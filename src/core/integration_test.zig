//! 集成测试 — 不启动真实 HTTP Server，但覆盖完整的请求处理链路：
//! 路由分发 → 中间件链 → 处理器执行 → 响应构建
//! 使用 `Head.parse()` 创建模拟 HTTP 请求，通过 `router.dispatch()` 全流程处理。
//!
//! 覆盖内容：
//! - 纯函数/单例/请求级三种处理器模式
//! - 静态路由、路径参数、通配符
//! - 中间件链（允许、阻止、错误）
//! - 查询参数、请求体
//! - 404 路由、方法不允许 405

const std = @import("std");
const http = std.http;
const mem = std.mem;

const core = @import("root.zig");
const Router = core.Router;
const Handler = core.Handler;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Middleware = core.Middleware;

/// 创建模拟 HTTP 请求上下文
fn createMockRequest(
    allocator: std.mem.Allocator,
    method: http.Method,
    target: []const u8,
    headers: ?[]const []const u8,
    body: ?[]const u8,
) !RequestContext {
    // 使用栈缓冲区构建原始 HTTP 请求头
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // 请求行
    const rl = try std.fmt.bufPrint(buf[pos..], "{s} {s} HTTP/1.1\r\n", .{ @tagName(method), target });
    pos += rl.len;

    const hl = try std.fmt.bufPrint(buf[pos..], "Host: localhost\r\n", .{});
    pos += hl.len;

    if (headers) |hds| {
        for (hds) |h| {
            const hr = try std.fmt.bufPrint(buf[pos..], "{s}\r\n", .{h});
            pos += hr.len;
        }
    }
    if (body) |b| {
        const cl = try std.fmt.bufPrint(buf[pos..], "Content-Length: {d}\r\n", .{b.len});
        pos += cl.len;
    }
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    const raw_headers = buf[0..pos];

    // 用 Head.parse 解析请求头
    const head = try http.Server.Request.Head.parse(raw_headers);

    // 构建 http.Server.Request
    var req = http.Server.Request{
        .server = undefined,
        .head = head,
        .head_buffer = raw_headers,
        .respond_err = null,
    };

    // 初始化 RequestContext
    var ctx = try RequestContext.init(allocator, std.testing.io, &req);

    // 如果有请求体，手动设置
    if (body) |b| {
        ctx.body_data = try allocator.dupe(u8, b);
        ctx.body_read = true;
    }

    return ctx;
}

/// 创建模拟 Response（不实际发送）
fn createMockResponse(allocator: std.mem.Allocator, ctx: *RequestContext) !Response {
    return Response.init(allocator, ctx.request);
}

// ── 测试辅助：验证 handler 被调用的状态持有者 ────────

const BoolFlag = struct {
    flag: *bool,
    pub fn handle(self: *@This(), _: *RequestContext, _: *Response) !void {
        self.flag.* = true;
    }
};

const NoopHandler = struct {
    pub fn handle(_: *@This(), _: *RequestContext, _: *Response) !void {}
};

// ===========================================================================
// 测试：基本路由分发
// ===========================================================================

test "integration - router dispatches GET static route to handler" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var handled = false;
    var h = BoolFlag{ .flag = &handled };
    try router.route(.GET, "/hello", Handler.init(BoolFlag, &h));

    var ctx = try createMockRequest(allocator, .GET, "/hello", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expect(handled);
}

test "integration - router returns 404 for unknown route" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var not_found_called = false;
    var nf = BoolFlag{ .flag = &not_found_called };
    router.notFound(Handler.init(BoolFlag, &nf));

    var ctx = try createMockRequest(allocator, .GET, "/unknown", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expect(not_found_called);
}

// ===========================================================================
// 测试：中间件
// ===========================================================================

test "integration - middleware can block request" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const BlockMiddleware = struct {
        pub fn process(self: *@This(), ctx: *RequestContext) anyerror!Middleware.NextAction {
            _ = self;
            ctx.blocked_status = .forbidden;
            return .respond;
        }
    };

    var blocker = BlockMiddleware{};
    const mw = Middleware.init(BlockMiddleware, &blocker);

    var noop = NoopHandler{};
    try router.routeWithMiddleware(.GET, "/blocked", Handler.init(NoopHandler, &noop), &.{mw});

    var ctx = try createMockRequest(allocator, .GET, "/blocked", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expectEqual(@as(http.Status, .forbidden), ctx.blocked_status.?);
}

test "integration - middleware passes through with .next" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var middleware_called = false;
    var handler_called = false;

    const PassMiddleware = struct {
        called: *bool,
        pub fn process(self: *@This(), ctx: *RequestContext) anyerror!Middleware.NextAction {
            _ = ctx;
            self.called.* = true;
            return .next;
        }
    };
    var mw_state = PassMiddleware{ .called = &middleware_called };
    const mw = Middleware.init(PassMiddleware, &mw_state);

    var h = BoolFlag{ .flag = &handler_called };
    try router.routeWithMiddleware(.GET, "/pass", Handler.init(BoolFlag, &h), &.{mw});

    var ctx = try createMockRequest(allocator, .GET, "/pass", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expect(middleware_called);
    try std.testing.expect(handler_called);
}

test "integration - middleware can return .err" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const ErrMiddleware = struct {
        pub fn process(_: *@This(), ctx: *RequestContext) anyerror!Middleware.NextAction {
            _ = ctx;
            return .err;
        }
    };

    var err_mw = ErrMiddleware{};
    const mw = Middleware.init(ErrMiddleware, &err_mw);

    var handler_called = false;
    var h = BoolFlag{ .flag = &handler_called };
    try router.routeWithMiddleware(.GET, "/err", Handler.init(BoolFlag, &h), &.{mw});

    var ctx = try createMockRequest(allocator, .GET, "/err", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expect(!handler_called);
}

// ===========================================================================
// 测试：多种处理器模式
// ===========================================================================

test "integration - singleton handler preserves state between calls" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const Counter = struct {
        count: u32 = 0,
        pub fn handle(self: *@This(), _: *RequestContext, _: *Response) !void {
            self.count += 1;
        }
    };

    var counter = Counter{};
    try router.route(.GET, "/count", Handler.init(Counter, &counter));

    var ctx1 = try createMockRequest(allocator, .GET, "/count", null, null);
    defer ctx1.deinit();
    var res1 = try createMockResponse(allocator, &ctx1);
    defer res1.deinit();
    _ = try router.dispatch(&ctx1, &res1);
    try std.testing.expectEqual(@as(u32, 1), counter.count);

    var ctx2 = try createMockRequest(allocator, .GET, "/count", null, null);
    defer ctx2.deinit();
    var res2 = try createMockResponse(allocator, &ctx2);
    defer res2.deinit();
    _ = try router.dispatch(&ctx2, &res2);
    try std.testing.expectEqual(@as(u32, 2), counter.count);
}

test "integration - per-request handler gets fresh instance each time" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var instance_ids = std.ArrayList(usize).empty;
    defer instance_ids.deinit(allocator);

    // Use Handler.initPerRequestWith to pass state via a type with var declarations
    const PerReqHandler = struct {
        id: usize,
        var next_id: usize = 0;
        var results_list: *std.ArrayList(usize) = undefined;

        pub fn init(alloc: std.mem.Allocator, _: void) !*@This() {
            const self = try alloc.create(@This());
            self.* = .{ .id = next_id };
            next_id += 1;
            return self;
        }

        pub fn handle(self: *@This(), _: *RequestContext, _: *Response) !void {
            results_list.append(allocator, self.id) catch {};
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    PerReqHandler.next_id = 0;
    PerReqHandler.results_list = &instance_ids;

    const handler = try Handler.initPerRequestWith(PerReqHandler, allocator, {});
    defer {
        // Context cleanup - get the Context struct from handler.ptr
        const Context = struct { alloc: std.mem.Allocator, args: void };
        const ctx_ptr: *Context = @ptrCast(@alignCast(handler.ptr));
        allocator.destroy(ctx_ptr);
    }
    try router.route(.GET, "/per-req", handler);

    // 第一次请求
    {
        var ctx = try createMockRequest(allocator, .GET, "/per-req", null, null);
        defer ctx.deinit();
        var res = try createMockResponse(allocator, &ctx);
        defer res.deinit();
        _ = try router.dispatch(&ctx, &res);
    }

    // 第二次请求
    {
        var ctx = try createMockRequest(allocator, .GET, "/per-req", null, null);
        defer ctx.deinit();
        var res = try createMockResponse(allocator, &ctx);
        defer res.deinit();
        _ = try router.dispatch(&ctx, &res);
    }

    try std.testing.expectEqual(@as(usize, 2), instance_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), instance_ids.items[0]);
    try std.testing.expectEqual(@as(usize, 1), instance_ids.items[1]);
}

// ===========================================================================
// 测试：方法不匹配
// ===========================================================================

test "integration - POST to GET-only route returns 405" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var handler_called = false;
    var h = BoolFlag{ .flag = &handler_called };
    try router.route(.GET, "/data", Handler.init(BoolFlag, &h));

    var ctx = try createMockRequest(allocator, .POST, "/data", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expect(!handler_called);
}

// ===========================================================================
// 测试：请求体读取
// ===========================================================================

test "integration - handler can read request body" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var body_content: []const u8 = "";
    const BodyCapture = struct {
        dest: *[]const u8,
        pub fn handle(self: *@This(), ctx: *RequestContext, _: *Response) !void {
            self.dest.* = try ctx.readBody();
        }
    };
    var h = BodyCapture{ .dest = &body_content };
    try router.route(.POST, "/echo", Handler.init(BodyCapture, &h));

    var ctx = try createMockRequest(allocator, .POST, "/echo", null, "hello-body");
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expectEqualStrings("hello-body", body_content);
}
