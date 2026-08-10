//! 连接状态与连接状态池
//!
//! # 为什么需要它
//!
//! 早期版本在 `handleConnection` 里用两个栈数组做读写缓冲：
//!
//! ```zig
//! var read_buf:  [64 * 1024]u8 = undefined;
//! var write_buf: [64 * 1024]u8 = undefined;
//! ```
//!
//! 栈帧按**编译期上限**分配，`config.read_buffer_size` 只是事后 `@min` 切片，
//! 所以调小配置一个字节都省不下来——每条连接雷打不动占 128KiB 栈。
//! 并发一上来，栈占用就线性爆炸，而且缓冲区跨连接完全不复用。
//!
//! 这里把「一条连接处理请求所需的全部可复用内存」收敛成一个 `ConnState`：
//!
//! - `read_buf` / `write_buf`：按 config 的实际大小堆分配，多大就是多大；
//! - `arena`：每请求复用的分配器，请求结束 `reset` 而不是逐块 `free`。
//!
//! `ConnStatePool` 负责跨连接复用这些 `ConnState`。
//!
//! # 池的策略
//!
//! - 启动时预分配 `pool_size` 个，稳态下 acquire/release 只是摘链表节点；
//! - 池空时**不排队**，直接堆分配一个新的（宁可慢，不要卡住 accept）；
//! - 归还时若空闲链已满，直接销毁而不是无限囤积——高水位后自动缩容。
//!
//! 每一次「快路径失效」（池空、超额销毁）都计数，见 `Stats`。
//! 内存池什么时候失效是可运维指标，不是内部细节。
//!
//! # 线程安全
//!
//! `acquire` / `release` 可从任意连接任务并发调用，用 `std.Io.Mutex` 保护。
//! 临界区只有几条摘链指令，不做任何分配。
//!
//! 一律用 `lockUncancelable`：`release` 跑在 `defer` 里，关服时若在这里
//! 观察到 `error.Canceled` 就没有任何合理的补救动作——要么泄漏一个
//! ConnState，要么无视取消继续跑。既然临界区只有几条指令，
//! 直接选择不引入取消点。

const std = @import("std");

/// 池的运行计数器（快照，非原子读取的一致性视图）
pub const Stats = struct {
    /// 从空闲链直接命中的次数（快路径）
    pool_hits: u64 = 0,
    /// 池空、不得不现场堆分配的次数（快路径失效）
    pool_misses: u64 = 0,
    /// 归还时空闲链已满、直接销毁的次数（高水位缩容）
    discarded: u64 = 0,
    /// 当前空闲链上的 ConnState 数量
    idle: u32 = 0,
};

/// 一条连接在整个生命周期里复用的全部内存。
pub const ConnState = struct {
    /// socket 读缓冲（HTTP 头 + 随头一起到达的 body 前缀）
    read_buf: []u8,
    /// socket 写缓冲
    write_buf: []u8,
    /// 每请求分配器。请求结束时 `resetArena`，不逐块 free。
    arena: std.heap.ArenaAllocator,
    /// 空闲链表指针（仅池内部使用）
    next: ?*ConnState = null,

    /// 每请求分配器。所有权仍属 ConnState，不要在请求之外持有它分配的内存。
    pub fn allocator(self: *ConnState) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 结束一个请求：回收本次请求的全部分配，但保留一段容量。
    ///
    /// `retain_bytes` 是留给下一个请求的「热身容量」——完全释放会让
    /// keep-alive 连接上的每个请求都重新向 OS 要一次内存。
    pub fn resetArena(self: *ConnState, retain_bytes: usize) void {
        _ = self.arena.reset(.{ .retain_with_limit = retain_bytes });
    }

    fn create(
        gpa: std.mem.Allocator,
        read_size: usize,
        write_size: usize,
    ) !*ConnState {
        const state = try gpa.create(ConnState);
        errdefer gpa.destroy(state);

        const read_buf = try gpa.alloc(u8, read_size);
        errdefer gpa.free(read_buf);

        const write_buf = try gpa.alloc(u8, write_size);
        errdefer gpa.free(write_buf);

        state.* = .{
            .read_buf = read_buf,
            .write_buf = write_buf,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        return state;
    }

    fn destroy(self: *ConnState, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.free(self.write_buf);
        gpa.free(self.read_buf);
        gpa.destroy(self);
    }
};

/// ConnState 的空闲链池。
pub const ConnStatePool = struct {
    gpa: std.mem.Allocator,
    read_size: usize,
    write_size: usize,
    /// 空闲链最多保留多少个 ConnState
    max_idle: u32,

    mutex: std.Io.Mutex = .init,
    free_list: ?*ConnState = null,
    idle_count: u32 = 0,

    // 计数器：受 mutex 保护，与链表状态一起更新
    pool_hits: u64 = 0,
    pool_misses: u64 = 0,
    discarded: u64 = 0,

    const Self = @This();

    pub const Options = struct {
        /// 单条连接的读缓冲字节数
        read_size: usize,
        /// 单条连接的写缓冲字节数
        write_size: usize,
        /// 空闲池容量，同时也是启动时预分配的数量
        pool_size: u32,
    };

    /// 创建池并预分配 `pool_size` 个 ConnState。
    ///
    /// 预分配失败不算致命：能分配几个就用几个，剩下的等运行期按需创建。
    /// 启动阶段为了内存不够就拒绝启动，不划算。
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Self {
        var pool: Self = .{
            .gpa = gpa,
            .read_size = opts.read_size,
            .write_size = opts.write_size,
            .max_idle = opts.pool_size,
        };

        var i: u32 = 0;
        while (i < opts.pool_size) : (i += 1) {
            const state = try ConnState.create(gpa, opts.read_size, opts.write_size);
            state.next = pool.free_list;
            pool.free_list = state;
            pool.idle_count += 1;
        }
        return pool;
    }

    /// 销毁池内所有空闲 ConnState。
    ///
    /// 调用方必须保证此时没有任何连接仍持有 acquire 出去的 ConnState
    /// （Server 在 `conn_group.cancel` 之后才 deinit）。
    pub fn deinit(self: *Self, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        var node = self.free_list;
        self.free_list = null;
        self.idle_count = 0;
        self.mutex.unlock(io);

        while (node) |state| {
            const next = state.next;
            state.destroy(self.gpa);
            node = next;
        }
    }

    /// 借一个 ConnState。池空时现场分配（并计入 `pool_misses`）。
    pub fn acquire(self: *Self, io: std.Io) !*ConnState {
        self.mutex.lockUncancelable(io);
        if (self.free_list) |state| {
            self.free_list = state.next;
            self.idle_count -= 1;
            self.pool_hits += 1;
            self.mutex.unlock(io);
            state.next = null;
            return state;
        }
        self.pool_misses += 1;
        self.mutex.unlock(io);

        return ConnState.create(self.gpa, self.read_size, self.write_size);
    }

    /// 归还一个 ConnState。空闲链已满时直接销毁（计入 `discarded`）。
    ///
    /// 归还前会把 arena 完全释放：连接之间不共享任何请求数据，
    /// 而且空闲期间不该继续占着上一条连接撑大的容量。
    pub fn release(self: *Self, io: std.Io, state: *ConnState) void {
        _ = state.arena.reset(.free_all);

        self.mutex.lockUncancelable(io);
        if (self.idle_count >= self.max_idle) {
            self.discarded += 1;
            self.mutex.unlock(io);
            state.destroy(self.gpa);
            return;
        }
        state.next = self.free_list;
        self.free_list = state;
        self.idle_count += 1;
        self.mutex.unlock(io);
    }

    pub fn stats(self: *Self, io: std.Io) Stats {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .pool_hits = self.pool_hits,
            .pool_misses = self.pool_misses,
            .discarded = self.discarded,
            .idle = self.idle_count,
        };
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "ConnStatePool: 预分配后 acquire 走快路径" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try ConnStatePool.init(gpa, .{
        .read_size = 1024,
        .write_size = 512,
        .pool_size = 4,
    });
    defer pool.deinit(io);

    try std.testing.expectEqual(@as(u32, 4), pool.stats(io).idle);

    const a = try pool.acquire(io);
    const b = try pool.acquire(io);
    try std.testing.expectEqual(@as(usize, 1024), a.read_buf.len);
    try std.testing.expectEqual(@as(usize, 512), a.write_buf.len);

    const s = pool.stats(io);
    try std.testing.expectEqual(@as(u64, 2), s.pool_hits);
    try std.testing.expectEqual(@as(u64, 0), s.pool_misses);
    try std.testing.expectEqual(@as(u32, 2), s.idle);

    pool.release(io, a);
    pool.release(io, b);
    try std.testing.expectEqual(@as(u32, 4), pool.stats(io).idle);
}

test "ConnStatePool: 池空时回退到堆分配并计数" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try ConnStatePool.init(gpa, .{
        .read_size = 64,
        .write_size = 64,
        .pool_size = 1,
    });
    defer pool.deinit(io);

    const a = try pool.acquire(io); // 命中
    const b = try pool.acquire(io); // 池空 → 现场分配

    const s = pool.stats(io);
    try std.testing.expectEqual(@as(u64, 1), s.pool_hits);
    try std.testing.expectEqual(@as(u64, 1), s.pool_misses);

    pool.release(io, a);
    pool.release(io, b); // 空闲链已满（max_idle = 1）→ 销毁

    const s2 = pool.stats(io);
    try std.testing.expectEqual(@as(u64, 1), s2.discarded);
    try std.testing.expectEqual(@as(u32, 1), s2.idle);
}

test "ConnStatePool: pool_size 为 0 时全部走堆分配" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try ConnStatePool.init(gpa, .{
        .read_size = 32,
        .write_size = 32,
        .pool_size = 0,
    });
    defer pool.deinit(io);

    const a = try pool.acquire(io);
    pool.release(io, a); // max_idle = 0 → 立即销毁，不泄漏

    const s = pool.stats(io);
    try std.testing.expectEqual(@as(u64, 1), s.pool_misses);
    try std.testing.expectEqual(@as(u64, 1), s.discarded);
    try std.testing.expectEqual(@as(u32, 0), s.idle);
}

test "ConnState: arena 每请求 reset 后仍可继续分配" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try ConnStatePool.init(gpa, .{
        .read_size = 128,
        .write_size = 128,
        .pool_size = 1,
    });
    defer pool.deinit(io);

    const state = try pool.acquire(io);
    defer pool.release(io, state);

    // 第一个请求
    const first = try state.allocator().dupe(u8, "request-1");
    try std.testing.expectEqualStrings("request-1", first);
    state.resetArena(4096);

    // 第二个请求：reset 之后照样能分配（容量被保留，不需要重新向 OS 要）
    const second = try state.allocator().alloc(u8, 2048);
    try std.testing.expectEqual(@as(usize, 2048), second.len);
    state.resetArena(4096);
}

test "ConnStatePool: release 会清空上一条连接的 arena 数据" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try ConnStatePool.init(gpa, .{
        .read_size = 64,
        .write_size = 64,
        .pool_size = 1,
    });
    defer pool.deinit(io);

    const first = try pool.acquire(io);
    _ = try first.allocator().alloc(u8, 100_000); // 撑大 arena
    pool.release(io, first);

    // 复用同一个 ConnState：arena 已被 free_all，不该继续占着 100KB
    const second = try pool.acquire(io);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 0), second.arena.queryCapacity());
    pool.release(io, second);
}
