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
    var ws_manager = http_framework.WebSocketManager.init(allocator, io);
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
    const config = http_framework.Config{};
    var server = try http_framework.Server.init(allocator, io, config, &router);
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
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>WebSocket Echo - Zig HTTP Framework</title>
        \\  <style>
        \\    body { font-family: sans-serif; max-width: 720px; margin: 2em auto; padding: 0 1em; }
        \\    #log { height: 320px; overflow-y: scroll; border: 1px solid #ccc; padding: 0.5em; background: #fafafa; }
        \\    input { padding: 0.4em; font-size: 1em; }
        \\    button { padding: 0.4em 1em; font-size: 1em; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <h1>WebSocket Echo Demo</h1>
        \\  <p>Connect to <code>ws://localhost:9000/ws</code> and send a message.</p>
        \\  <div>
        \\    <input id="msg" type="text" placeholder="Type a message..." size="40" />
        \\    <button id="send">Send</button>
        \\    <button id="clear">Clear Log</button>
        \\  </div>
        \\  <pre id="log"></pre>
        \\  <script>
        \\    const ws = new WebSocket("ws://" + location.host + "/ws");
        \\    const logEl = document.getElementById("log");
        \\    const msgEl = document.getElementById("msg");
        \\    function append(text) {
        \\      logEl.textContent += text + "\\n";
        \\      logEl.scrollTop = logEl.scrollHeight;
        \\    }
        \\    ws.onopen = () => append("[connected]");
        \\    ws.onclose = () => append("[disconnected]");
        \\    ws.onerror = (e) => append("[error] " + e);
        \\    ws.onmessage = (e) => append("[echo] " + e.data);
        \\    document.getElementById("send").onclick = () => {
        \\      const v = msgEl.value;
        \\      if (v) { ws.send(v); append("[sent] " + v); msgEl.value = ""; }
        \\    };
        \\    document.getElementById("clear").onclick = () => { logEl.textContent = ""; };
        \\    msgEl.addEventListener("keydown", (e) => {
        \\      if (e.key === "Enter") document.getElementById("send").click();
        \\    });
        \\  </script>
        \\</body>
        \\</html>
    ;
    try res.html(html);
}

/// 状态端点 - 返回当前 WebSocket 连接数
fn statusHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    // 注意：真实场景中需要将 ws_manager 通过 handler state 传入
    // 这里仅作为演示返回静态信息
    try res.json(.{
        .service = "zig-http-framework-websocket",
        .note = "Connect to ws://localhost:9000/ws to test echo",
    });
}

/// 广播处理器 - 接收 POST 请求体，广播到所有 WebSocket 客户端
fn broadcastHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    const body = try ctx.readBody();
    if (body.len == 0) {
        try res.statusCode(.bad_request).text("Empty body");
        return;
    }
    // 真实场景需要通过 state 传入 ws_manager
    // 这里仅返回接收确认
    try res.json(.{
        .broadcast = true,
        .message_len = body.len,
        .note = "In production, this would broadcast to all connected WebSocket clients",
    });
}

/// 404 处理器
fn notFoundHandler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).html(
        \\<!DOCTYPE html>
        \\<html><head><title>404</title></head>
        \\<body>
        \\  <h1>404 - Not Found</h1>
        \\  <p><a href="/">Go home</a></p>
        \\</body>
        \\</html>
    );
}
