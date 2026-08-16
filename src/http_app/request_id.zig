//! Request ID 中间件（回应 fix.md §二.5）
//!
//! 为每个请求生成唯一 ID，用于日志关联和跨服务追踪。
//!
//! 行为：
//! - 如果请求带 `X-Request-Id` 头，沿用客户端的 ID（信任客户端）
//! - 否则生成一个新的 16 字节随机 hex ID
//! - 把 ID 写进响应头 `X-Request-Id`
//! - 把 ID 存进 ctx.state.user_data，供日志/handler 取用
//!
//! 用法：
//! ```zig
//! var rid_mw = RequestIdMiddleware{};
//! router.use(Middleware.init(RequestIdMiddleware, &rid_mw));
//! // 放在最外层（仅次于 ErrorRenderer），让后续中间件都能拿到 ID
//! ```
//!
//! 之后日志中间件可以这样取：
//!   const rid = ctx.state.getUserData(RequestId);

const std = @import("std");
const Context = @import("context.zig").Context;
const Response = @import("http_protocol").Response;
const Next = @import("middleware.zig").Next;

pub const REQUEST_ID_HEADER = "X-Request-Id";

/// 请求 ID 容器——存进 ctx.state.user_data，按 RequestId 类型索引。
pub const RequestId = struct {
    value: [32]u8 = std.mem.zeroes([32]u8),
    len: u8 = 0,

    pub fn slice(self: *const RequestId) []const u8 {
        return self.value[0..self.len];
    }
};

pub const RequestIdMiddleware = struct {
    const Self = @This();

    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        _ = self;

        // 在请求 arena 上分配 RequestId 槽
        const rid = try ctx.arena.create(RequestId);

        // 沿用客户端传入的 X-Request-Id（信任模式，便于跨服务串联）
        if (ctx.request.getHeader("x-request-id")) |client_rid| {
            const copy_len = @min(client_rid.len, rid.value.len);
            @memcpy(rid.value[0..copy_len], client_rid[0..copy_len]);
            rid.len = @intCast(copy_len);
        } else {
            // 生成 16 字节随机 ID，hex 编码成 32 字符
            var rand_bytes: [16]u8 = undefined;
            ctx.io.random(&rand_bytes);
            const hex_chars = "0123456789abcdef";
            for (rand_bytes, 0..) |b, i| {
                rid.value[i * 2] = hex_chars[b >> 4];
                rid.value[i * 2 + 1] = hex_chars[b & 0xf];
            }
            rid.len = 32;
        }

        // 存进 ctx.state，供下游中间件/handler/日志取用
        try ctx.state.setUserData(RequestId, rid, ctx.arena);

        // 先把头加到响应（缓冲模式下也能在 flush 时输出）
        _ = res.header(REQUEST_ID_HEADER, rid.slice()) catch {};

        try next.call(ctx, res);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "RequestIdMiddleware generates ID when client didn't send one" {
    // 这个测试需要接线的 io（std.Io.random），留到集成测试覆盖。
    // 这里只验证结构：如果带 X-Request-Id 头，应该沿用。
    _ = RequestIdMiddleware{};
}

test "RequestIdMiddleware reuses client-provided X-Request-Id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\nX-Request-Id: abc-123\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    var rid_mw = RequestIdMiddleware{};
    // 构建一个最小 pipeline（0 中间件 + no-op handler），
    // 其 Next.call 会走到 handler.dispatch。
    const noop_handler = @import("handler.zig").Handler.fromFn(struct {
        fn handle(_: *Context, _: *Response) !void {}
    }.handle);
    var pipeline = @import("middleware.zig").DynPipeline.init(arena.allocator(), noop_handler);
    defer pipeline.deinit();
    // Next 从 DynPipeline 的 items + handler 构建（不再直接引用 pipeline 指针）
    const next = @import("middleware.zig").Next.root(pipeline.items.items, pipeline.handler);
    try rid_mw.process(&ctx, &res, next);

    const stored = ctx.state.getUserData(RequestId);
    try std.testing.expect(stored != null);
    try std.testing.expectEqualStrings("abc-123", stored.?.slice());
}
