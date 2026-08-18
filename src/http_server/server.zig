//! Server — 纯组装器（回应 bug.md §7）
//!
//! 原来 Server 一个 struct 扛 9 种关注点。现在只做组装：
//! Listener + Router + Lifecycle + Shutdown + Io.Group 用 Io 串起来。
//! 每种关注点可独立测试。
//!
//! 信号处理（SIGINT/SIGTERM）由 installSignalHandlers() 注册，
//! handler 是 async-signal-safe 的：原子 store + close(fd) 唤醒 accept。
//!
//! 并发模型（回应 bug.md §7 + async dispatch）：
//!   accept 循环在主线程；每个连接通过 Io.Group.concurrent 派发到
//!   独立的并发任务。Io.Threaded 会用线程池执行这些任务。
//!   如果并发上限达到（ConcurrencyUnavailable），退化到就地处理
//!   ——形成自然的背压。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const http_app = @import("http_app");
const http_router = @import("http_router");
const Listener = @import("listener.zig").Listener;
const ConnectionRunner = @import("connection.zig").ConnectionRunner;
const connectionTask = @import("connection.zig").connectionTask;
const Shutdown = @import("shutdown.zig").Shutdown;

/// Windows 没有 POSIX 信号（posix.Sigaction 是桩），信号处理逻辑整体跳过。
const is_windows = builtin.target.os.tag == .windows;

pub const Server = struct {
    io: std.Io,
    config: http_app.Config,
    runtime: http_app.RuntimeState,
    listener: Listener,
    router: *const http_router.Router,
    lifecycle: http_app.Lifecycle,
    shutdown: Shutdown,
    /// 所有活跃连接任务属于这个 group。
    /// shutdown 时 cancel + await 实现优雅关闭。
    group: std.Io.Group,
    allocator: std.mem.Allocator,

    /// 全局指针——信号处理器通过它触发 shutdown。
    /// 只能是 single-owner：main.zig 里唯一的 Server 实例。
    var global_instance: ?*Server = null;

    /// 信号处理器入口（async-signal-safe：原子 store + close(fd)）。
    ///
    /// 仅调 shutdown.begin() 不足以唤醒阻塞的 accept()（Io.Threaded
    /// 会自动重启被信号中断的 syscall）。所以同时 close(fd) 让
    /// accept() 返回 SocketNotListening，run 循环随后检查
    /// isShuttingDown() 退出。close 是 async-signal-safe。
    fn signalHandler(sig: posix.SIG) callconv(.c) void {
        _ = sig;
        if (global_instance) |s| {
            s.shutdown.begin();
            // 唤醒可能阻塞在 accept() 的运行循环：close fd 让 accept 返回。
            // 用 std.Io 关闭监听 socket（跨平台，无需 libc）。
            s.listener.tcp_server.socket.close(s.io);
        }
    }

    /// 注册为全局实例，并安装 SIGINT/SIGTERM 处理器。
    /// 必须在 run() 之前调用。
    /// Windows 上无 POSIX 信号，函数直接返回（Ctrl+C 由进程终止处理）。
    pub fn installSignalHandlers(self: *Server) void {
        if (comptime is_windows) return;
        global_instance = self;
        const act: posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        // SIGINT 和 SIGTERM 都触发同一个 handler。
        posix.sigaction(.INT, &act, null);
        posix.sigaction(.TERM, &act, null);
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: http_app.Config, router: *const http_router.Router) !Server {
        return .{
            .io = io,
            .config = config,
            .runtime = .{},
            .listener = undefined,
            .router = router,
            .lifecycle = .{},
            .shutdown = .{ .stats = undefined },
            .group = .init,
            .allocator = allocator,
        };
    }

    /// 在 Server 落到最终位置后调用，修正内部自指针。
    /// 必须在 init 之后、run 之前调用。
    pub fn setup(self: *Server) !void {
        self.listener = try Listener.init(self.io, &self.config.network, &self.runtime);
        self.shutdown = Shutdown.init(&self.runtime);
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    pub fn setLifecycle(self: *Server, lifecycle: http_app.Lifecycle) void {
        self.lifecycle = lifecycle;
    }

    pub fn beginShutdown(self: *Server) void {
        self.shutdown.begin();
    }

    pub fn stats(self: *const Server) http_app.ServerStats {
        return .{
            .active_connections = self.runtime.active_connections.load(.monotonic),
            .total_connections = self.runtime.total_connections.load(.monotonic),
            .active_requests = self.runtime.active_requests.load(.monotonic),
            .accept_errors = self.runtime.accept_errors.load(.monotonic),
            .shutting_down = self.runtime.shutting_down.load(.monotonic),
        };
    }

    /// 主运行循环。阻塞直到 shutdown 被调用。
    /// 退出方式：SIGINT/SIGTERM → installSignalHandlers 注册的 handler →
    /// shutdown.begin() → isShuttingDown() 返回 true → 循环退出 →
    /// cancel + await 活跃连接 → drain。
    pub fn run(self: *Server) !void {
        while (!self.shutdown.isShuttingDown()) {
            const stream = self.listener.accept() catch |err| {
                _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                if (self.shutdown.isShuttingDown()) break;
                // accept 错误：短暂等待后重试
                try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real);
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

            // 堆分配 runner——任务可能比当前栈帧活得更久
            const runner = self.allocator.create(ConnectionRunner) catch {
                stream.close(self.io);
                try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(50), .real);
                continue;
            };
            errdefer self.allocator.destroy(runner);

            runner.* = ConnectionRunner.init(
                self.allocator,
                self.io,
                stream,
                self.router,
                &self.config,
                self.lifecycle,
                &self.runtime,
            ) catch |err| {
                std.log.err("failed to init connection runner: {s}", .{@errorName(err)});
                self.allocator.destroy(runner);
                stream.close(self.io);
                continue;
            };

            // 派发到并发任务（回应 bug.md §7：async dispatch）
            // Group.concurrent 保证任务被分配到一个并发单元。
            // 如果并发上限达到，退化到就地处理——自然背压。
            self.group.concurrent(self.io, connectionTask, .{runner}) catch {
                // ConcurrencyUnavailable：就地处理（退化模式）
                runner.run();
                runner.deinit();
                self.allocator.destroy(runner);
            };
        }

        // 优雅关闭：cancel 所有活跃连接，等待它们清理
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
        self.shutdown.drain(self.io);
    }
};
