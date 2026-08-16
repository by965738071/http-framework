//! 优雅关闭（回应 bug.md §7）
//!
//! 把 graceful shutdown 从 Server 里拆出来。不负责信号处理——
//! 信号是部署形态，由 main.zig 调 `shutdown.begin()`。

const std = @import("std");
const http_app = @import("http_app");

pub const Shutdown = struct {
    stats: *http_app.RuntimeState,
    drain_timeout_ns: u64 = 30 * std.time.ns_per_s,

    pub fn init(stats: *http_app.RuntimeState) Shutdown {
        return .{ .stats = stats };
    }

    /// 标记服务器进入关闭状态。新连接会被 ConnectionRunner 拒绝。
    pub fn begin(self: *Shutdown) void {
        self.stats.shutting_down.store(true, .monotonic);
    }

    pub fn isShuttingDown(self: *const Shutdown) bool {
        return self.stats.shutting_down.load(.monotonic);
    }

    /// 等待所有活跃连接结束，最多等 drain_timeout_ns。
    pub fn drain(self: *Shutdown, io: std.Io) void {
        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        while (true) {
            const active = self.stats.active_connections.load(.monotonic);
            if (active == 0) return;
            const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - start;
            if (elapsed >= self.drain_timeout_ns) return;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
    }
};
