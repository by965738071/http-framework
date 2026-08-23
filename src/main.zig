//! http_framework — 入口示例
//!
//! 入口只做两件事：
//!   1. 通过 framework.runZio 启动运行时（封装了 zio 初始化，入口不直接依赖 zio）；
//!   2. 在 appMain(io, allocator) 里做 http_framework 的初始化（路由/中间件/Server）。

const std = @import("std");
const framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    _ = init;
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer{
        if(debug_allocator.deinit() == .leak) {
            std.debug.panic("memory leak", .{});
        }
    }
    const allocator = debug_allocator.allocator();
    try framework.runZio(allocator, appMain);
}

fn appMain(io: std.Io, allocator: std.mem.Allocator) !void {
    // 1. 配置
    const config = framework.Config{
        .network = .{ .port = 9000 },
        .http = .{ .access_log_enabled = true },
        .body = .{ .size_limit = 10 * 1024 * 1024 },
        .pool = .{ .request_arena_retain_bytes = 4 * 1024 },
    };

    // 2. 路由
    var router = try framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/", framework.Handler.fromFn(helloHandler));
    try router.route(.GET, "/users/:id", framework.Handler.fromFn(userHandler));
    try router.route(.GET, "/health", framework.Handler.fromFn(healthHandler));

    var api_handler = ApiHandler{ .request_count = 0 };
    try router.route(.GET, "/api", framework.Handler.initSingleton(ApiHandler, &api_handler));
    try router.route(.POST, "/login", framework.Handler.fromFn(loginHandler));
    try router.route(.POST, "/upload", framework.Handler.fromFn(uploadHandler));

    var static_server = framework.StaticFileServer.init(allocator, io, "./public", "/static");
    try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &static_server));

    // 3. 日志器
    var logger = try framework.Logger.init(allocator, io, .{
        .min_level = .info,
        .format = .json,
        .output = .file,
        .file = .{ .path = "log/zighttp.log", .max_size = 2 * 1024 * 1024, .max_backups = 1, .compress = true },
    });
    defer logger.deinit();

    // 4. 中间件管道
    var error_renderer = framework.ErrorRenderer{};
    try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));
    var rid_mw = framework.RequestIdMiddleware{};
    try router.use(framework.Middleware.init(framework.RequestIdMiddleware, &rid_mw));
    var compress_mw = framework.CompressMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CompressMiddleware, &compress_mw));
    var timing_mw = TimingMiddleware{};
    try router.use(framework.Middleware.init(TimingMiddleware, &timing_mw));
    var security_mw = framework.SecurityHeaders{ .config = .{} };
    try router.use(framework.Middleware.init(framework.SecurityHeaders, &security_mw));
    var cors_mw = framework.CorsMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CorsMiddleware, &cors_mw));

    // 5. 生命周期钩子
    var log_hook = framework.LoggingHook{ .logger = &logger };
    const hooks = [_]framework.Hook{framework.Hook.init(framework.LoggingHook, &log_hook)};

    // 6. 组装并运行 Server
    var server = try framework.Server.init(allocator, io, config, &router);
    defer server.deinit();
    try server.setup();
    server.setLifecycle(.{ .hooks = &hooks });

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
        const start = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
        // 错误时也要加 timing 头——计时应该包含错误处理时间，
        // 且 ErrorRenderer 在外层兑底时已经能看到这个头（fix.md §三.1）。
        next.call(ctx, res) catch |err| {
            const elapsed_err = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
            _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed_err}) catch "?");
            return err;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
        _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
    }
};
