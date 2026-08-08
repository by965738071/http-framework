//! 生产级 WebSocket 支持 (Zig 0.17.0-dev)
//! 基于 Zig 标准库 `std.http.Server` 的内置 WebSocket 实现

const std = @import("std");
const http = std.http;
const mem = std.mem;

const RequestContext = @import("core").RequestContext;
const Response = @import("core").Response;

// =========================================================================
// WebSocket 管理器（生产级）
// =========================================================================

pub const WebSocketManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // 连接管理：conn_id -> ConnectionInfo
    connections: std.StringHashMap(ConnectionInfo),
    // 活跃的 WebSocket 对象映射：conn_id -> *WebSocket（用于广播）
    active_sockets: std.StringHashMap(*http.Server.WebSocket),
    next_id: u32 = 0,

    // 配置
    ping_interval_ms: u32 = 30000, // 30 秒
    pong_timeout_ms: u32 = 5000, // 5 秒

    const Self = @This();

    const ConnectionInfo = struct {
        last_pong: i96, // 最后收到 Pong 的纳秒时间戳
        connected_at: i96, // 连接建立的时间戳
        client_ip: ?[]const u8, // 客户端 IP（可选）
    };

    /// 初始化 WebSocket 管理器
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .connections = std.StringHashMap(ConnectionInfo).init(allocator),
            .active_sockets = std.StringHashMap(*http.Server.WebSocket).init(allocator),
        };
    }

    /// 释放所有资源
    pub fn deinit(self: *Self) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();

        var sit = self.active_sockets.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.active_sockets.deinit();
    }

    /// 获取当前时间（纳秒）
    fn nowNano(self: *const Self) i96 {
        // Zig 0.16: 使用 std.Io.Clock
        return std.Io.Clock.now(.real, self.io).nanoseconds;
    }

    /// 从管理器中移除连接并释放资源
    pub fn cleanupConnection(self: *Self, conn_id: []const u8) void {
        // 先记录日志，再 free（避免 use-after-free）
        std.log.info("Connection removed from manager: {s}", .{conn_id});

        if (self.connections.fetchRemove(conn_id)) |kv| {
            self.allocator.free(kv.key);
        } else {
            std.log.warn("Connection not found in manager: {s}", .{conn_id});
        }
        // 同时清理 socket 映射
        if (self.active_sockets.fetchRemove(conn_id)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// 处理 WebSocket 升级请求
    pub fn handle(
        self: *Self,
        ctx: *RequestContext,
        request: *http.Server.Request,
    ) !struct { http.Server.WebSocket, []const u8 } {
        const upgrade_req = request.upgradeRequested();

        switch (upgrade_req) {
            .none => {
                std.log.warn("WebSocket upgrade failed: not a valid WebSocket request", .{});
                return error.NotWebSocketRequest;
            },
            .other => |protocol| {
                std.log.warn("WebSocket upgrade failed: unsupported protocol '{s}'", .{protocol});
                return error.NotWebSocketRequest;
            },
            .websocket => |maybe_key| {
                const key = maybe_key orelse {
                    std.log.warn("WebSocket upgrade failed: missing Sec-WebSocket-Key", .{});
                    return error.NotWebSocketRequest;
                };

                std.log.info("WebSocket upgrade request received, key: {s}", .{key});

                // respondWebSocket 计算 Sec-WebSocket-Accept 并写入 101 响应头，
                // 但**不会自动 flush**，必须手动调用 ws.flush() 才能发送到客户端！
                var ws = try request.respondWebSocket(.{ .key = key });
                try ws.flush(); // 关键：确保 101 响应发送到 TCP 连接
                std.log.info("WebSocket handshake completed, 101 response flushed", .{});

                // 生成连接 ID
                const conn_id = try std.fmt.allocPrint(
                    self.allocator,
                    "ws_{d}",
                    .{self.next_id},
                );
                self.next_id += 1;

                const now = self.nowNano();
                const info = ConnectionInfo{
                    .connected_at = now,
                    .last_pong = now,
                    .client_ip = ctx.getClientIp(),
                };

                // 0.17-dev: put 只需要 key, value
                try self.connections.put(conn_id, info);

                // 注册 WebSocket 对象到活跃映射（用于广播）
                // 注意：需要 dupe key，因为 active_sockets 和 connections 是独立 map，
                // 各自负责释放自己的 key
                const ws_ptr = try self.allocator.create(http.Server.WebSocket);
                ws_ptr.* = ws;
                const ws_key = try self.allocator.dupe(u8, conn_id);
                try self.active_sockets.put(ws_key, ws_ptr);

                std.log.info("WebSocket connected: {s}", .{conn_id});
                std.log.info("WebSocket connection established, ready for messages", .{});
                return .{ ws, conn_id };
            },
        }
    }

    /// 读取一条文本消息
    ///
    /// 注意：当前底层 http.Server.WebSocket.readSmallMessage() 是阻塞调用，
    /// 不支持原生超时。需要使用者在主循环中自行管理超时（见 WsEchoHandler.handle 的示例实现）。
    ///
    /// 参数 `buffer` 用于存储读取的数据。如果消息超过 buffer 长度，返回 BufferTooSmall。
    pub fn readText(
        self: *const Self,
        ws: *http.Server.WebSocket,
        buffer: []u8,
    ) ![]const u8 {
        _ = self;
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

    /// 广播消息到所有活跃连接
    pub fn broadcast(
        self: *Self,
        message: []const u8,
        opcode: http.Server.WebSocket.Opcode,
    ) void {
        var it = self.active_sockets.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.writeMessage(message, opcode) catch |err| {
                std.log.warn("Broadcast failed for {s}: {}", .{ entry.key_ptr.*, err });
            };
        }
    }

    /// 获取当前活跃连接数
    pub fn connectionCount(self: *const Self) usize {
        return self.active_sockets.count();
    }

    /// 清理超时连接
    pub fn cleanupStale(self: *Self) void {
        const now = self.nowNano();
        const timeout_ns = @as(i128, self.pong_timeout_ms) * 1_000_000;

        var to_remove = std.ArrayList([]const u8).empty;
        defer {
            for (to_remove.items) |key| {
                self.allocator.free(key);
            }
            to_remove.deinit(self.allocator);
        }

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.last_pong > timeout_ns) {
                const key_dup = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(self.allocator, key_dup) catch {
                    self.allocator.free(key_dup);
                    continue;
                };
            }
        }

        for (to_remove.items) |key| {
            // 使用 cleanupConnection 清理
            self.cleanupConnection(key);
            // 注意：cleanupConnection 内部会释放 key，所以这里不需要再释放
        }
    }
};

// =========================================================================
// WebSocket 回显处理器（有状态）
// =========================================================================
pub const WsEchoHandler = struct {
    allocator: std.mem.Allocator,
    ws_manager: *WebSocketManager,

    pub fn init(allocator: std.mem.Allocator, ws_manager: *WebSocketManager) !*WsEchoHandler {
        const ptr = try allocator.create(WsEchoHandler);
        ptr.* = .{ .allocator = allocator, .ws_manager = ws_manager };
        return ptr;
    }

    pub fn deinit(self: *WsEchoHandler) void {
        self.allocator.destroy(self);
    }

    pub fn handle(self: *WsEchoHandler, ctx: *RequestContext, res: *Response) !void {
        _ = res; // 标记未使用，因为WebSocket升级后不再使用HTTP响应

        const request = ctx.request;

        // 尝试升级到WebSocket
        std.log.info("Attempting WebSocket upgrade for path: {s}", .{ctx.path});
        const upgrade = self.ws_manager.handle(ctx, request) catch |err| {
            std.log.err("WebSocket upgrade failed: {}", .{err});
            // 注意：升级失败后，需要发送HTTP错误响应
            // 但由于request可能已经被部分消耗，这里简单返回
            return;
        };

        // 标记为WebSocket连接
        ctx.is_websocket = true;

        // 使用正确的方式解构返回值
        var ws = upgrade.@"0";
        const conn_id = upgrade.@"1";
        // conn_id 由 cleanupConnection 负责释放，这里不需要手动 free

        std.log.info("WebSocket handler started for {s}, entering message loop", .{conn_id});

        // 主消息循环 - 添加完整错误处理
        while (true) {
            // 设置5秒读取超时
            const timeout_ns = @as(u64, 5_000_000_000);
            const start_time = self.ws_manager.nowNano();

            const msg = ws.readSmallMessage() catch |err| {
                std.log.err("读取消息错误{s}", .{@errorName(err)});
                const elapsed = self.ws_manager.nowNano() - start_time;

                if (elapsed > @as(i128, timeout_ns)) {
                    std.log.info("[{s}] Read timeout after 5s", .{conn_id});
                    ws.writeMessage("ping", .ping) catch {};
                    continue;
                }

                switch (err) {
                    error.EndOfStream => {
                        std.log.info("Client closed connection: {s}", .{conn_id});
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                    error.ConnectionClose => {
                        std.log.info("Connection closed by peer: {s}", .{conn_id});
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                    error.UnexpectedOpCode => {
                        std.log.warn("Bad opcode: {s}", .{conn_id});
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                    error.MissingMaskBit => {
                        std.log.warn("No mask bit: {s}", .{conn_id});
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                    error.MessageOversize => {
                        std.log.warn("Message too large: {s}", .{conn_id});
                        ws.writeMessage(&.{}, .connection_close) catch {};
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                    error.ReadFailed => {
                        std.log.err("TCP read failed: {s}", .{conn_id});
                        self.ws_manager.cleanupConnection(conn_id);
                        return;
                    },
                }
            };

            // 处理不同消息类型
            switch (msg.opcode) {
                .text => {
                    std.log.info("[{s}] Received text: {s}", .{ conn_id, msg.data });
                    // 识别客户端心跳 ping，回复 pong
                    if (mem.eql(u8, msg.data, "__ping__")) {
                        ws.writeMessage("__pong__", .text) catch |write_err| {
                            std.log.err("Failed to send pong: {}", .{write_err});
                        };
                    } else {
                        ws.writeMessage(msg.data, .text) catch |write_err| {
                            std.log.err("Failed to echo text: {}", .{write_err});
                            continue;
                        };
                    }
                },
                .binary => {
                    std.log.info("[{s}] Received binary: {d} bytes", .{ conn_id, msg.data.len });
                    ws.writeMessage(msg.data, .binary) catch |write_err| {
                        std.log.err("Failed to echo binary: {}", .{write_err});
                        continue;
                    };
                },
                .ping => {
                    std.log.info("[{s}] Received ping", .{conn_id});
                    ws.writeMessage(msg.data, .pong) catch |write_err| {
                        std.log.err("Failed to send pong: {}", .{write_err});
                        continue;
                    };
                },
                .pong => {
                    std.log.info("[{s}] Received pong", .{conn_id});
                    if (self.ws_manager.connections.getPtr(conn_id)) |info| {
                        info.last_pong = self.ws_manager.nowNano();
                    }
                },
                .connection_close => {
                    std.log.info("[{s}] Received close frame", .{conn_id});
                    ws.writeMessage(&.{}, .connection_close) catch |close_err| {
                        std.log.err("Failed to send close: {}", .{close_err});
                    };
                    self.ws_manager.cleanupConnection(conn_id);
                    return;
                },
                else => {
                    std.log.warn("[{s}] Unknown opcode: {any}", .{ conn_id, msg.opcode });
                },
            }
        }
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "WebSocketManager.init - creates empty manager" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    try std.testing.expectEqual(@as(usize, 0), wsm.connectionCount());
    try std.testing.expectEqual(@as(u32, 30000), wsm.ping_interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), wsm.pong_timeout_ms);
}

test "WebSocketManager.connectionCount - empty manager returns 0" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    try std.testing.expectEqual(@as(usize, 0), wsm.connectionCount());
}

test "WebSocketManager.cleanupConnection - non-existent key does not crash" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    // Should not crash — only log a warning
    wsm.cleanupConnection("non_existent");
}

test "WebSocketManager.cleanupStale - empty manager does not crash" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    // Should not crash with no connections
    wsm.cleanupStale();
}

test "WebSocketManager - default config values" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    try std.testing.expectEqual(@as(u32, 30000), wsm.ping_interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), wsm.pong_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), wsm.next_id);
    try std.testing.expectEqual(@as(usize, 0), wsm.connections.count());
    try std.testing.expectEqual(@as(usize, 0), wsm.active_sockets.count());
}

test "WsEchoHandler.init and deinit" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    var handler = try WsEchoHandler.init(allocator, &wsm);
    defer handler.deinit();

    try std.testing.expectEqual(&wsm, handler.ws_manager);
}

test "WebSocketManager - connectionCount after manual add" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    // Add entries directly — no need for real WebSocket objects
    const key = try allocator.dupe(u8, "test_1");
    wsm.active_sockets.put(key, undefined) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), wsm.connectionCount());

    // Remove entry so deinit doesn't free the key (avoid double-free)
    if (wsm.active_sockets.fetchRemove("test_1")) |kv| {
        allocator.free(kv.key);
    }
}

test "WebSocketManager - cleanupConnection removes from both maps" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    // Add connections to both maps
    const key = try allocator.dupe(u8, "ws_0");
    const info = WebSocketManager.ConnectionInfo{
        .last_pong = 0,
        .connected_at = 0,
        .client_ip = null,
    };
    wsm.connections.put(key, info) catch unreachable;

    const ws_key = try allocator.dupe(u8, "ws_0");
    wsm.active_sockets.put(ws_key, undefined) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), wsm.connections.count());
    try std.testing.expectEqual(@as(usize, 1), wsm.active_sockets.count());

    // Clean it up — cleanupConnection frees the key internally
    wsm.cleanupConnection("ws_0");

    try std.testing.expectEqual(@as(usize, 0), wsm.connections.count());
    try std.testing.expectEqual(@as(usize, 0), wsm.active_sockets.count());
}

test "WebSocketManager - deinit after adding connections does not leak" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);

    // Add a connection
    const key = try allocator.dupe(u8, "ws_0");
    const info = WebSocketManager.ConnectionInfo{
        .last_pong = 0,
        .connected_at = 0,
        .client_ip = null,
    };
    wsm.connections.put(key, info) catch unreachable;

    const ws_key = try allocator.dupe(u8, "ws_0");
    wsm.active_sockets.put(ws_key, undefined) catch unreachable;

    // deinit should clean up all allocated keys without leaking
    // (no defer — we call deinit manually)
    wsm.deinit();
}

test "WebSocketManager - cleanupStale removes timed out connections" {
    const allocator = std.testing.allocator;
    var wsm = WebSocketManager.init(allocator, std.testing.io);
    defer wsm.deinit();

    // Add a connection with a very old last_pong (1 hour ago)
    const now = @as(i96, @intCast(std.Io.Clock.now(.real, std.testing.io).nanoseconds));
    const one_hour_ago_ns = now - 3_600_000_000_000;

    const key = try allocator.dupe(u8, "ws_stale");
    const info = WebSocketManager.ConnectionInfo{
        .last_pong = one_hour_ago_ns,
        .connected_at = one_hour_ago_ns,
        .client_ip = null,
    };
    wsm.connections.put(key, info) catch unreachable;

    // Also add an active socket entry
    const ws_key = try allocator.dupe(u8, "ws_stale");
    wsm.active_sockets.put(ws_key, undefined) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), wsm.connections.count());

    // cleanupStale should remove the stale connection and free the key
    wsm.cleanupStale();

    try std.testing.expectEqual(@as(usize, 0), wsm.connections.count());
    try std.testing.expectEqual(@as(usize, 0), wsm.active_sockets.count());
}
