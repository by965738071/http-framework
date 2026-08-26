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

    /// 请求结束后调用：reset request arena，保留至多 `retain_bytes` 的热身容量。
    ///
    /// 旧实现把 `retain_bytes` 当布尔用（`> 0` 就 `.retain_capacity`），而
    /// `.retain_capacity` 的语义是「按历史峰值预热」——预算完全不起作用。
    /// 后果：一个 10MB body 的请求让这条 keep-alive 连接**永久**占住 10MB；
    /// `max_connections` 默认 1024 → 最坏 10GB 常驻，且攻击者只需在每条连接上
    /// 打一次大请求然后保持空闲即可。
    /// `.retain_with_limit` 才是「保留至多 N 字节，超出的归还给上游」。
    pub fn endRequest(self: *Arenas, retain_bytes: usize) void {
        _ = self.request.reset(if (retain_bytes > 0)
            .{ .retain_with_limit = retain_bytes }
        else
            .free_all);
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

test{
    std.testing.refAllDecls(@This());
}