const std = @import("std");
const http = std.http;
const RequestContext = @import("request_context.zig").RequestContext;

/// WebSocket 处理器
/// 处理 WebSocket 连接
pub fn handle(ctx: *RequestContext, request: *http.Server.Request) !http.Server.WebSocket {
    const upgrade = request.upgradeRequested();
    _ = ctx;
    switch (upgrade) {
        .websocket => |key| {
            if (key) |k| {
                return try request.respondWebSocket(.{
                    .key = k,
                });
            }
            return error.MissingWebSocketKey;
        },
        else => return error.NotWebSocketRequest,
    }
}

/// 读取文本消息
pub fn readText(ws: *http.Server.WebSocket, buffer: []u8) ![]const u8 {
    const msg = try ws.readSmallMessage();
    if (msg.opcode != .text) return error.NotTextMessage;

    if (msg.data.len > buffer.len) return error.BufferTooSmall;

    @memcpy(buffer[0..msg.data.len], msg.data);
    return buffer[0..msg.data.len];
}

/// 发送文本消息
pub fn sendText(ws: *http.Server.WebSocket, text: []const u8) !void {
    try ws.writeMessage(text, .text);
}

/// 发送二进制消息
pub fn sendBinary(ws: *http.Server.WebSocket, data: []const u8) !void {
    try ws.writeMessage(data, .binary);
}

/// 关闭连接
pub fn close(ws: *http.Server.WebSocket) !void {
    try ws.writeMessage(&.{}, .connection_close);
}

/// WebSocket 处理器
pub const WebSocketHandler = struct {
    /// 处理 WebSocket 连接
    pub fn handle(ctx: *RequestContext, request: *http.Server.Request) !http.Server.WebSocket {
        const upgrade = request.upgradeRequested();
        _ = ctx;
        switch (upgrade) {
            .websocket => |key| {
                if (key) |k| {
                    return try request.respondWebSocket(.{
                        .key = k,
                    });
                }
                return error.MissingWebSocketKey;
            },
            else => return error.NotWebSocketRequest,
        }
    }

    /// 读取文本消息
    pub fn readText(ws: *http.Server.WebSocket, buffer: []u8) ![]const u8 {
        const msg = try ws.readSmallMessage();
        if (msg.opcode != .text) return error.NotTextMessage;

        if (msg.data.len > buffer.len) return error.BufferTooSmall;

        @memcpy(buffer[0..msg.data.len], msg.data);
        return buffer[0..msg.data.len];
    }

    /// 发送文本消息
    pub fn sendText(ws: *http.Server.WebSocket, text: []const u8) !void {
        try ws.writeMessage(text, .text);
    }

    /// 发送二进制消息
    pub fn sendBinary(ws: *http.Server.WebSocket, data: []const u8) !void {
        try ws.writeMessage(data, .binary);
    }

    /// 关闭连接
    pub fn close(ws: *http.Server.WebSocket) !void {
        try ws.writeMessage(&.{}, .connection_close);
    }
};
