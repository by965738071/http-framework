//! 请求上下文 — 拆分 God Object（回应 bug.md §4）
//!
//! 原来的 RequestContext 一个 struct 持有 24 个字段、4 种所有权模型。
//! 现在拆成三个对象：
//!
//! - `Request`（不可变）：解析结果，从 http_protocol 层 re-export
//! - `RequestState`（可变）：路由输出 + 中间件通讯槽 + 连接状态
//! - `RequestConfig`（只读共享指针）：配置注入
//!
//! Context 是 handler / middleware 看到的完整类型，组合了这三者。
//! deinit 只需释放 RequestState，不需要 4 种所有权规则的 if-else 链。

const std = @import("std");
const http_protocol = @import("http_protocol");
const error_mod = @import("error.zig");
const Services = @import("services.zig").Services;

pub const Request = http_protocol.Request;
pub const AppError = error_mod.AppError;

/// 连接劫持钩子（如 WebSocket 升级）。
///
/// handler 通过 `ctx.hijack(...)` 注册后，ConnectionRunner 在 dispatch 结束、
/// **不发送常规响应**的前提下，把裸 `*std.Io.Reader` / `*std.Io.Writer`
/// 交给 `run` 回调；回调负责写协议切换响应并接管连接（跑帧循环等）。
/// 回调返回即视为连接结束，keep-alive 循环随之退出。
///
/// 这是**协议无关**的原语：http_app 不依赖 http_websocket（避免循环依赖），
/// WebSocket 只是它的一个使用者。
pub const Hijack = struct {
    /// 用户上下文（回调实现自行 @ptrCast 回具体类型）。
    ctx: *anyopaque,
    /// 接管裸连接。allocator 是连接级 gpa（非 arena），回调内分配需自行释放。
    run: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
    ) anyerror!void,
};

/// 路径参数存储 —— 小型内联数组（性能优化）。
///
/// REST 路由参数通常 0-2 个，极少超过几个。HashMap 的哈希+桶分配在这个
/// 绝对热路径上得不偿失，改用固定容量内联数组：get/put 就是几次 eql 比较，
/// 零分配（key/value 切片指向 trie/arena，本结构只存指针）。
/// 容量 16 足够——router 已限制路径段数 ≤64，参数数 ≤ 段数，实际远小于 16。
pub const PathParams = struct {
    pub const CAP = 16;
    keys: [CAP][]const u8 = undefined,
    values: [CAP][]const u8 = undefined,
    len: usize = 0,

    pub fn put(self: *PathParams, key: []const u8, value: []const u8) !void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.keys[i], key)) {
                self.values[i] = value;
                return;
            }
        }
        if (self.len >= CAP) return error.TooManyPathParams;
        self.keys[self.len] = key;
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn get(self: *const PathParams, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.keys[i], key)) return self.values[i];
        }
        return null;
    }

    /// 移除某个 key（swap-remove，顺序无关）。返回是否移除到。
    /// 供 trie 匹配回溯时撤销 param 绑定。
    pub fn remove(self: *PathParams, key: []const u8) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.keys[i], key)) {
                self.len -= 1;
                self.keys[i] = self.keys[self.len];
                self.values[i] = self.values[self.len];
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *PathParams) void {
        self.len = 0;
    }

    /// 清空所有绑定（保留容量）。供 router 在 HEAD→GET 回退前撤销上一轮残留参数（P2-6）。
    pub fn clear(self: *PathParams) void {
        self.len = 0;
    }
};

/// 请求级可变状态（每个请求一个实例）。
pub const RequestState = struct {
    /// 请求级分配器（生产上是连接复用的 request arena；测试里可为任意 allocator）。
    /// setUserData 用它分配链表节点；节点随 arena reset 统一回收，不单独 free。
    arena: std.mem.Allocator,
    path_params: PathParams = .{},
    user_data: ?*UserData = null,
    route_pattern: ?[]const u8 = null,
    /// 405 时的 Allow 头值（逗号分隔的方法名）。由 router 在方法不匹配时填充，
    /// methodNotAllowedHandler 读取并写入响应头（修复 F4：405 缺 Allow）。
    allow_header: ?[]const u8 = null,
    poisoned: bool = false,
    /// 已缓冲的请求体（fix.md §四.7：Request 不可变，body 缓存移到 State）。
    /// readBody 首次调用后缓存于此，后续调用直接返回。
    body_buffer: ?[]const u8 = null,
    /// 连接劫持钩子（WebSocket 升级等）。handler 设置后 ConnectionRunner
    /// 跳过常规响应并把裸连接交给 hijack.run。
    hijack: ?Hijack = null,

    pub fn deinit(self: *RequestState) void {
        // path_params: 内联数组，key/value 切片指向 trie/arena，无需释放内存。
        self.path_params.deinit();

        // user_data: 节点由 self.arena 分配、这里用同一个 self.arena 释放，
        // 不存在分配/释放 allocator 不匹配的风险。arena 分配器下 destroy 是 no-op
        // （随 arena reset 统一回收）；裸 allocator（如测试）下正常释放节点。
        // 注：ud.ptr 指向的数据由调用方拥有（通常是 arena），不在此释放。
        var node = self.user_data;
        self.user_data = null;
        while (node) |ud| {
            const next = ud.next;
            self.arena.destroy(ud);
            node = next;
        }
    }

    /// 按类型索引的中间件通讯槽。
    pub fn getUserData(self: *const RequestState, comptime T: type) ?*T {
        var node = self.user_data;
        while (node) |ud| {
            if (std.mem.eql(u8, ud.key, @typeName(T))) {
                return @ptrCast(@alignCast(ud.ptr));
            }
            node = ud.next;
        }
        return null;
    }

    /// 设置中间件通讯槽（按类型索引，不覆盖其它类型的槽）。
    /// 同类型重复设置时原地更新 ptr，不产生孤儿节点（与 PathParams.put 对齐）。
    /// 链表节点用 self.arena 分配，随 arena 统一回收。
    pub fn setUserData(self: *RequestState, comptime T: type, ptr: *T) !void {
        const key = @typeName(T);
        var node = self.user_data;
        while (node) |ud| {
            if (std.mem.eql(u8, ud.key, key)) {
                ud.ptr = @ptrCast(ptr);
                return;
            }
            node = ud.next;
        }
        const new_node = try self.arena.create(UserData);
        new_node.* = .{
            .key = key,
            .ptr = @ptrCast(ptr),
            .next = self.user_data,
        };
        self.user_data = new_node;
    }
};

/// 用户数据槽位 — 按类型索引的不透明指针。
pub const UserData = struct {
    key: []const u8,
    ptr: *anyopaque,
    next: ?*UserData = null,
};

/// 配置视图（全局共享，不可变）。
/// 回应 bug.md §4：配置不再平铺到每个请求。
pub const RequestConfig = struct {
    trust_proxy: bool = false,
    body_size_limit: u64 = 0,
    lazy_read_size: u64 = 0,
};

/// 完整上下文 — handler / middleware 看到的类型。
pub const Context = struct {
    /// Request 不可变（fix.md §四.7：解析结果不应被中间件/handler 修改）。
    /// body 缓存由 RequestState.body_buffer 承载，readBody 经 Context 走 State。
    request: *const Request,
    state: *RequestState,
    config: *const RequestConfig,
    arena: std.mem.Allocator,
    io: std.Io,
    /// 应用级服务容器（进程级单例，如 SessionManager/Logger/ORM Store）。
    /// 由 Server 注入；handler 通过 ctx.service(T) 取回，脱离全局变量。
    /// 可能为 null（未注入服务时，如部分单元测试）。
    services: ?*const Services = null,
    /// 对端 IP 地址（内核 accept 时获得，不可伪造）。
    /// 由后端（如 zio_server）注入；单元测试手工构造 Context 时为 null。
    /// per-IP 限流 / 审计日志 / Geofence 必须优先用它，而不是可伪造的代理头（H3/M8）。
    peer_ip: ?std.Io.net.IpAddress = null,

    /// 对端 IP 的稳定字符串形式（不含端口），适合做 per-IP 限流键 / 审计日志：
    ///   - IPv4 → 点分十进制，如 "203.0.113.195"
    ///   - IPv6 → 16 字节大端序的低位十六进制（RFC-5952 压缩省略，但无歧义且稳定）
    /// 无对端地址时为 null；缓冲区不够时返回 null，调用方给足 ≥ 64 字节。
    pub fn peerIpString(self: *const Context, buf: []u8) ?[]const u8 {
        const ip = self.peer_ip orelse return null;
        var w = std.Io.Writer.fixed(buf);
        switch (ip) {
            .ip4 => |a| w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch return null,
            .ip6 => |a| {
                for (a.bytes) |b| w.print("{x:0>2}", .{b}) catch return null;
            },
        }
        return w.buffered();
    }

    /// 取回某类型的应用级服务，未注册或未注入服务容器时返回 null。
    /// 用法：`const sm = ctx.service(SessionManager) orelse return error...;`
    pub fn service(self: *const Context, comptime T: type) ?*T {
        const svc = self.services orelse return null;
        return svc.get(T);
    }

    /// 读取请求体。首次调用从 streaming body 读取并存入 state.body_buffer；
    /// 后续调用直接返回缓存的 buffer。handler/中间件应通过此方法读 body，
    /// 而非 ctx.request.readBody()（Request 已不可变，不再提供 readBody）。
    pub fn readBody(self: *Context, allocator: std.mem.Allocator, limit: u64) ![]const u8 {
        if (self.state.body_buffer) |buf| return buf;
        const buf = try self.request.readBodyInto(allocator, limit);
        self.state.body_buffer = buf;
        return buf;
    }

    /// 便捷方法：获取路径参数（原始，未解码）
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.state.path_params.get(name);
    }

    /// 便捷方法：获取路径参数并按 **RFC 3986** 解码（`%XX`→字节，`+` 保持
    /// 字面量，用 ctx.arena）。非法 `%` 序列原样保留（不报错），参数不存在
    /// 返回 null。
    ///
    /// 为什么不用 form 语义（`+`→空格）：那是 `queryDecoded` / `formDecoded`
    /// 的规则，只适用于 application/x-www-form-urlencoded。RFC 3986 把 `+`
    /// 列为 sub-delims，在路径段里就是普通字符——`/files/a+b.txt` 若按 form
    /// 解成 `a b.txt`，这个文件名就永远取不到。
    ///
    /// `param` 保持返回原始值：trie 匹配时把路径段原样塞进 PathParams，改成
    /// 匹配期解码会破坏现有调用方（http_static 依赖原始段做 `..` 与前缀校验，
    /// 且「先校验再解码」正是它防路径穿越的顺序），也会让 match 在热路径上
    /// 为每个请求分配。解码因此推迟到真正要用的这一刻。
    pub fn paramDecoded(self: *const Context, name: []const u8) !?[]const u8 {
        const raw = self.state.path_params.get(name) orelse return null;
        return try http_protocol.urlDecodePath(self.arena, raw);
    }

    /// 便捷方法：获取请求头
    pub fn header(self: *const Context, name: []const u8) ?[]const u8 {
        return self.request.getHeader(name);
    }

    /// 便捷方法：获取 query 参数（原始，未解码）
    pub fn query(self: *const Context, key: []const u8) ?[]const u8 {
        return self.request.getQuery(key);
    }

    /// 便捷方法：获取 query 参数并解码（`+`→空格、`%XX`→字节，用 ctx.arena）。
    pub fn queryDecoded(self: *const Context, key: []const u8) !?[]const u8 {
        return self.request.getQueryDecoded(self.arena, key);
    }

    /// 便捷方法：读 body 后获取表单字段（原始，未解码）。
    /// 读取的 body 缓冲在 state.body_buffer（streaming body 经 readBody 缓冲）。
    pub fn form(self: *Context, key: []const u8, limit: u64) !?[]const u8 {
        const body = try self.readBody(self.arena, limit);
        return Request.getFormFrom(body, key);
    }

    /// 便捷方法：读 body 后获取表单字段并解码（urlencoded）。
    pub fn formDecoded(self: *Context, key: []const u8, limit: u64) !?[]const u8 {
        const body = try self.readBody(self.arena, limit);
        return Request.getFormDecodedFrom(self.arena, body, key);
    }

    /// 便捷方法：中间件通讯槽
    pub fn getUserData(self: *const Context, comptime T: type) ?*T {
        return self.state.getUserData(T);
    }

    pub fn setUserData(self: *Context, comptime T: type, ptr: *T) !void {
        try self.state.setUserData(T, ptr);
    }

    /// 注册连接劫持钩子（WebSocket 升级等）。
    /// handler 调用后应直接 return：ConnectionRunner 会跳过常规响应，
    /// 在 dispatch 结束后把裸 reader/writer 交给 `run` 回调。
    /// 注意：劫持后该请求不再经过 Response，不要再写响应体。
    pub fn hijack(self: *Context, hijack_ctx: *anyopaque, run: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
    ) anyerror!void) void {
        self.state.hijack = .{ .ctx = hijack_ctx, .run = run };
    }

    /// 便捷方法：发送错误响应（状态码 + 消息文本）。
    /// 直接写响应，handler 应直接 return。
    /// 注意：这种方式不经过 ErrorRenderer，丢失了错误细节结构化。
    /// 推荐用 `failWith` 让 ErrorRenderer 统一渲染。
    pub fn fail(self: *Context, res: *http_protocol.Response, status: std.http.Status, message: []const u8) !void {
        _ = self;
        _ = res.statusCode(status);
        try res.text(message);
    }

    /// 推荐：返回结构化应用错误。把 AppError 存进 ctx.state.user_data，
    /// 返回 `error.AppError`。ErrorRenderer 会 catch 到这个 error，
    /// 取出 AppError 并用 `toResponse` 渲染（fix.md §一.3）。
    ///
    /// handler 用法：
    ///   try ctx.failWith(AppError.unauthorized("bad token"));
    ///   return;  // failWith 返回 error.AppError，会自动 return
    pub fn failWith(self: *Context, app_err: AppError) !void {
        // 在请求 arena 上分配 AppError 实例，存进 user_data 槽。
        // 连接结束 arena 回收，无需手动 free。
        const slot = try self.arena.create(AppError);
        slot.* = app_err;
        try self.state.setUserData(AppError, slot);
        return error.AppError;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "RequestState.setUserData / getUserData by type" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var state = RequestState{ .arena = arena_alloc };
    defer state.deinit();

    const AuthInfo = struct { user_id: u32 };
    const Session = struct { session_id: []const u8 };

    var auth = AuthInfo{ .user_id = 42 };
    var session = Session{ .session_id = "abc123" };

    try state.setUserData(AuthInfo, &auth);
    try state.setUserData(Session, &session);

    try std.testing.expectEqual(@as(u32, 42), state.getUserData(AuthInfo).?.user_id);
    try std.testing.expectEqualStrings("abc123", state.getUserData(Session).?.session_id);
    try std.testing.expect(state.getUserData(struct { missing: void }) == null);
}

test "Context.param delegates to state.path_params" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    try state.path_params.put("id", "123");

    var req = Request{
        .method = .GET,
        .target = "/users/123",
        .path = "/users/123",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = RequestConfig{};
    const ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    try std.testing.expectEqualStrings("123", ctx.param("id").?);
}

test "Context.paramDecoded 解码路径参数，param 保持原始值" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    try state.path_params.put("id", "%41");

    var req = Request{
        .method = .GET,
        .target = "/users/%41",
        .path = "/users/%41",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /users/%41 HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = RequestConfig{};
    const ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    // param 必须继续返回原始段（http_static 依赖它做遍历校验）
    try std.testing.expectEqualStrings("%41", ctx.param("id").?);
    try std.testing.expectEqualStrings("A", (try ctx.paramDecoded("id")).?);

    // 空参数值：解码结果仍是空串，不是 null
    try state.path_params.put("empty", "");
    try std.testing.expectEqualStrings("", (try ctx.paramDecoded("empty")).?);
}

test "Context.paramDecoded 按 RFC 3986 解码：多字节 UTF-8、%20、加号字面量" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    try state.path_params.put("name", "%E4%B8%AD%E6%96%87");
    try state.path_params.put("q", "a+b");
    try state.path_params.put("sp", "%20x");

    var req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = RequestConfig{};
    const ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    try std.testing.expectEqualStrings("中文", (try ctx.paramDecoded("name")).?);
    try std.testing.expectEqualStrings(" x", (try ctx.paramDecoded("sp")).?);
    // 路径按 RFC 3986：`+` 是字面量（form 语义的 '+'→空格 只属于 query/表单）。
    try std.testing.expectEqualStrings("a+b", (try ctx.paramDecoded("q")).?);

    // `/files/a+b.txt`：解出来必须还是 a+b.txt，否则这个文件名永远取不到。
    try state.path_params.put("file", "a+b.txt");
    try std.testing.expectEqualStrings("a+b.txt", (try ctx.paramDecoded("file")).?);
    // %20 照常解成空格
    try state.path_params.put("sp2", "a%20b.txt");
    try std.testing.expectEqualStrings("a b.txt", (try ctx.paramDecoded("sp2")).?);
}

test "Context.paramDecoded 对非法 % 序列与 queryDecoded 同口径：原样保留" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    try state.path_params.put("bad", "%zz");
    try state.path_params.put("trunc", "abc%2");
    try state.path_params.put("tail", "100%");

    var req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = RequestConfig{};
    const ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    // urlDecode 不把非法序列当错误，原样吐回（queryDecoded 已经是这个行为）。
    try std.testing.expectEqualStrings("%zz", (try ctx.paramDecoded("bad")).?);
    try std.testing.expectEqualStrings("abc%2", (try ctx.paramDecoded("trunc")).?);
    try std.testing.expectEqualStrings("100%", (try ctx.paramDecoded("tail")).?);
    // 不存在的参数 → null（不是 error）
    try std.testing.expect(try ctx.paramDecoded("nope") == null);
}

test "Context.peerIpString 格式化内核对端 IP（H3  plumbing）" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{ .arena = arena.allocator() };
    defer state.deinit();

    var req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = RequestConfig{};
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
        .peer_ip = .{ .ip4 = .{ .bytes = .{ 203, 0, 113, 195 }, .port = 8080 } },
    };

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("203.0.113.195", ctx.peerIpString(&buf).?);

    // v6 也能格式化
    // v6 也能格式化（16 字节大端 hex，无歧义）
    ctx.peer_ip = .{ .ip6 = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 0 } };
    try std.testing.expectEqualStrings("00000000000000000000000000000001", ctx.peerIpString(&buf).?);

    // 无对端地址 → null
    ctx.peer_ip = null;
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.peerIpString(&buf));
}

test {
    std.testing.refAllDecls(@This());
}
