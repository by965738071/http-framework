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

const fw = @import("../root.zig");
const Router = fw.Router;
const Handler = fw.Handler;
const RequestContext = fw.RequestContext;
const Response = fw.Response;
const Middleware = fw.Middleware;

/// 模拟请求的后备存储。
///
/// `RequestContext` 不复制请求报文：`ctx.path` / header 值 / `ctx.request`
/// 全都是指向原始字节和 `http.Server.Request` 的指针。所以这两块内存必须
/// 活得比 ctx 长——由调用方在自己的栈帧上持有本结构，而不是放在
/// `createMockRequest` 的栈帧里（那样函数一返回 ctx 就全是悬垂指针，
/// 测试能不能过纯看运气）。
const MockStorage = struct {
    head_buf: [4096]u8 = undefined,
    req: http.Server.Request = undefined,
};

/// 创建模拟 HTTP 请求上下文。
///
/// `storage` 必须在整个 ctx 生命周期内保持有效且不被移动。
fn createMockRequest(
    storage: *MockStorage,
    allocator: std.mem.Allocator,
    method: http.Method,
    target: []const u8,
    headers: ?[]const []const u8,
    body: ?[]const u8,
) !RequestContext {
    const buf = &storage.head_buf;
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

    // 构建 http.Server.Request（存进调用方的 storage，地址才稳定）
    storage.req = .{
        .server = undefined,
        .head = head,
        .head_buffer = raw_headers,
        .respond_err = null,
    };

    // 初始化 RequestContext
    var ctx = try RequestContext.init(allocator, std.testing.io, &storage.req);

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

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/hello", null, null);
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

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/unknown", null, null);
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
        pub fn process(self: *@This(), ctx: *RequestContext, res: *Response) anyerror!Middleware.NextAction {
            _ = self;
            _ = res;
            ctx.blocked_status = .forbidden;
            return .respond;
        }
    };

    var blocker = BlockMiddleware{};
    const mw = Middleware.init(BlockMiddleware, &blocker);

    var noop = NoopHandler{};
    try router.routeWithMiddleware(.GET, "/blocked", Handler.init(NoopHandler, &noop), &.{mw});

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/blocked", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expectEqual(@as(http.Status, .forbidden), ctx.blocked_status.?);
    // 拦截路径：状态码已写入响应
    try std.testing.expectEqual(@as(http.Status, .forbidden), res.status);
}

test "integration - middleware passes through with .next" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var middleware_called = false;
    var handler_called = false;

    const PassMiddleware = struct {
        called: *bool,
        pub fn process(self: *@This(), ctx: *RequestContext, res: *Response) anyerror!Middleware.NextAction {
            _ = ctx;
            _ = res;
            self.called.* = true;
            return .next;
        }
    };
    var mw_state = PassMiddleware{ .called = &middleware_called };
    const mw = Middleware.init(PassMiddleware, &mw_state);

    var h = BoolFlag{ .flag = &handler_called };
    try router.routeWithMiddleware(.GET, "/pass", Handler.init(BoolFlag, &h), &.{mw});

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/pass", null, null);
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
        pub fn process(_: *@This(), ctx: *RequestContext, res: *Response) anyerror!Middleware.NextAction {
            _ = ctx;
            _ = res;
            return .err;
        }
    };

    var err_mw = ErrMiddleware{};
    const mw = Middleware.init(ErrMiddleware, &err_mw);

    var handler_called = false;
    var h = BoolFlag{ .flag = &handler_called };
    try router.routeWithMiddleware(.GET, "/err", Handler.init(BoolFlag, &h), &.{mw});

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/err", null, null);
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

    var ctx1_storage: MockStorage = .{};
    var ctx1 = try createMockRequest(&ctx1_storage, allocator, .GET, "/count", null, null);
    defer ctx1.deinit();
    var res1 = try createMockResponse(allocator, &ctx1);
    defer res1.deinit();
    _ = try router.dispatch(&ctx1, &res1);
    try std.testing.expectEqual(@as(u32, 1), counter.count);

    var ctx2_storage: MockStorage = .{};
    var ctx2 = try createMockRequest(&ctx2_storage, allocator, .GET, "/count", null, null);
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
    // Context 由 router.deinit() 通过 handler.deinit() 统一回收
    try router.route(.GET, "/per-req", handler);

    // 第一次请求
    {
        var ctx_storage: MockStorage = .{};
        var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/per-req", null, null);
        defer ctx.deinit();
        var res = try createMockResponse(allocator, &ctx);
        defer res.deinit();
        _ = try router.dispatch(&ctx, &res);
    }

    // 第二次请求
    {
        var ctx_storage: MockStorage = .{};
        var ctx = try createMockRequest(&ctx_storage, allocator, .GET, "/per-req", null, null);
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

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .POST, "/data", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    try std.testing.expect(!handler_called);
    // 405：状态码已设置，且带 Allow 头
    try std.testing.expectEqual(@as(http.Status, .method_not_allowed), res.status);
    var has_allow = false;
    for (res.headers.items) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "Allow")) {
            // 注册的是 GET，但 HEAD 会自动回落到它，Allow 必须如实列出两个
            try std.testing.expectEqualStrings("GET, HEAD", hdr.value);
            has_allow = true;
        }
    }
    try std.testing.expect(has_allow);
}

// ===========================================================================
// 测试：HEAD 自动回落（RFC 9110 §9.3.2）
// ===========================================================================

test "integration - HEAD falls back to the GET route" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var handler_called = false;
    var h = BoolFlag{ .flag = &handler_called };
    try router.route(.GET, "/data", Handler.init(BoolFlag, &h));

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .HEAD, "/data", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    const dispatched = try router.dispatch(&ctx, &res);
    try std.testing.expect(dispatched);
    // GET 的 handler 被复用，而不是 405
    try std.testing.expect(handler_called);
    try std.testing.expectEqual(@as(http.Status, .ok), res.status);
}

test "integration - explicit HEAD route wins over the GET fallback" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var get_called = false;
    var head_called = false;
    var get_h = BoolFlag{ .flag = &get_called };
    var head_h = BoolFlag{ .flag = &head_called };

    // GET 先注册：如果回落逻辑不先探显式 HEAD，就会错误地命中 GET
    try router.route(.GET, "/data", Handler.init(BoolFlag, &get_h));
    try router.route(.HEAD, "/data", Handler.init(BoolFlag, &head_h));

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .HEAD, "/data", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expect(head_called);
    try std.testing.expect(!get_called);
}

test "integration - HEAD on a POST-only route still returns 405" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    var handler_called = false;
    var h = BoolFlag{ .flag = &handler_called };
    try router.route(.POST, "/submit", Handler.init(BoolFlag, &h));

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .HEAD, "/submit", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expect(!handler_called);
    // 回落到 GET 也没有 GET 路由 → 依然 405，且 Allow 里不该出现 HEAD
    try std.testing.expectEqual(@as(http.Status, .method_not_allowed), res.status);
    for (res.headers.items) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "Allow")) {
            try std.testing.expectEqualStrings("POST", hdr.value);
        }
    }
}

test "integration - HEAD keeps path params from the GET route" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const ParamCapture = struct {
        seen: *[]const u8,
        pub fn handle(self: *@This(), c: *RequestContext, _: *Response) !void {
            self.seen.* = c.getParam("id") orelse "";
        }
    };
    var seen: []const u8 = "";
    var h = ParamCapture{ .seen = &seen };
    try router.route(.GET, "/users/:id", Handler.init(ParamCapture, &h));

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .HEAD, "/users/42", null, null);
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expectEqualStrings("42", seen);
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

    var ctx_storage: MockStorage = .{};
    var ctx = try createMockRequest(&ctx_storage, allocator, .POST, "/echo", null, "hello-body");
    defer ctx.deinit();
    var res = try createMockResponse(allocator, &ctx);
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try std.testing.expectEqualStrings("hello-body", body_content);
}
