//! 生产级 WebSocket 支持 (Zig 0.16)
//! 基于 Zig 标准库 `std.http.Server` 的内置 WebSocket 实现，
//! 提供握手升级、消息收发、Ping/Pong、连接管理等功能。
//!
//! 注意：
//! - 时间戳通过 `std.Io.Clock` 获取，符合 0.16 的 Io 中心设计。
//! - 使用了 `ArrayList.initCapacity`，适配 0.16 的 API 变更。
//! - 连接信息中的 `id` 被移除，改为使用 `conn_id` 字符串索引。
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

const RequestContext = @import("request.zig");
const Response = @import("response.zig");

// =========================================================================
// WebSocket 管理器（生产级）
// =========================================================================

pub const WebSocketManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io, // 用于获取时间戳等 Io 操作

    // 连接管理：conn_id -> ConnectionInfo
    connections: std.StringHashMap(ConnectionInfo),
    next_id: u32 = 0,

    // 配置
    ping_interval_ms: u32 = 30000, // 30 秒
    pong_timeout_ms: u32 = 5000, // 5 秒

    const Self = @This();

    const ConnectionInfo = struct {
        last_pong: i128, // 最后收到 Pong 的纳秒时间戳（单调时钟）
        connected_at: i128, // 连接建立的时间戳（单调时钟）
        client_ip: ?[]const u8, // 客户端 IP（可选，所有权在调用方）
    };

    /// 初始化 WebSocket 管理器
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .connections = .init(allocator),
        };
    }

    /// 释放所有资源
    pub fn deinit(self: *Self) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            // key_ptr 是分配的字符串，需要释放
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();
    }

    /// 获取当前单调时间（纳秒）
    fn nowNano(self: *const Self) i128 {
        // Zig 0.16: 通过 Io.Clock 获取时间，替代已移除的 time.nanoTimestamp
        return std.Io.Clock.now(.real, self.io).nanoseconds;
    }

    /// 处理 WebSocket 升级请求
    pub fn handle(
        self: *Self,
        ctx: *RequestContext,
        request: *http.Server.Request,
    ) !struct { http.Server.WebSocket, []const u8 } {
        std.log.info("hello{}", .{request.head});
        const upgrade = request.upgradeRequested();
        switch (upgrade) {
            .websocket => |key| {
                if (key) |k| {
                    // 执行 WebSocket 握手
                    const ws = try request.respondWebSocket(.{ .key = k });

                    // 生成连接 ID
                    const conn_id = try std.fmt.allocPrint(
                        self.allocator,
                        "ws_{}",
                        .{self.next_id},
                    );
                    self.next_id += 1;

                    const now = self.nowNano();
                    const info = ConnectionInfo{
                        .connected_at = now,
                        .last_pong = now,
                        .client_ip = ctx.getClientIp(),
                    };

                    try self.connections.put(conn_id, info);

                    std.log.info("WebSocket connected: {s}", .{conn_id});
                    return .{ ws, conn_id };
                }
                return error.MissingWebSocketKey;
            },
            else => return error.NotWebSocketRequest,
        }
    }

    /// 读取一条文本消息（带大小限制，超时待实现）
    pub fn readText(
        self: *const Self,
        ws: *http.Server.WebSocket,
        buffer: []u8,
        timeout_ms: ?u32,
    ) ![]const u8 {
        _ = self;
        _ = timeout_ms; // TODO: 利用 self.io 实现超时

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

    /// 关闭 WebSocket 连接（标准方式）
    /// 发送关闭帧后，会将此连接从管理器中移除。
    pub fn close(
        self: *Self,
        ws: *http.Server.WebSocket,
        code: ?u16,
        reason: ?[]const u8,
        conn_id: []const u8, // 需要知道是哪个连接
    ) !void {
        // 构造关闭帧（标准状态码 + 可选原因）
        var close_frame = std.ArrayList(u8).initCapacity(self.allocator, 2 + @as(usize, if (reason) |r| r.len else 0));
        defer close_frame.deinit(self.allocator);

        const status_code = code orelse 1000; // 正常关闭
        try close_frame.writer(self.allocator).writeInt(u16, status_code, .big);
        if (reason) |r| {
            try close_frame.appendSlice(self.allocator, r);
        }

        // 发送关闭帧
        try ws.writeMessage(close_frame.items, .connection_close);

        // 从连接表中移除
        if (self.connections.fetchRemove(conn_id)) |kv| {
            self.allocator.free(kv.key);
            // 如果 client_ip 是动态分配的，这里也应释放；当前实现不拥有 client_ip，故跳过
        }

        std.log.info("WebSocket closed: {s}", .{conn_id});
    }

    /// 广播消息给所有已知连接（需维护 WebSocket 实例列表，当前为占位）
    pub fn broadcast(
        self: *const Self,
        message: []const u8,
        opcode: http.Server.WebSocket.Opcode,
    ) void {
        _ = self;
        _ = message;
        _ = opcode;
        // TODO: 需要维护 WebSocket 实例列表才能实现广播
    }

    /// 清理超时的连接（定期调用）
    pub fn cleanupStale(self: *Self) void {
        const now = self.nowNano();
        const timeout_ns = @as(i128, self.pong_timeout_ms) * 1_000_000;

        // 收集需要移除的连接 ID
        var to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer {
            for (to_remove.items) |key| {
                self.allocator.free(key);
            }
            to_remove.deinit(self.allocator);
        }

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.last_pong > timeout_ns) {
                // 复制 key，因为之后要 remove，原 key 指向 hashmap 内部
                const key_dup = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(key_dup) catch {
                    self.allocator.free(key_dup);
                    continue;
                };
            }
        }

        for (to_remove.items) |key| {
            if (self.connections.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                // 注意：ConnectionInfo 内的 client_ip 不是我们分配的，无需释放
            }
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
        const request = ctx.request;

        // 尝试升级到 WebSocket
        const upgrade = self.ws_manager.handle(ctx, request) catch |err| {
            std.log.err("WebSocket upgrade failed: {}", .{err});
            try res.statusCode(.bad_request).text("WebSocket upgrade failed");
            return;
        };
        var ws = upgrade.@"0";
        const conn_id = upgrade.@"1";
        defer self.allocator.free(conn_id);

        // var buf: [1024]u8 = undefined;
        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                std.log.err("WebSocket read error: {}", .{err});
                break;
            };
            switch (msg.opcode) {
                .text => {
                    // 回显文本消息
                    try ws.writeMessage(msg.data, .text);
                    // 刷新心跳（防止被清理）
                    if (self.ws_manager.connections.getPtr(conn_id)) |info| {
                        info.last_pong = self.ws_manager.nowNano();
                    }
                },
                .binary => try ws.writeMessage(msg.data, .binary),
                .ping => try ws.writeMessage(msg.data, .pong),
                .pong => {
                    if (self.ws_manager.connections.getPtr(conn_id)) |info| {
                        info.last_pong = self.ws_manager.nowNano();
                    }
                },
                .connection_close => {
                    _ = try ws.writeMessage(&.{}, .connection_close);
                    // 从管理器中移除
                    if (self.ws_manager.connections.fetchRemove(conn_id)) |kv| {
                        self.allocator.free(kv.key);
                    }
                    break;
                },
                else => {},
            }
        }
    }
};
