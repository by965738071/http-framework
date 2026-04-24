//! WebSocket 支持
//!
//! 基于 Zig 标准库 `std.http.Server` 的内置 WebSocket 实现，
//! 提供握手升级和消息收发功能。
//!
//! # 使用示例
//!
//! ```zig
//! const ws = try websocket.handle(&ctx, request);
//! const msg = try websocket.readText(&ws, &buffer);
//! try websocket.sendText(&ws, "Hello, WebSocket!");
//! ```

const std = @import("std");
const http = std.http;
const RequestContext = @import("request.zig").RequestContext;

// =========================================================================
// WebSocket 握手
// =========================================================================

/// 处理 WebSocket 升级请求。
///
/// 检查请求是否包含有效的 WebSocket 升级头。如果是，执行握手并
/// 返回一个 `WebSocket` 实例用于后续通信。
///
/// 返回的错误：
/// - `error.NotWebSocketRequest` — 请求不是 WebSocket 升级
/// - `error.MissingWebSocketKey` — 缺少 `Sec-WebSocket-Key` 头
pub fn handle(ctx: *RequestContext, request: *http.Server.Request) !http.Server.WebSocket {
    _ = ctx;

    const upgrade = request.upgradeRequested();
    switch (upgrade) {
        .websocket => |key| {
            if (key) |k| {
                return try request.respondWebSocket(.{ .key = k });
            }
            return error.MissingWebSocketKey;
        },
        else => return error.NotWebSocketRequest,
    }
}

// =========================================================================
// 消息读写
// =========================================================================

/// 读取一条文本消息。
///
/// `buffer` 用于存储消息数据。如果消息超过缓冲区大小，返回
/// `error.BufferTooSmall`。
pub fn readText(ws: *http.Server.WebSocket, buffer: []u8) ![]const u8 {
    const msg = try ws.readSmallMessage();
    if (msg.opcode != .text) return error.NotTextMessage;
    if (msg.data.len > buffer.len) return error.BufferTooSmall;

    @memcpy(buffer[0..msg.data.len], msg.data);
    return buffer[0..msg.data.len];
}

/// 发送一条文本消息。
pub fn sendText(ws: *http.Server.WebSocket, text: []const u8) !void {
    try ws.writeMessage(text, .text);
}

/// 发送一条二进制消息。
pub fn sendBinary(ws: *http.Server.WebSocket, data: []const u8) !void {
    try ws.writeMessage(data, .binary);
}

/// 发送 Ping 帧。
pub fn sendPing(ws: *http.Server.WebSocket, data: []const u8) !void {
    try ws.writeMessage(data, .ping);
}

/// 发送 Pong 帧。
pub fn sendPong(ws: *http.Server.WebSocket, data: []const u8) !void {
    try ws.writeMessage(data, .pong);
}

/// 关闭 WebSocket 连接。
pub fn close(ws: *http.Server.WebSocket) !void {
    try ws.writeMessage(&.{}, .connection_close);
}
