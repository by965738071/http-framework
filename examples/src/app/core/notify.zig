//!
//! 与 examples/src/admin.zig 的 `Notifications` 同思路（全程持锁发送，见
//! bug.md §9），但连接表改用 `std.ArrayList` 而不是"手工扩窗 + 定长缓冲"，
//! 避免越界写与满容量静默丢连接。

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
        // 修复 bug.md §9（与 examples/src/admin.zig 的 Notifications 同一 bug）：
        // 必须全程持锁发送。connections 里的 *WebSocket 指向 handshake.zig
        // run() 的栈局部变量，handler 返回即析构；旧写法「锁内拷快照、
        // 锁外发送」在锁外解引用快照期间，对应 worker 线程可能已断开返回
        // → 栈帧销毁 → use-after-free。
        //
        // 代价：慢客户端的 TCP 写会阻塞 register/unregister 直到发送超时
        // （TimedWriter write_timeout_ns）。锁内失败就地 orderedRemove，绝不能
        // 在持锁时调 self.unregister（std.Io.Mutex 非重入 → 死锁）。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var i: usize = 0;
        while (i < self.connections.items.len) {
            const ws = self.connections.items[i];
            if (ws.sendText(text)) |_| {
                i += 1;
            } else |_| {
                _ = self.connections.orderedRemove(i);
                // 不推进 i：后移元素落在位置 i，需在下一轮处理
            }
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
