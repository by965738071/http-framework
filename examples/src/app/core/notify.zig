//!
//! 与 examples/src/admin.zig 的 `Notifications` 同思路（锁内拷快照、锁外发送），
//! 但连接表改用 `std.ArrayList` 而不是"手工扩窗 + 定长缓冲"，避免越界写与
//! 满容量静默丢连接。

const std = @import("std");
const framework = @import("http_framework");
const respond = @import("respond.zig");

pub const Notifier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    connections: std.ArrayList(*framework.WebSocket),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Notifier {
        return .{
            .allocator = allocator,
            .io = io,
            .connections = std.ArrayList(*framework.WebSocket).empty,
        };
    }

    pub fn deinit(self: *Notifier) void {
        self.connections.deinit(self.allocator);
    }

    pub fn register(self: *Notifier, ws: *framework.WebSocket) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.connections.append(self.allocator, ws);
    }

    pub fn unregister(self: *Notifier, ws: *framework.WebSocket) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items, 0..) |c, i| {
            if (c == ws) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    pub fn onlineCount(self: *Notifier) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.connections.items.len;
    }

    /// 向所有连接推送一条文本。发送失败的连接会被注销。
    pub fn broadcast(self: *Notifier, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        const snapshot = self.allocator.dupe(*framework.WebSocket, self.connections.items) catch {
            self.mutex.unlock(self.io);
            return error.OutOfMemory;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(snapshot);

        for (snapshot) |ws| {
            ws.sendText(text) catch {
                self.unregister(ws);
            };
        }
    }

    /// 推送结构化事件：`{"type":"user.created","data":{...},"ts":123}`。
    pub fn broadcastEvent(self: *Notifier, event_type: []const u8, data: anytype, ts_ms: u64) !void {
        const text = try respond.toJson(self.allocator, .{
            .type = event_type,
            .data = data,
            .ts = ts_ms,
        });
        defer self.allocator.free(text);
        try self.broadcast(text);
    }
};

test "Notifier 注册/注销与在线数" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var n = Notifier.init(allocator, io);
    defer n.deinit();

    const a = try allocator.create(framework.WebSocket);
    defer allocator.destroy(a);
    const b = try allocator.create(framework.WebSocket);
    defer allocator.destroy(b);

    try std.testing.expectEqual(@as(usize, 0), n.onlineCount());
    try n.register(a);
    try n.register(b);
    try std.testing.expectEqual(@as(usize, 2), n.onlineCount());

    n.unregister(a);
    try std.testing.expectEqual(@as(usize, 1), n.onlineCount());
    try std.testing.expect(n.connections.items[0] == b);

    n.unregister(b);
    try std.testing.expectEqual(@as(usize, 0), n.onlineCount());
    // 注销不存在的连接是 no-op
    n.unregister(a);
    try std.testing.expectEqual(@as(usize, 0), n.onlineCount());
}
