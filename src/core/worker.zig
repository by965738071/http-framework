//! 后台工作者接口（核心侧）
//!
//! Server 的事件循环之外常常需要一个周期性执行的任务（清理过期会话、
//! 排空异步队列、刷新缓存……）。核心提供"按固定间隔调用你一次"这个能力，
//! 但不关心你要做什么——那是 `background`、`session` 等模块的事。

const std = @import("std");

/// 周期性后台工作者。
pub const Worker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 执行一轮工作。由 Server 按 `tick_interval_ns` 周期调用，
        /// 并在关闭前再调用最后一次，尽量不丢任务。
        ///
        /// 不得返回错误，也不应长时间阻塞——它与请求处理共享 IO 运行时。
        tick: *const fn (ptr: *anyopaque) void,
    };

    /// 由具体实现构造。`T` 需提供 `fn tick(*T) void`。
    pub fn init(comptime T: type, impl: *T) Worker {
        const gen = struct {
            fn tick(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                T.tick(self);
            }
        };
        return .{
            .ptr = impl,
            .vtable = &.{ .tick = gen.tick },
        };
    }

    pub fn tick(self: Worker) void {
        self.vtable.tick(self.ptr);
    }
};

// =========================================================================
// 测试
// =========================================================================

const CountingWorker = struct {
    ticks: usize = 0,
    fn tick(self: *CountingWorker) void {
        self.ticks += 1;
    }
};

test "Worker dispatches through vtable" {
    var w = CountingWorker{};
    const worker = Worker.init(CountingWorker, &w);
    worker.tick();
    worker.tick();
    try std.testing.expectEqual(@as(usize, 2), w.ticks);
}
