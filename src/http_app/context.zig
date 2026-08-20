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

pub const Request = http_protocol.Request;
pub const AppError = error_mod.AppError;

/// 请求级可变状态（每个请求一个实例）。
pub const RequestState = struct {
    path_params: std.StringHashMapUnmanaged([]const u8) = .empty,
    user_data: ?*UserData = null,
    route_pattern: ?[]const u8 = null,
    /// 405 时的 Allow 头值（逗号分隔的方法名）。由 router 在方法不匹配时填充，
    /// methodNotAllowedHandler 读取并写入响应头（修复 F4：405 缺 Allow）。
    allow_header: ?[]const u8 = null,
    poisoned: bool = false,
    /// 已缓冲的请求体（fix.md §四.7：Request 不可变，body 缓存移到 State）。
    /// readBody 首次调用后缓存于此，后续调用直接返回。
    body_buffer: ?[]const u8 = null,

    pub fn deinit(self: *RequestState, allocator: std.mem.Allocator) void {
        // path_params: key 和 value 都在 request arena 上，arena reset 时自动回收。
        // 但 HashMap 的内部桶需要释放。
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

    /// 便捷方法：获取 query 参数
    pub fn query(self: *const Context, key: []const u8) ?[]const u8 {
        return self.request.getQuery(key);
    }

    /// 便捷方法：中间件通讯槽
    pub fn getUserData(self: *const Context, comptime T: type) ?*T {
        return self.state.getUserData(T);
    }

    pub fn setUserData(self: *Context, comptime T: type, ptr: *T) !void {
        try self.state.setUserData(T, ptr, self.arena);
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
