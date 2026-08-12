//! 程序入口 (Zig 0.17-dev)
//!
//! 演示如何使用 http_framework 创建 HTTP 服务器、注册路由及 WebSocket。

const std = @import("std");
const Io = std.Io;
const fw = @import("http_framework");
const Server = fw.Server;
const Router = fw.Router;
const RequestContext = fw.RequestContext;
const Response = fw.Response;
const Handler = fw.Handler;
const Config = fw.Config;
const Static = fw.Static;
const WebSocketManager = fw.WebSocketManager;
const WsEchoHandler = fw.WsEchoHandler;
const CorsMiddleware = fw.CorsMiddleware;
const RateLimiter = fw.RateLimiter;
const MetricsCollector = fw.MetricsCollector;
const FileLogger = fw.FileLogger;
const HomeHandler = @import("api/home.zig");
const UserHandler = @import("api/user.zig");

pub fn main(init: std.process.Init) !void {
    // ── 分配器 ──────────────────────────────────────────
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // ── 解析命令行参数（获取静态文件目录）───────────────

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit(); // Windows/WASI 下迭代器持有内部缓冲，必须释放
    var static_dir: []const u8 = "public"; // 默认值

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--static-dir") or std.mem.eql(u8, arg, "-s")) {
            const dir = args.next() orelse {
                std.log.err("Missing value for --static-dir", .{});
                return error.InvalidArgs;
            };
            static_dir = dir;
            break;
        }
    }

    // ── 路由器 ──────────────────────────────────────────
    var router = Router.init(allocator);
    defer router.deinit();

    // ── CORS / RateLimiter / Metrics ───────────────
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{.GET},
    });
    defer cors.deinit();

    // CORS 是普通的全局中间件，Server 不再为它开专用钩子。
    // 全局中间件在路由匹配之前执行，因此 OPTIONS 预检照样能绕过路由表。
    try router.use(&.{cors.middleware});

    var rate_limiter = try RateLimiter.init(allocator, io, .{
        .window_seconds = 60,
        .max_requests = 100,
    });
    defer rate_limiter.deinit();

    var metrics = MetricsCollector.init(allocator, io);
    defer metrics.deinit();

    // ── WebSocket 管理器 & 处理器 ─────────────────────
    var ws_manager = WebSocketManager.init(allocator, io);
    defer ws_manager.deinit();

    var ws_echo = try WsEchoHandler.init(allocator, &ws_manager);
    defer ws_echo.deinit();

    // ── HTTP 路由 ───────────────────────────────────────
    try router.route(.GET, "/", try Handler.initPerRequest(HomeHandler, allocator));
    try router.route(.GET, "/users/:id", try Handler.initPerRequestWith(
        UserHandler,
        allocator,
        .{ .default_name = "John Doe" },
    ));

    // Rate-limited endpoint
    try router.routeWithMiddleware(.GET, "/api/limited", Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.ok).json(.{ .message = "rate-limited endpoint" });
        }
    }.handler), &.{rate_limiter.middleware});

    // Metrics endpoint (uses server.metrics)
    try router.route(.GET, "/metrics", Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.ok).text("Metrics: see server logs for report");
        }
    }.handler));

    // 404 处理
    router.notFound(Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler));

    // WebSocket 路由（单例模式）
    try router.route(.GET, "/ws", Handler.init(WsEchoHandler, ws_echo));

    // ── 静态文件服务（动态路径）─────────────────────────

    var static_server = Static.init(allocator, io, static_dir, "/static");
    try router.route(.GET, "/static/*", Handler.init(Static, &static_server));

    // ── 日志：core 只认 Logger 接口，轮转/异步都在 observability 里 ──
    var file_logger = try FileLogger.init(allocator, io, "./log/zighttp.log", .{
        .async_enabled = true,
        .min_level = .debug,
        .utc_offset_seconds = 8 * 3600,
    });
    defer file_logger.deinit();

    // ── 服务器 ─────────────────────────────────────────
    var server = try Server.init(allocator, io, Config{}, &router);
    defer server.deinit();
    server.setLogger(file_logger.logger());
    server.setObserver(metrics.observer());
    try server.run();
}
