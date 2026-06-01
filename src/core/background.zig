//! 后台任务队列
//!
//! 轻量级的 fire-and-forget 后台任务系统，用于在 HTTP 响应发送后
//! 异步执行任务（如发送邮件、清理资源、写入日志等）。
//!
//! # 设计模式
//!
//! 使用编译期泛型擦除：`submit` 接收任意类型的上下文指针和回调函数，
//! 内部通过 `*anyopaque` 擦除类型，`drain` 时逐项执行。
//!
//! 线程安全：通过 `std.Io.Mutex` 保护队列操作。
//!
//! # 使用示例
//!
//! ```zig
//! var bg = try BackgroundQueue.init(allocator, io);
//! defer bg.deinit();
//!
//! // 在 handler 中提交后台任务
//! try bg.submit(EmailTask, &email, EmailTask.send);
//!
//! // 在 server 的 keep-alive 循环中（响应发送后）执行
//! try bg.drain();
//! ```

const std = @import("std");

/// 单个后台任务
pub const Task = struct {
    /// 任务回调函数，接收 ctx 指针
    callback: *const fn (*anyopaque) void,
    /// 回调上下文（类型擦除）
    ctx: *anyopaque,
};

/// 后台任务队列
pub const BackgroundQueue = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// I/O 实例
    io: std.Io,
    /// 排队中的任务列表
    tasks: std.ArrayList(Task),
    /// 互斥锁（保护任务队列的并发访问）
    mutex: std.Io.Mutex,

    const Self = @This();

    /// 创建后台任务队列。
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .tasks = try std.ArrayList(Task).initCapacity(allocator, 8),
            .mutex = std.Io.Mutex.init,
        };
    }

    /// 释放队列资源（不清空未执行的任务）。
    pub fn deinit(self: *Self) void {
        self.tasks.deinit(self.allocator);
    }

    /// 提交一个后台任务（fire-and-forget，不立即执行）。
    ///
    /// `T` 为上下文类型，`callback` 为其方法签名 `fn (*T) void`。
    pub fn submit(self: *Self, comptime T: type, ctx: *T, comptime callback: fn (*T) void) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const task = Task{
            .callback = struct {
                fn wrapper(ptr: *anyopaque) void {
                    const t: *T = @ptrCast(@alignCast(ptr));
                    callback(t);
                }
            }.wrapper,
            .ctx = @ptrCast(ctx),
        };

        try self.tasks.append(self.allocator, task);
    }

    /// 处理队列中所有待处理任务。
    ///
    /// 逐个执行所有排队的任务，执行完毕后清空队列。
    /// 通常在 HTTP 响应发送之后调用。
    pub fn drain(self: *Self) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        for (self.tasks.items) |task| {
            task.callback(task.ctx);
        }
        self.tasks.clearRetainingCapacity();
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "BackgroundQueue: init and deinit" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    // 初始化后队列应为空
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}

test "BackgroundQueue: submit and drain single task" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    const Ctx = struct {
        called: bool = false,

        fn execute(self: *@This()) void {
            self.called = true;
        }
    };

    var ctx = Ctx{};
    try bg.submit(Ctx, &ctx, Ctx.execute);
    try bg.drain();

    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}

test "BackgroundQueue: submit and drain multiple tasks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    const Ctx = struct {
        counter: u32 = 0,

        fn increment(self: *@This()) void {
            self.counter += 1;
        }
    };

    var ctx = Ctx{};

    // 提交 5 个任务
    for (0..5) |_| {
        try bg.submit(Ctx, &ctx, Ctx.increment);
    }

    try std.testing.expectEqual(@as(usize, 5), bg.tasks.items.len);
    try bg.drain();

    // 所有 5 个任务都应执行完毕
    try std.testing.expectEqual(@as(u32, 5), ctx.counter);
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}

test "BackgroundQueue: tasks with different context types" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    const EmailCtx = struct {
        sent: bool = false,

        fn send(self: *@This()) void {
            self.sent = true;
        }
    };

    const LogCtx = struct {
        messages: u32 = 0,

        fn flush(self: *@This()) void {
            self.messages += 1;
        }
    };

    var email = EmailCtx{};
    var log = LogCtx{};

    try bg.submit(EmailCtx, &email, EmailCtx.send);
    try bg.submit(LogCtx, &log, LogCtx.flush);
    try bg.submit(LogCtx, &log, LogCtx.flush);

    try bg.drain();

    try std.testing.expect(email.sent);
    try std.testing.expectEqual(@as(u32, 2), log.messages);
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}

test "BackgroundQueue: drain clears queue even without tasks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    // 空队列 drain 不应报错
    try bg.drain();
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}
