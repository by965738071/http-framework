//! 基础服务器示例
//!
//! 演示 http_framework 的核心功能：
//! - 路由注册（静态路径、动态参数）
//! - 三种处理器模式（纯函数、单例、请求级）
//! - JSON/HTML/文本响应
//! - 404 处理
//! - 静态文件服务
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build run
//! ```

const std = @import("std");
pub const http_framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // ── 初始化路由器 ──────────────────────────────────────
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    // ── 注册路由 ──────────────────────────────────────────

    // 1. 请求级处理器（推荐）- 每次请求自动创建和销毁
    try router.route(.GET, "/", try http_framework.Handler.initPerRequest(HomeHandler, allocator));

    // 2. 带参数的请求级处理器
    try router.route(.GET, "/users/:id", try http_framework.Handler.initPerRequestWith(
        UserHandler,
        allocator,
        .{ .default_name = "John Doe" },
    ));

    // 3. 纯函数处理器（零开销）- 适合无状态逻辑
    try router.route(.GET, "/health", http_framework.Handler.fromFn(healthHandler));

    // 4. 单例处理器（零分配）- 适合全局共享状态
    const counter_handler = try allocator.create(CounterHandler);
    counter_handler.* = .{ .counter = std.atomic.Value(u64).init(0) };
    defer allocator.destroy(counter_handler);
    try router.route(.GET, "/count", http_framework.Handler.init(CounterHandler, counter_handler));

    // 5. JSON API 示例
    try router.route(.GET, "/api/status", http_framework.Handler.fromFn(statusHandler));

    // 6. POST 请求处理
    try router.route(.POST, "/api/echo", http_framework.Handler.fromFn(echoHandler));

    // 7. 静态文件服务
    var static_server = http_framework.Static.init(allocator, io, "public", "/static");
    try router.route(.GET, "/static/*", http_framework.Handler.init(http_framework.Static, &static_server));

    // 8. 404 处理
    router.notFound(http_framework.Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ────────────────────────────────────────
    const config = http_framework.Config.Config{};
    var server = try http_framework.Server.init(allocator, io, config, router);
    defer server.deinit();

    std.log.info("Server starting...", .{});
    try server.run();
}

// =========================================================================
// 处理器实现
// =========================================================================

/// Home 页面处理器（请求级）
const HomeHandler = struct {
    title: []const u8,

    pub fn init(allocator: std.mem.Allocator) !*HomeHandler {
        const ptr = try allocator.create(HomeHandler);
        ptr.* = .{ .title = "Zig HTTP Framework Examples" };
        return ptr;
    }

    pub fn handle(self: *HomeHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        _ = ctx;
        _ = self;
        try res.html(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Zig HTTP Framework</title></head>
            \\<body>
            \\  <h1>Welcome to Zig HTTP Framework!</h1>
            \\  <h2>Examples:</h2>
            \\  <ul>
            \\    <li><a href="/">Home</a> - This page</li>
            \\    <li><a href="/users/42">/users/42</a> - Dynamic route with parameter</li>
            \\    <li><a href="/health">/health</a> - Pure function handler</li>
            \\    <li><a href="/count">/count</a> - Singleton handler with counter</li>
            \\    <li><a href="/api/status">/api/status</a> - JSON API</li>
            \\    <li><a href="/static/index.html">/static/index.html</a> - Static file</li>
            \\    <li><a href="/not-found">/not-found</a> - 404 page</li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    }

    pub fn deinit(self: *HomeHandler) void {
        _ = self;
    }
};

/// 用户信息处理器（带参数的请求级）
const UserHandler = struct {
    default_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*UserHandler {
        const ptr = try allocator.create(UserHandler);
        ptr.* = .{ .default_name = args.default_name };
        return ptr;
    }

    pub fn handle(self: *UserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const user_id = ctx.getParam("id") orelse "unknown";
        try res.json(.{
            .user_id = user_id,
            .name = self.default_name,
            .message = "Hello from Zig HTTP Framework!",
        });
    }

    pub fn deinit(self: *UserHandler) void {
        _ = self;
    }
};

/// 健康检查处理器（纯函数）
fn healthHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    try res.json(.{
        .status = "ok",
    });
}

/// 计数器处理器（单例）
const CounterHandler = struct {
    counter: std.atomic.Value(u64),

    pub fn handle(self: *CounterHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        _ = ctx;
        const count = self.counter.fetchAdd(1, .monotonic);
        try res.json(.{
            .request_count = count,
            .message = "This request was counted",
        });
    }
};

/// 状态处理器（纯函数）
fn statusHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    try res.json(.{
        .server = "Zig HTTP Framework",
        .version = "0.1.0",

        .features = .{
            "routing",
            "middleware",
            "websocket",
            "static_files",
        },
    });
}

/// Echo 处理器（纯函数）- 回显请求体
fn echoHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const body = try ctx.readBody();
    try res.json(.{
        .echo = body,
        .content_type = ctx.content_type,
        .content_length = ctx.content_length,
    });
}

/// 404 处理器（纯函数）
fn notFoundHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>404 - Not Found</title></head>
        \\<body>
        \\  <h1>404 - Page Not Found</h1>
        \\  <p>The requested page does not exist.</p>
        \\  <p><a href="/">Go back to home</a></p>
        \\</body>
        \\</html>
    );
}
