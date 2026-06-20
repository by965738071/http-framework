//! WebSocket 回显示例
//!
//! 演示 http_framework 的 WebSocket 功能：
//! - WebSocket 升级
//! - 消息回显
//! - 广播消息到所有客户端
//! - 心跳/心跳检测
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build run-websocket
//! ```
//!
//! # 测试方式
//!
//! 使用 WebSocket 客户端连接到 ws://localhost:9000/ws
//! 发送消息后会收到相同的回显消息

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

    // ── 初始化 WebSocket 管理器 ──────────────────────────
    var ws_manager = http_framework.WebSocket.init(allocator, io);
    defer ws_manager.deinit();

    // ── 初始化路由器 ──────────────────────────────────────
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    // ── 注册路由 ──────────────────────────────────────────

    // 首页 - 显示 WebSocket 测试页面
    try router.route(.GET, "/", http_framework.Handler.fromFn(homeHandler));

    // WebSocket 端点
    const ws_handler = try http_framework.WsEchoHandler.init(allocator, &ws_manager);
    defer ws_handler.deinit();
    try router.route(.GET, "/ws", http_framework.Handler.init(http_framework.WsEchoHandler, ws_handler));

    // 状态端点 - 显示连接信息
    try router.route(.GET, "/status", http_framework.Handler.fromFn(statusHandler));

    // 广播端点 - 向所有客户端广播消息
    try router.route(.POST, "/broadcast", http_framework.Handler.fromFn(broadcastHandler));

    // 404 处理
    router.notFound(http_framework.Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ────────────────────────────────────────
    const config = http_framework.Config.Config{};
    var server = try http_framework.Server.init(allocator, io, config, router);
    defer server.deinit();

    std.log.info("WebSocket example server starting...", .{});
    std.log.info("Open http://localhost:9000 in your browser", .{});
    try server.run();
}

// =========================================================================
// 处理器实现
// =========================================================================

/// 首页 - 显示 WebSocket 测试页面
fn homeHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    try res.html(
        