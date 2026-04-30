//! 生产级 WebSocket 支持
//! 基于 Zig 标准库 `std.http.Server` 的内置 WebSocket 实现，
//! 提供握手升级、消息收发、Ping/Pong、连接管理等功能。
//!
//! # 使用示例
//! ```zig
//! const ws = try websocket.handle(&ctx, &request);
//! const msg = try websocket.readText(ws, &buffer);
//! try websocket.sendText(ws, "Hello, WebSocket!");
//! try websocket.close(ws);
//! ```

const std = @import("std");
const http = std.http;
const mem = std.mem;
const time = std.time;

const RequestContext = @import("request.zig").RequestContext;

// =========================================================================
// WebSocket 管理器（生产级）
// =========================================================================

pub const WebSocketManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // 连接管理
    connections: std.StringHashMap(ConnectionInfo) = .empty,
    next_id: u32 = 0,

    // 配置
    ping_interval_ms: u32 = 30000, // 30 秒
    pong_timeout_ms: u32 = 5000, // 5 秒

    const Self = @This();

    const ConnectionInfo = struct {
        id: u32,
        connected_at: i128, // 纳秒时间戳
        last_pong: i128, // 最后收到 Pong 的时间
        client_ip: ?[]const u8,
    };

    /// 初始化 WebSocket 管理器
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{
            .allocator = allocator,
            .io = io,
        };
    }

    /// 释放所有资源
    pub fn deinit(self: *Self) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit(self.allocator);
    }

    /// 处理 WebSocket 升级请求（生产级）
    pub fn handle(
        self: *Self,
        ctx: *RequestContext,
        request: *http.Server.Request,
    ) !http.Server.WebSocket {
        const upgrade = request.upgradeRequested();
        switch (upgrade) {
            .websocket => |key| {
                if (key) |k| {
                    // 执行 WebSocket 握手
                    const ws = try request.respondWebSocket(.{ .key = k });

                    // 记录连接信息
                    const conn_id = try std.fmt.allocPrint(
                        self.allocator,
                        "ws_{}",
                        .{self.next_id},
                    );
                    self.next_id += 1;

                    const info = ConnectionInfo{
                        .id = self.next_id,
                        .connected_at = time.nanoTimestamp(),
                        .last_pong = time.nanoTimestamp(),
                        .client_ip = ctx.getClientIp(),
                    };

                    try self.connections.put(self.allocator, conn_id, info);

                    std.log.info("WebSocket connected: {s}", .{conn_id});
                    return ws;
                }
                return error.MissingWebSocketKey;
            },
            else => return error.NotWebSocketRequest,
        }
    }

    /// 读取一条文本消息（带超时和大小限制）
    pub fn readText(
        self: *const Self,
        ws: *http.Server.WebSocket,
        buffer: []u8,
        timeout_ms: ?u32,
    ) ![]const u8 {
        _ = self;
        _ = timeout_ms; // TODO: 实现超时

        const msg = try ws.readSmallMessage();
        if (msg.opcode != .text) {
            return error.NotTextMessage;
        }

        if (msg.data.len > buffer.len) {
            return error.BufferTooSmall;
        }

        @memcpy(buffer[0..msg.data.len], msg.data);
        return buffer[0..msg.data.len];
    }

    /// 发送一条文本消息
    pub fn sendText(
        ws: *http.Server.WebSocket,
        text: []const u8,
    ) !void {
        try ws.writeMessage(text, .text);
    }

    /// 发送一条二进制消息
    pub fn sendBinary(
        ws: *http.Server.WebSocket,
        data: []const u8,
    ) !void {
        try ws.writeMessage(data, .binary);
    }

    /// 发送 Ping 帧（心跳）
    pub fn sendPing(
        ws: *http.Server.WebSocket,
        data: []const u8,
    ) !void {
        try ws.writeMessage(data, .ping);
    }

    /// 发送 Pong 帧（响应心跳）
    pub fn sendPong(
        ws: *http.Server.WebSocket,
        data: []const u8,
    ) !void {
        try ws.writeMessage(data, .pong);
    }

    /// 关闭 WebSocket 连接（友好）
    pub fn close(
        self: *Self,
        ws: *http.Server.WebSocket,
        code: ?u16,
        reason: ?[]const u8,
    ) !void {
        _ = self;
        _ = code;
        _ = reason;

        // 发送关闭帧
        try ws.writeMessage(&.{}, .connection_close);

        std.log.info("WebSocket closed", .{});
    }

    /// 广播消息给所有连接的客户端
    pub fn broadcast(
        self: *const Self,
        message: []const u8,
        opcode: http.Server.WebSocket.Opcode,
    ) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            // 注意：这里需要维护 WebSocket 实例列表
            _ = entry;
            _ = message;
            _ = opcode;
            // TODO: 实现广播逻辑
        }
    }

    /// 清理超时的连接（定期调用）
    pub fn cleanupStale(self: *Self) void {
        const now = time.nanoTimestamp();
        const timeout_ns = @as(i128, self.pong_timeout_ms) * 1_000_000;

        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit(self.allocator);

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.last_pong > timeout_ns) {
                const key_dup = self.allocator.dup(entry.key_ptr.*) catch continue;
                to_remove.append(self.allocator, key_dup) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.connections.get(key)) |*info| {
                self.allocator.free(info.id);
            }
            _ = self.connections.remove(key);
            self.allocator.free(key);
        }
    }
};
