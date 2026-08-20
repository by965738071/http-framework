//! Router — 基于 radix trie 的路由引擎（回应 bug.md §5）
//!
//! 职责：
//! 1. 注册路由到 trie
//! 2. 注册全局中间件
//! 3. dispatch：trie 匹配 → 组装管道 → 执行
//!
//! 不负责 TCP / 信号 / 连接生命周期（那些在 http_server 层）。

const std = @import("std");
const http = std.http;
const http_app = @import("http_app");
const Handler = http_app.Handler;
const Middleware = http_app.Middleware;
const DynPipeline = http_app.DynPipeline;
const Context = http_app.Context;
const Response = @import("http_protocol").Response;
const Trie = @import("trie.zig").Trie;

pub const Router = struct {
    trie: Trie,
    global_middleware: std.ArrayList(Middleware) = .empty,
    not_found: ?Handler = null,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{
            .trie = try Trie.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        self.trie.deinit();
        for (self.global_middleware.items) |mw| mw.deinit();
        self.global_middleware.deinit(self.allocator);
        if (self.not_found) |h| h.deinit();
        self.arena.deinit();
    }

    /// 注册路由
    pub fn route(self: *Router, method: http.Method, pattern: []const u8, handler: Handler) !void {
        try self.trie.insert(method, pattern, handler);
    }

    /// 注册全局中间件
    pub fn use(self: *Router, mw: Middleware) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// 设置 404 handler
    pub fn notFoundHandler(self: *Router, handler: Handler) void {
        self.not_found = handler;
    }

    /// 分发请求
    ///
    /// 三种结果都经过全局中间件管道，保证 404/405 响应也带 X-Request-Id、
    /// 日志上下文、计时头等（回应 fix.md §三：404 不走中间件）。
    pub fn dispatch(self: *const Router, ctx: *Context, res: *Response) !bool {
        const result = self.trie.match(
            @as(http.Method, ctx.request.method),
            ctx.request.path,
            ctx.state,
            ctx.arena,
        );

        // 决定最终要执行的 handler（命中 / 405 兜底 / 404 兜底 / not_found 自定义）
        const handler: Handler = if (result.handler) |h| h else if (result.pattern_matched) blk: {
            // 修复 F4：把 trie 计算出的 allowed_methods 拼成 Allow 头值，存进 state，
            // 供 methodNotAllowedHandler 输出（RFC 7231 §6.5.5）。
            if (result.allowed_count > 0) {
                var buf = std.ArrayList(u8).empty;
                errdefer buf.deinit(ctx.arena);
                var i: u8 = 0;
                while (i < result.allowed_count) : (i += 1) {
                    if (result.allowed_methods[i]) |m| {
                        if (buf.items.len > 0) try buf.appendSlice(ctx.arena, ", ");
                        try buf.appendSlice(ctx.arena, @tagName(m));
                    }
                }
                ctx.state.allow_header = try buf.toOwnedSlice(ctx.arena);
            }
            break :blk Handler.fromFn(methodNotAllowedHandler);
        } else if (self.not_found) |nf| nf else Handler.fromFn(defaultNotFoundHandler);

        ctx.state.route_pattern = result.pattern;

        // 组装管道：全局中间件 + handler
        // 即使是 404/405 也走管道——中间件（request-id/logging/timing）能正常工作
        var pipeline = DynPipeline.init(ctx.arena, handler);
        for (self.global_middleware.items) |mw| {
            try pipeline.add(mw);
        }
        try pipeline.dispatch(ctx, res);
        return true;
    }

    fn methodNotAllowedHandler(ctx: *Context, res: *Response) !void {
        _ = res.statusCode(.method_not_allowed);
        if (ctx.state.allow_header) |allow| {
            _ = try res.header("Allow", allow);
        }
        try res.text("Method Not Allowed");
    }

    fn defaultNotFoundHandler(_: *Context, res: *Response) !void {
        _ = res.statusCode(.not_found);
        try res.text("Not Found");
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Router dispatches to matched route" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *Context, res: *Response) !void {
            try res.text("hello");
        }
    }.h);
    try router.route(.GET, "/hello", handler);

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/hello",
        .path = "/hello",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /hello HTTP/1.1\r\n\r\n",
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
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "hello") != null);
}

test "Router returns 404 for unmatched route" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/nope",
        .path = "/nope",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /nope HTTP/1.1\r\n\r\n",
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
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    // 修复后：404 也走全局中间件管道，dispatch 始终返回 true
    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "404") != null);
}

test "Router records route pattern instead of raw path (fix TODO)" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *Context, res: *Response) !void {
            try res.text("hello");
        }
    }.h);
    try router.route(.GET, "/users/:id", handler);

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/users/42",
        .path = "/users/42",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /users/42 HTTP/1.1\r\n\r\n",
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
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    // 验证 route_pattern 是 pattern 而非原始路径
    try std.testing.expect(state.route_pattern != null);
    try std.testing.expectEqualStrings("/users/:id", state.route_pattern.?);
    // 验证 path_params 正确提取
    try std.testing.expectEqualStrings("42", state.path_params.get("id").?);
}
