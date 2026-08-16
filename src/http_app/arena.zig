//! 两级 arena（回应 bug.md §12）
//!
//! 原来 arena 在 ConnState 里，但 path_params 等请求级资源的销毁
//! 时机是"请求结束"而不是"连接结束"——导致 dispatch 要手动 freeHashMap。
//!
//! 现在两级：
//! - `request` arena：每请求结束 reset(.retain_capacity)
//! - `connection` arena：连接结束才释放
//!
//! path_params 进 request arena（自动回收），session 进 connection
//! arena（keep-alive 跨请求存活）。dispatch 不再需要手动 free。

const std = @import("std");

pub const Arenas = struct {
    request: std.heap.ArenaAllocator,
    connection: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) Arenas {
        return .{
            .request = std.heap.ArenaAllocator.init(parent),
            .connection = std.heap.ArenaAllocator.init(parent),
        };
    }

    pub fn requestAllocator(self: *Arenas) std.mem.Allocator {
        return self.request.allocator();
    }

    pub fn connectionAllocator(self: *Arenas) std.mem.Allocator {
        return self.connection.allocator();
    }

    /// 请求结束后调用：reset request arena，保留热身容量。
    pub fn endRequest(self: *Arenas, retain_bytes: usize) void {
        if (retain_bytes > 0) {
            _ = self.request.reset(.retain_capacity);
        } else {
            _ = self.request.reset(.free_all);
        }
    }

    /// 连接结束后调用：释放两个 arena。
    pub fn deinit(self: *Arenas) void {
        self.request.deinit();
        self.connection.deinit();
    }
};

test "Arenas request-level reset does not affect connection-level" {
    var arenas = Arenas.init(std.testing.allocator);
    defer arenas.deinit();

    // 在 connection arena 分配一些东西
    const conn_data = try arenas.connectionAllocator().dupe(u8, "persistent");
    try std.testing.expectEqualStrings("persistent", conn_data);

    // 在 request arena 分配
    const req_data = try arenas.requestAllocator().dupe(u8, "ephemeral");
    try std.testing.expectEqualStrings("ephemeral", req_data);

    // 结束请求：request arena reset
    arenas.endRequest(0);

    // connection data 仍然有效
    try std.testing.expectEqualStrings("persistent", conn_data);
}

test "Arenas retains capacity for keep-alive hot path" {
    var arenas = Arenas.init(std.testing.allocator);
    defer arenas.deinit();

    // 模拟 keep-alive 上的两个请求
    for (0..2) |_| {
        _ = try arenas.requestAllocator().alloc(u8, 1024); // 模拟请求分配
        arenas.endRequest(16 * 1024); // 保留 16KB 热身容量
        // 保留后下一个请求应该命中已有内存（不再向 OS 要）
        // 只验证不崩溃
    }
}
