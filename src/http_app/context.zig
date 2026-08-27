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

    /// allocator 参数保留是为了与旧 HashMap 调用点签名兼容（本实现不分配）。
    pub fn put(self: *PathParams, _: std.mem.Allocator, key: []const u8, value: []const u8) !void {
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

    /// 与旧 HashMap 签名兼容；内联数组无需释放。
    pub fn deinit(self: *PathParams, _: std.mem.Allocator) void {
        self.len = 0;
    }

    /// 清空所有绑定（保留容量）。供 router 在 HEAD→GET 回退前撤销上一轮残留参数（P2-6）。
    pub fn clear(self: *PathParams) void {
        self.len = 0;
    }
};

/// 请求级可变状态（每个请求一个实例）。
pub const RequestState = struct {
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

    pub fn deinit(self: *RequestState, allocator: std.mem.Allocator) void {
        // path_params: 内联数组，key/value 切片指向 trie/arena，无需释放内存。
        self.path_params.deinit(allocator);

        // user_data: 链表节点由 arena 分配，arena reset 时回收。
        // 但 destroyFn 可能需要释放非 arena 资源。
        var node = self.user_data;
        self.user_data = null;
        while (node) |ud| {
            const next = ud.next;
            ud.destroyFn(ud.ptr, allocator);
            allocator.destroy(ud);
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
    pub fn setUserData(self: *RequestState, comptime T: type, ptr: *T, allocator: std.mem.Allocator) !void {
        const node = try allocator.create(UserData);
        node.* = .{
            .key = @typeName(T),
            .ptr = @ptrCast(ptr),
            .destroyFn = struct {
                fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
            }.destroy,
            .next = self.user_data,
        };
        self.user_data = node;
    }
};

/// 用户数据槽位 — 按类型索引的不透明指针。
pub const UserData = struct {
    key: []const u8,
    ptr: *anyopaque,
    destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
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

    /// 便捷方法：获取路径参数
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.state.path_params.get(name);
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
        try self.state.setUserData(T, ptr, self.arena);
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
    ///   try ctx.failWith(res, .unauthorized, "bad token");
    ///   return;  // 实际上 failWith 返回 error，会自动 return
    pub fn failWith(self: *Context, res: *http_protocol.Response, app_err: AppError) !void {
        _ = res;
        // 在请求 arena 上分配 AppError 实例，存进 user_data 槽。
        // 连接结束 arena 回收，无需手动 free。
        const slot = try self.arena.create(AppError);
        slot.* = app_err;
        try self.state.setUserData(AppError, slot, self.arena);
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

    var state = RequestState{};
    defer state.deinit(arena_alloc);

    const AuthInfo = struct { user_id: u32 };
    const Session = struct { session_id: []const u8 };

    var auth = AuthInfo{ .user_id = 42 };
    var session = Session{ .session_id = "abc123" };

    try state.setUserData(AuthInfo, &auth, arena_alloc);
    try state.setUserData(Session, &session, arena_alloc);

    try std.testing.expectEqual(@as(u32, 42), state.getUserData(AuthInfo).?.user_id);
    try std.testing.expectEqualStrings("abc123", state.getUserData(Session).?.session_id);
    try std.testing.expect(state.getUserData(struct { missing: void }) == null);
}

test "Context.param delegates to state.path_params" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = RequestState{};
    defer state.deinit(arena.allocator());
    try state.path_params.put(arena.allocator(), "id", "123");

    var req = Request{
        .method = .GET,
        .target = "/users/123",
        .path = "/users/123",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
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

test {
    std.testing.refAllDecls(@This());
}
