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
//! // 交给 Server 周期性排空（BackgroundQueue 实现 core.Worker）
//! server.setWorker(bg.worker());
//!
//! // 或者自己控制节奏
//! try bg.drain();
//! ```

const std = @import("std");
const core = @import("core");

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
    /// 将排队的任务并发提交到线程池执行，所有任务执行完毕后清空队列。
    /// 调用线程会阻塞直到所有任务完成，但由于 drain 通常在
    /// HTTP 响应发送之后调用，从 handler 视角看是 fire‑and‑forget。
    pub fn drain(self: *Self) !void {
        try self.mutex.lock(self.io);
        const task_count = self.tasks.items.len;
        if (task_count == 0) {
            self.mutex.unlock(self.io);
            return;
        }
        const tasks_to_run = try self.allocator.alloc(Task, task_count);
        @memcpy(tasks_to_run, self.tasks.items);
        self.tasks.clearRetainingCapacity();
        self.mutex.unlock(self.io);
        defer self.allocator.free(tasks_to_run);

        // 使用 Group 并发执行所有任务（线程池 + 自动清理）
        var group: std.Io.Group = .init;
        for (tasks_to_run) |t| {
            group.async(self.io, struct {
                fn run(task: Task) void {
                    task.callback(task.ctx);
                }
            }.run, .{t});
        }
        _ = try group.await(self.io);
    }

    // ---- core.Worker 实现 ----

    /// 由 Server 按固定间隔调用。drain 失败（内存不足等）静默重试下一轮——
    /// 任务仍在队列里，不会丢。
    pub fn tick(self: *Self) void {
        self.drain() catch |err| {
            std.log.warn("BackgroundQueue drain failed: {}", .{err});
        };
    }

    /// 取得可注入 `server.setWorker()` 的接口句柄。
    pub fn worker(self: *Self) core.Worker {
        return core.Worker.init(Self, self);
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "BackgroundQueue: init and deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    // 初始化后队列应为空
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}

test "BackgroundQueue: submit and drain single task" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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
    const io = std.testing.io;

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
    const io = std.testing.io;

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
    const io = std.testing.io;

    var bg = try BackgroundQueue.init(allocator, io);
    defer bg.deinit();

    // 空队列 drain 不应报错
    try bg.drain();
    try std.testing.expectEqual(@as(usize, 0), bg.tasks.items.len);
}
