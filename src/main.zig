//! http_framework — 入口示例
//!
//! 展示完整架构的使用方式：4 层模块 + 中间件管道 + 生命周期钩子。
//! 包含 JSON body 解析、multipart 文件上传、响应压缩等完整功能。

const std = @import("std");
const framework = @import("http_framework");
const builtin = @import("builtin");
/// Debug 模式下的全局分配器实例（泄漏检测）。
pub fn main() !void {
    // 0. allocator
    // Debug 模式用 DebugAllocator（逐分配追踪 + 退出时泄漏检测）；
    // Release 用全局 Arena（线程安全，进程生命周期内存，退出时一次性释放）。
    // DebugAllocator(.{ .safety = false }) 关闭逐分配跟踪，减少元数据开销。
    var release_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var debug_allocator_instance = std.heap.DebugAllocator(.{ .safety = false }){};

    const allocator: std.mem.Allocator = if (builtin.mode == .debug) blk: {
        break :blk debug_allocator_instance.allocator();
    } else release_arena.allocator();
    defer {
        if (builtin.mode == .debug) {
            if (debug_allocator_instance.deinit() == .leak) {
                std.debug.panic("memory leak {}", .{@src()});
            }
        } else {
            release_arena.deinit();
        }
    }
    // 1. 初始化 Io
    // concurrent_limit 限制线程池大小，防止压测时无限扩展线程。
    // 默认 = CPU 核心数 - 1。每线程栈 512KB+，1000 并发时线程池不收缩
    // → 内存不回收。显式限制可控制常驻内存上限。
    var io_state = std.Io.Threaded.init(allocator, .{
        .concurrent_limit = .limited(128),
    });
    const io = io_state.io();

    // 2. 配置
    const config = framework.Config{
        .network = .{ .port = 9000 },
        .http = .{ .access_log_enabled = true },
        .body = .{ .size_limit = 10 * 1024 * 1024 },
        // 降低 arena 保留容量：16KB → 4KB，1000 并发时减少 12MB 常驻内存
        .pool = .{ .request_arena_retain_bytes = 4 * 1024 },
    };

    // 3. 路由
    var router = try framework.Router.init(allocator);
    defer router.deinit();

    // ── 基础路由 ──────────────────────────────────────────────
    try router.route(.GET, "/", framework.Handler.fromFn(helloHandler));
    try router.route(.GET, "/users/:id", framework.Handler.fromFn(userHandler));
    try router.route(.GET, "/health", framework.Handler.fromFn(healthHandler));

    // 单例 handler
    var api_handler = ApiHandler{ .request_count = 0 };
    try router.route(.GET, "/api", framework.Handler.initSingleton(ApiHandler, &api_handler));

    // ── JSON body 解析示例 ────────────────────────────────────
    try router.route(.POST, "/login", framework.Handler.fromFn(loginHandler));

    // ── Multipart 文件上传示例 ───────────────────────────────
    try router.route(.POST, "/upload", framework.Handler.fromFn(uploadHandler));

    // 静态文件服务
    var static_server = framework.StaticFileServer.init(
        allocator,
        io,
        "./public",
        "/static",
    );
    try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &static_server));

    // ── 结构化日志器（全局单例）────────────────────────────────
    // 文件输出：超过 16 MiB 自动轮转，归档文件 gzip 压缩，最多保留 5 个备份。
    var logger = try framework.Logger.init(allocator, io, .{
        .min_level = .info,
        .format = .json,
        .output = .file,
        .file = .{ .path = "log/zighttp.log", .max_size = 2 * 1024 * 1024, .max_backups = 1, .compress = true },
    });
    defer logger.deinit();
    logger.info(null, "server starting", &.{
        framework.fstr("addr", config.network.address),
        framework.fint("port", config.network.port),
    });

    // ── 中间件管道 ────────────────────────────────────────────

    // 错误渲染（应放最外层，兜底所有错误）
    var error_renderer = framework.ErrorRenderer{};
    try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));

    // Request ID（紧跟 ErrorRenderer，让下游所有中间件/handler 都能取到 ID）
    var rid_mw = framework.RequestIdMiddleware{};
    try router.use(framework.Middleware.init(framework.RequestIdMiddleware, &rid_mw));

    // 响应压缩
    var compress_mw = framework.CompressMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CompressMiddleware, &compress_mw));

    // 计时中间件
    var timing_mw = TimingMiddleware{};
    try router.use(framework.Middleware.init(TimingMiddleware, &timing_mw));

    // 安全头
    var security_mw = framework.SecurityHeaders{ .config = .{} };
    try router.use(framework.Middleware.init(framework.SecurityHeaders, &security_mw));

    // CORS（不再持有 arena 字段——CORS 头用请求级 ctx.arena 分配）
    var cors_mw = framework.CorsMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CorsMiddleware, &cors_mw));

    // 速率限制（全局 100 req/分钟）
    // var rate_mw = framework.RateLimiter.init(allocator, io, .{
    //     .window_seconds = 60,
    //     .max_requests = 100,
    //     .per_ip = false,
    // });
    // try router.use(framework.Middleware.init(framework.RateLimiter, &rate_mw));

    // 4. 生命周期钩子（结构化日志 Hook——利用 server 计算的 duration/status）
    var log_hook = framework.LoggingHook{ .logger = &logger };
    const hooks = [_]framework.Hook{
        framework.Hook.init(framework.LoggingHook, &log_hook),
    };

    // 5. 组装 Server
    var server = try framework.Server.init(allocator, io, config, &router);
    defer server.deinit();
    try server.setup();
    server.setLifecycle(.{ .hooks = &hooks });
    // 6. 注册信号处理器（SIGINT/SIGTERM → server.beginShutdown）
    server.installSignalHandlers();

    std.log.info("Server starting on {s}:{d}", .{ config.network.address, config.network.port });

    try server.run();
}

// ── Handlers ──────────────────────────────────────────────────

fn helloHandler(ctx: *framework.Context, res: *framework.Response) !void {
    _ = ctx;
    try res.statusCode(.ok).text("Hello, World!");
}

fn userHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const id = ctx.param("id") orelse {
        try ctx.failWith(res, .{ .status = .bad_request, .message = "Missing id" });
        return;
    };
    try res.statusCode(.ok).html("<h1>User ");
    try res.html(id);
}

fn healthHandler(ctx: *framework.Context, res: *framework.Response) !void {
    _ = ctx;
    try res.json(.{ .status = "ok", .timestamp = 42 });
}

// 单例 handler
const ApiHandler = struct {
    request_count: u32,

    pub fn handle(self: *ApiHandler, _: *framework.Context, res: *framework.Response) !void {
        self.request_count += 1;
        try res.json(.{ .endpoint = "api", .requests = self.request_count });
    }
};

// ── JSON body 解析示例 ────────────────────────────────────────

const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
};

/// 用 curl 测试：
/// curl -X POST -H "Content-Type: application/json" \
///   -d '{"username":"alice","password":"secret"}' \
///   http://127.0.0.1:9000/login
fn loginHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const body = framework.parseJson(LoginRequest, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, .{ .status = .bad_request, .message = "failed to read body" });
        return;
    }) catch {
        try ctx.failWith(res, .{ .status = .bad_request, .message = "invalid JSON body" });
        return;
    };

    // 实际应用这里应该查数据库验证密码
    if (std.mem.eql(u8, body.username, "alice") and std.mem.eql(u8, body.password, "secret")) {
        try res.json(.{ .ok = true, .user = body.username });
    } else {
        try ctx.failWith(res, .{ .status = .unauthorized, .message = "invalid credentials" });
    }
}

// ── Multipart 文件上传示例 ───────────────────────────────────

/// 用 curl 测试：
/// curl -X POST -F "username=bob" -F "avatar=@photo.png" \
///   http://127.0.0.1:9000/upload
fn uploadHandler(ctx: *framework.Context, res: *framework.Response) !void {
    var form = framework.multipartFrom(ctx, 10 * 1024 * 1024) catch {
        try ctx.failWith(res, .{ .status = .bad_request, .message = "not a multipart request" });
        return;
    };
    defer form.deinit();

    const username = form.getText("username") orelse "anonymous";

    if (form.getFile("avatar")) |file| {
        const file_name = file.file_name orelse "upload.bin";
        const msg = try std.fmt.allocPrint(
            ctx.arena,
            "uploaded \"{s}\" ({d} bytes, {s}) by {s}",
            .{
                file_name,
                file.data.len,
                file.content_type orelse "unknown",
                username,
            },
        );
        try res.text(msg);
        return;
    }

    try ctx.failWith(res, .{ .status = .bad_request, .message = "no file field \"avatar\" found" });
}

// ── Middleware ────────────────────────────────────────────────

const TimingMiddleware = struct {
    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        _ = self;
        // 启用缓冲模式——保证 next() 返回后还能修改头。
        // 不调 flush()：让外层（CompressMiddleware / ErrorRenderer /
        // ConnectionRunner 兜底）负责最终发送。
        res.setBuffered();
        const start = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;
        // 错误时也要加 timing 头——计时应该包含错误处理时间，
        // 且 ErrorRenderer 在外层兑底时已经能看到这个头（fix.md §三.1）。
        next.call(ctx, res) catch |err| {
            const elapsed_err = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
            _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed_err}) catch "?");
            return err;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
        _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
    }
};
