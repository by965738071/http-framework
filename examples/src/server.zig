//! 演示服务器
//!
//! 综合展示 http_framework 全部功能：
//! - 路由、处理器（纯函数/单例/请求级）
//! - 中间件（日志、Auth、CORS、RateLimiter）
//! - Session / WebSocket / 后台任务
//! - 静态文件 / JSON / HTML 渲染
//! - 性能指标（/metrics）

const std = @import("std");
const http = std.http;

pub const http_framework = @import("http_framework");
const Server = http_framework.Server;
const Router = http_framework.Router;
const Handler = http_framework.Handler;
const RequestContext = http_framework.RequestContext;
const Response = http_framework.Response;
const Config = http_framework.Config;
const Middleware = http_framework.Middleware;
const NextAction = http_framework.Middleware.NextAction;
const AuthMiddleware = http_framework.AuthMiddleware;
const AuthConfig = http_framework.AuthConfig;
const CorsMiddleware = http_framework.CorsMiddleware;
const RateLimiter = http_framework.RateLimiter;
const RateLimitConfig = http_framework.RateLimitConfig;
const SessionManager = http_framework.SessionManager;
const BackgroundQueue = http_framework.BackgroundQueue;
const MetricsCollector = http_framework.MetricsCollector;
const WebSocketManager = http_framework.WebSocketManager;
const WsEchoHandler = http_framework.WsEchoHandler;
const Static = http_framework.Static;
const Validation = http_framework.Validation;

// =========================================================================
// 应用状态
// =========================================================================

const AppState = struct {
    session_mgr: SessionManager,
    bg_queue: BackgroundQueue,
    ws_manager: WebSocketManager,
    start_time: i128,

    fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        return .{
            .session_mgr = SessionManager.init(allocator, io),
            .bg_queue = try BackgroundQueue.init(allocator, io),
            .ws_manager = WebSocketManager.init(allocator, io),
            .start_time = std.Io.Clock.now(.real, io).nanoseconds,
        };
    }

    fn deinit(self: *AppState) void {
        self.ws_manager.deinit();
        self.bg_queue.deinit();
        self.session_mgr.deinit();
    }
};

// =========================================================================
// 中间件：请求日志
// =========================================================================

const LoggingMiddleware = struct {
    pub fn process(_: *@This(), ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = res;
        std.log.info("[LOG] {s} {s}", .{ @tagName(ctx.method), ctx.path });
        return .next;
    }
};

// =========================================================================
// 中间件：请求计时
// =========================================================================

const TimingMiddleware = struct {
    pub fn process(_: *@This(), ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = ctx;
        _ = res;
        return .next;
    }
};

// =========================================================================
// 处理器
// =========================================================================

// ── Home（纯函数）─────────────────────────────────────────

fn homeHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.html(
        \\<!DOCTYPE html><html><body>
        \\<h1>Zig HTTP Framework</h1>
        \\<p><a href="/api/health">/api/health</a></p>
        \\<p><a href="/api/hello">/api/hello</a></p>
        \\<p><a href="/metrics">/metrics</a></p>
        \\<p><a href="/static/test.html">/static/test.html</a></p>
        \\<p><a href="/ws">/ws (WebSocket)</a></p>
        \\</body></html>
    );
}

// ── Health（纯函数）────────────────────────────────────────

fn healthHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.json(.{
        .status = "ok",
        .service = "zig-http-framework",
    });
}

// ── Hello（纯函数，演示 AuthInfo）──────────────────────────

fn helloHandler(ctx: *RequestContext, res: *Response) !void {
    if (ctx.getUserData(http_framework.AuthInfo)) |info| {
        try res.json(.{
            .message = "Hello, authenticated user!",
            .strategy = @tagName(info.strategy),
        });
    } else {
        try res.json(.{
            .message = "Hello, guest!",
            .note = "Add Authorization header to authenticate",
        });
    }
}

// ── Counter（单例）──────────────────────────────────────────

const CounterHandler = struct {
    counter: std.atomic.Value(u64),

    pub fn handle(self: *@This(), _: *RequestContext, res: *Response) !void {
        const val = self.counter.fetchAdd(1, .monotonic);
        try res.json(.{ .count = val });
    }
};

// ── UserHandler（请求级，演示路径参数）──────────────────────

const UserHandler = struct {
    default_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .default_name = args.default_name };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        const id = ctx.getParam("id") orelse "unknown";
        const name = ctx.getQuery("name") orelse self.default_name;
        try res.json(.{ .id = id, .name = name });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// ── Echo（POST，纯函数）─────────────────────────────────────

fn echoHandler(ctx: *RequestContext, res: *Response) !void {
    const body = try ctx.readBody();
    try res.json(.{ .echo = body });
}

// ── 速率限制状态（纯函数）───────────────────────────────────

fn rateLimitStatusHandler(_: *RequestContext, res: *Response) !void {
    try res.json(.{
        .rate_limit = "100 requests per 60 seconds per IP",
        .note = "Check X-RateLimit-* headers in response",
    });
}

// ── Metrics（纯函数）─────────────────────────────────────────

fn metricsHandler(_: *RequestContext, res: *Response) !void {
    try res.json(.{
        .service = "zig-http-framework",
        .version = "0.1.0",
    });
}

// ── 认证信息（纯函数）────────────────────────────────────────

fn authInfoHandler(ctx: *RequestContext, res: *Response) !void {
    if (ctx.getUserData(http_framework.AuthInfo)) |info| {
        try res.json(.{ .authenticated = true, .strategy = @tagName(info.strategy) });
    } else {
        try res.json(.{ .authenticated = false });
    }
}

// ── Status 端点（纯函数）─────────────────────────────────────

fn statusHandler(_: *RequestContext, res: *Response) !void {
    try res.json(.{ .status = "running", .service = "demo" });
}

// ── Session 演示（请求级）────────────────────────────────────

const SessionDemoHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        const sid = try self.state.session_mgr.getOrCreate(ctx, res);
        try self.state.session_mgr.setData(sid, "visited", "true");
        try res.json(.{ .session_id = sid, .message = "Session created/updated" });
    }

    pub fn deinit(_: *@This()) void {}
};

// ── 后台任务演示（请求级）────────────────────────────────────

const BackgroundDemoHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), _: *RequestContext, res: *Response) !void {
        const Ctx = struct {
            message: []const u8,
            fn run(self2: *@This()) void {
                std.log.info("[BACKGROUND] {s}", .{self2.message});
            }
        };
        var bg_ctx = Ctx{ .message = "Hello from background task!" };
        self.state.bg_queue.submit(Ctx, &bg_ctx, Ctx.run) catch {};
        self.state.bg_queue.drain() catch {};
        try res.json(.{ .background = "submitted" });
    }

    pub fn deinit(_: *@This()) void {}
};

// ── WebSocket 状态（纯函数）─────────────────────────────────

fn wsStatusHandler(_: *RequestContext, res: *Response) !void {
    try res.json(.{ .websocket = "ws://localhost:9000/ws" });
}

// ── WebSocket 首页（纯函数）─────────────────────────────────

fn wsHomeHandler(_: *RequestContext, res: *Response) !void {
    try res.html(
        \\<!DOCTYPE html><html><body>
        \\<h1>WebSocket Echo</h1>
        \\<script>
        \\const ws=new WebSocket("ws://"+location.host+"/ws");
        \\ws.onmessage=function(e){document.body.innerHTML+="<p>Echo: "+e.data+"</p>";};
        \\ws.onopen=function(){ws.send("Hello WebSocket!");};
        \\</script>
        \\</body></html>
    );
}

// ── CORS 演示（纯函数）──────────────────────────────────────

fn corsHandler(ctx: *RequestContext, res: *Response) !void {
    try res.json(.{
        .message = "CORS-enabled endpoint",
        .origin = ctx.getHeader("Origin") orelse "(no Origin)",
    });
}

// ── Static 演示（纯函数）────────────────────────────────────

fn staticInfoHandler(_: *RequestContext, res: *Response) !void {
    try res.json(.{ .static = "Static files served from /static/" });
}

// ── 404 ────────────────────────────────────────────────────

fn notFoundHandler(_: *RequestContext, res: *Response) !void {
    try res.statusCode(.not_found).json(.{
        .@"error" = "Not found",
        .message = "The requested endpoint does not exist",
    });
}

// =========================================================================
// main
// =========================================================================

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // ── 全局状态 ─────────────────────────────────────
    var state = try AppState.init(allocator, io);
    defer state.deinit();

    // ── 路由器 ───────────────────────────────────────
    var router = Router.init(allocator);
    defer router.deinit();

    // ── 中间件 ───────────────────────────────────────

    // 日志
    var logging = LoggingMiddleware{};
    const log_mw = Middleware.init(LoggingMiddleware, &logging);
    var timing = TimingMiddleware{};
    _ = &timing;

    // Auth（支持 Bearer / Basic / API Key）
    var auth = try AuthMiddleware.create(allocator, .{
        .bearer_token = "my-secret-token",
        .basic_username = "admin",
        .basic_password = "secret123",
        .api_key = "my-api-key-123",
        .api_key_query = true,
    });
    defer auth.deinit();

    // CORS
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE, .OPTIONS },
        .allow_credentials = true,
    });
    defer cors.deinit();

    // RateLimiter（100 req/min）
    var rate_limiter = try RateLimiter.init(allocator, io, .{
        .window_seconds = 60,
        .max_requests = 100,
        .per_ip = true,
    });
    defer rate_limiter.deinit();

    // ── WebSocket ─────────────────────────────────────
    const ws_handler = try WsEchoHandler.init(allocator, &state.ws_manager);
    defer ws_handler.deinit();

    // ── 注册路由 ─────────────────────────────────────

    // 公开端点
    try router.route(.GET, "/", Handler.fromFn(homeHandler));
    try router.route(.GET, "/api/health", Handler.fromFn(healthHandler));
    try router.route(.GET, "/api/status", Handler.fromFn(statusHandler));
    try router.route(.GET, "/metrics", Handler.fromFn(metricsHandler));
    try router.route(.GET, "/ws", http_framework.Handler.init(http_framework.WsEchoHandler, ws_handler));
    try router.route(.GET, "/ws-home", Handler.fromFn(wsHomeHandler));
    try router.route(.POST, "/api/echo", Handler.fromFn(echoHandler));

    // 路径参数 & 查询参数（请求级处理器）
    try router.route(.GET, "/users/:id", try Handler.initPerRequestWith(
        UserHandler,
        allocator,
        .{ .default_name = "Guest", .allocator = allocator },
    ));

    // 计数器（单例处理器）
    const counter = try allocator.create(CounterHandler);
    counter.* = .{ .counter = std.atomic.Value(u64).init(0) };
    try router.route(.GET, "/count", Handler.init(CounterHandler, counter));

    // Session 演示
    try router.route(.GET, "/session-demo", try Handler.initPerRequestWith(
        SessionDemoHandler,
        allocator,
        .{ .state = &state },
    ));

    // 后台任务演示
    try router.route(.GET, "/background-demo", try Handler.initPerRequestWith(
        BackgroundDemoHandler,
        allocator,
        .{ .state = &state },
    ));

    // 静态文件
    // 兼容从不同工作目录启动（仓库根 / examples / examples/zig-out/bin）：
    // 向上查找第一个存在的 public 目录，避免相对路径解析失败。
    const public_candidates = [_][]const u8{ "public", "../public", "../../public" };
    var public_root: []const u8 = "public";
    for (public_candidates) |cand| {
        const probe = try std.fs.path.join(allocator, &.{ cand, "index.html" });
        defer allocator.free(probe);
        _ = std.Io.Dir.cwd().statFile(io, probe, .{}) catch continue;
        public_root = cand;
        break;
    }
    var static_server = Static.init(allocator, io, public_root, "/static");
    try router.route(.GET, "/static/*", Handler.init(Static, &static_server));

    // ── 受保护路由（需要中间件）────────────────────

    // Auth 保护
    try router.routeWithMiddleware(.GET, "/api/hello", Handler.fromFn(helloHandler), &.{
        auth.middle, log_mw,
    });
    try router.routeWithMiddleware(.GET, "/api/me", Handler.fromFn(authInfoHandler), &.{
        auth.middle, log_mw,
    });

    // RateLimiter 保护
    try router.routeWithMiddleware(.GET, "/rate-limit/status", Handler.fromFn(rateLimitStatusHandler), &.{
        rate_limiter.middleware, log_mw,
    });

    // CORS 端点
    try router.routeWithMiddleware(.GET, "/cors/test", Handler.fromFn(corsHandler), &.{
        cors.middleware, log_mw,
    });

    // WebSocket 状态（受速率限制）
    try router.routeWithMiddleware(.GET, "/ws-status", Handler.fromFn(wsStatusHandler), &.{
        rate_limiter.middleware, log_mw,
    });

    // ── 404 ──────────────────────────────────────────
    router.notFound(Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ───────────────────────────────────
    const config = Config{ .port = 9000 };
    var server = try Server.init(allocator, io, config, &router);
    defer server.deinit();

    // CORS 走全局中间件；后台队列实现 core.Worker，由 Server 周期 tick。
    try router.use(&.{cors.middleware});
    server.setWorker(state.bg_queue.worker());

    std.log.info("Server starting on http://127.0.0.1:9000", .{});
    std.log.info("Endpoints:", .{});
    std.log.info("  GET  /              — Home", .{});
    std.log.info("  GET  /api/health    — Health check", .{});
    std.log.info("  GET  /api/hello     — Auth demo (Bearer/Basic/API Key)", .{});
    std.log.info("  GET  /api/me        — Auth info", .{});
    std.log.info("  GET  /api/status    — Status", .{});
    std.log.info("  GET  /api/echo      — Echo POST body", .{});
    std.log.info("  GET  /users/:id     — Path params demo", .{});
    std.log.info("  GET  /count         — Counter (singleton)", .{});
    std.log.info("  GET  /session-demo  — Session demo", .{});
    std.log.info("  GET  /background-demo — Background task demo", .{});
    std.log.info("  GET  /rate-limit/status — Rate limiter demo", .{});
    std.log.info("  GET  /cors/test     — CORS demo", .{});
    std.log.info("  GET  /ws            — WebSocket echo", .{});
    std.log.info("  GET  /ws-home       — WebSocket HTML page", .{});
    std.log.info("  GET  /static/*      — Static files", .{});
    std.log.info("  GET  /metrics       — Service metrics", .{});

    try server.run();
}
