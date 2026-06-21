//! 中间件演示
//!
//! 展示 http_framework 所有中间件能力：
//! - Auth 中间件（Bearer / Basic / API Key）
//! - CORS 中间件
//! - RateLimiter 中间件
//! - 自定义日志中间件
//! - 中间件链（多个中间件按顺序执行）
//! - 中间件阻止请求（.respond / .err）
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build run-middleware-demo
//! ```
//!
//! # 测试
//!
//! ```bash
//! # Bearer 认证（通过）
//! curl -H "Authorization: Bearer my-secret-token" http://localhost:9000/api/hello
//!
//! # Bearer 认证（失败 → 401）
//! curl http://localhost:9000/api/hello
//!
//! # Basic 认证
//! curl -H "Authorization: Basic $(echo -n 'admin:secret123' | base64)" \
//!   http://localhost:9000/basic/hello
//!
//! # API Key 认证（Header）
//! curl -H "X-API-Key: my-api-key-123" http://localhost:9000/api/hello
//!
//! # API Key 认证（Query 参数）
//! curl "http://localhost:9000/api/hello?api_key=my-api-key-123"
//!
//! # 速率限制（第 101 次请求会被 429）
//! for i in $(seq 1 110); do curl -s -o /dev/null -w "%{http_code}\n" \
//!   http://localhost:9000/api/hello; done | sort | uniq -c
//! ```

const std = @import("std");
const http = std.http;
const base64 = std.base64;

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
const CorsConfig = http_framework.CorsConfig;
const RateLimiter = http_framework.RateLimiter;
const RateLimitConfig = http_framework.RateLimitConfig;

// =========================================================================
// 自定义中间件：请求日志
// =========================================================================

const LoggingMiddleware = struct {
    label: []const u8,

    pub fn process(self: *@This(), ctx: *RequestContext) anyerror!NextAction {
        std.log.info("[{s}] {s} {s}", .{
            self.label,
            @tagName(ctx.method),
            ctx.path,
        });
        return .next;
    }
};

// =========================================================================
// 自定义中间件：添加自定义响应头
// =========================================================================

const CustomHeadersMiddleware = struct {
    pub fn process(_: *@This(), ctx: *RequestContext) anyerror!NextAction {
        _ = ctx;
        return .next;
    }

    /// 在 handler 返回后、响应发送前调用（通过框架 hook）
    /// 这里演示：在 process 中直接返回 .next，
    /// 然后在 handler 中手动调用 addCustomHeaders
    pub fn addHeaders(_: *@This(), res: *Response) !void {
        _ = try res.header("X-Powered-By", "ZigHTTP-Framework");
        _ = try res.header("X-Request-ID", "demo-id-12345");
    }
};

// =========================================================================
// 处理器：Hello（纯函数）
// =========================================================================

fn helloHandler(ctx: *RequestContext, res: *Response) !void {
    // 演示：从 ctx 获取认证信息
    if (ctx.getUserData(http_framework.AuthInfo)) |info| {
        const strategy_name = switch (info.strategy) {
            .bearer => "Bearer",
            .basic => "Basic",
            .api_key => "API Key",
            .custom => "Custom",
        };
        try res.json(.{
            .message = "Hello, authenticated user!",
            .strategy = strategy_name,
        });
    } else {
        try res.json(.{
            .message = "Hello, guest!",
            .note = "Add Authorization header to authenticate",
        });
    }
}

// =========================================================================
// 处理器：Basic auth 专属
// =========================================================================

fn basicHelloHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.json(.{
        .message = "Hello from Basic Auth protected endpoint!",
        .auth = "Basic",
    });
}

// =========================================================================
// 处理器：速率限制状态
// =========================================================================

fn rateLimitStatusHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.json(.{
        .rate_limit = "100 requests per 60 seconds per IP",
        .note = "Check X-RateLimit-* headers in response",
    });
}

// =========================================================================
// 处理器：CORS 预检 + 正常响应
// =========================================================================

fn corsHandler(ctx: *RequestContext, res: *Response) !void {
    // CORS 中间件已经在 process() 中处理了预检请求
    // 这里只需要正常响应
    try res.json(.{
        .message = "CORS-enabled endpoint",
        .origin = ctx.getHeader("Origin") orelse "(no Origin)",
    });
}

// =========================================================================
// 处理器：404
// =========================================================================

fn notFoundHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).json(.{
        .@"error" = "Not found",
        .available_endpoints = .{
            "/api/hello",
            "/basic/hello",
            "/cors/test",
            "/rate-limit/status",
        },
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

    // ── 初始化中间件 ────────────────────────────────────

    // 1. Auth 中间件（多种方式）
    var auth_bearer = try AuthMiddleware.create(allocator, .{
        .bearer_token = "my-secret-token",
    });
    defer auth_bearer.deinit();

    var auth_basic = try AuthMiddleware.create(allocator, .{
        .basic_username = "admin",
        .basic_password = "secret123",
    });
    defer auth_basic.deinit();

    var auth_api_key = try AuthMiddleware.create(allocator, .{
        .api_key = "my-api-key-123",
        .api_key_header = "X-API-Key",
        .api_key_query = true,
    });
    defer auth_api_key.deinit();

    // 2. CORS 中间件
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{
            "http://localhost:3000",
            "http://127.0.0.1:3000",
        },
        .allowed_methods = &.{ .GET, .POST, .PUT, .DELETE, .OPTIONS },
        .allowed_headers = &.{ "Content-Type", "Authorization" },
        .allow_credentials = true,
        .max_age = 3600,
    });
    defer cors.deinit();

    // 3. 速率限制中间件
    var rate_limiter = try RateLimiter.init(allocator, io, .{
        .window_seconds = 60,
        .max_requests = 100,
        .per_ip = true,
    });
    defer rate_limiter.deinit();

    // 4. 日志中间件
    var logging_mw = LoggingMiddleware{ .label = "demo" };
    const log_middleware = Middleware.init(LoggingMiddleware, &logging_mw);

    // 5. 自定义响应头中间件
    var custom_hdr_mw = CustomHeadersMiddleware{};
    const custom_hdr_middleware = Middleware.init(
        CustomHeadersMiddleware,
        &custom_hdr_mw,
    );

    // 将 Auth 中间件转换为 Middleware 类型
    const bearer_middleware = auth_bearer.middle;
    const basic_middleware = auth_basic.middle;
    const api_key_middleware = auth_api_key.middle;
    const rate_middleware = rate_limiter.middleware;
    const cors_middleware = cors.middleware;

    // ── 初始化路由器 ────────────────────────────────────
    var router = Router.init(allocator);
    defer router.deinit();

    // ── 注册路由 ────────────────────────────────────────

    // 1. Bearer token 认证端点
    try router.routeWithMiddleware(
        .GET,
        "/api/hello",
        Handler.fromFn(helloHandler),
        &.{ bearer_middleware, log_middleware, custom_hdr_middleware },
    );

    // 2. Basic auth 端点
    try router.routeWithMiddleware(
        .GET,
        "/basic/hello",
        Handler.fromFn(basicHelloHandler),
        &.{ basic_middleware, log_middleware },
    );

    // 3. API Key 认证端点
    try router.routeWithMiddleware(
        .GET,
        "/api/hello",
        Handler.fromFn(helloHandler),
        &.{ api_key_middleware, log_middleware },
    );

    // 4. CORS 端点（OPTIONS 预检由中间件自动处理）
    try router.routeWithMiddleware(
        .GET,
        "/cors/test",
        Handler.fromFn(corsHandler),
        &.{ cors_middleware, log_middleware },
    );

    // 5. 速率限制端点
    try router.routeWithMiddleware(
        .GET,
        "/rate-limit/status",
        Handler.fromFn(rateLimitStatusHandler),
        &.{ rate_middleware, log_middleware },
    );

    // 6. 404
    router.notFound(Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ────────────────────────────────────
    const config = Config.Config{ .port = 9000 };
    var server = try Server.init(allocator, io, config, router);
    defer server.deinit();

    // 设置 CORS（Server 级别，对所有请求生效）
    server.setCors(cors);

    std.log.info("Middleware Demo Server starting on http://127.0.0.1:9000", .{});
    std.log.info("Middlewares active:", .{});
    std.log.info("  - Auth (Bearer + Basic + API Key)", .{});
    std.log.info("  - CORS (allowed: localhost:3000)", .{});
    std.log.info("  - Rate Limiter (100 req/min per IP)", .{});
    std.log.info("  - Request Logging", .{});
    std.log.info("Endpoints:", .{});
    std.log.info("  GET /api/hello    (Bearer auth)", .{});
    std.log.info("  GET /basic/hello  (Basic auth)", .{});
    std.log.info("  GET /cors/test    (CORS enabled)", .{});
    std.log.info("  GET /rate-limit/status", .{});

    try server.run();
}
