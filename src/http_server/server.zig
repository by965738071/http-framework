//! Server — 纯组装器（回应 bug.md §7）
//!
//! 原来 Server 一个 struct 扛 9 种关注点。现在只做组装：
//! Listener + Router + Lifecycle + Shutdown + Io.Group 用 Io 串起来。
//! 每种关注点可独立测试。
//!
//! 信号处理（SIGINT/SIGTERM）由 signal.install() 注册，
//! handler 只做 atomic store shutdown flag。
//! Listener.accept() 使用 poll timeout 定期检查 flag，无需 pipe。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;
const windows = std.os.windows;
const http_app = @import("http_app");
const http_router = @import("http_router");
const Listener = @import("listener.zig").Listener;
const ConnectionRunner = @import("connection.zig").ConnectionRunner;
const connectionTask = @import("connection.zig").connectionTask;
const Shutdown = @import("shutdown.zig").Shutdown;
const signal = @import("signal.zig");

const is_windows = builtin.target.os.tag == .windows;

// Windows 事件 API（std 未直接暴露，这里按需声明）。与 signal.zig 中
// SetConsoleCtrlHandler 的声明方式一致（本项目按 Windows 目标构建）。
extern "kernel32" fn CreateEventW(
    lp_event_attributes: ?*const anyopaque,
    b_manual_reset: windows.BOOL,
    b_initial_state: windows.BOOL,
    lp_name: ?[*:0]const u16,
) callconv(.c) ?windows.HANDLE;

extern "kernel32" fn WaitForMultipleObjects(
    n_count: windows.DWORD,
    lp_handles: [*]const windows.HANDLE,
    b_wait_all: windows.BOOL,
    dw_milliseconds: windows.DWORD,
) callconv(.c) windows.DWORD;

extern "kernel32" fn CloseHandle(h_object: windows.HANDLE) callconv(.c) windows.BOOL;

pub const Server = struct {
    io: std.Io,
    config: http_app.Config,
    runtime: http_app.RuntimeState,
    listener: Listener,
    router: *const http_router.Router,
    lifecycle: http_app.Lifecycle,
    shutdown: Shutdown,
    group: std.Io.Group,
    allocator: std.mem.Allocator,

    /// 安装信号处理器（SIGINT / SIGTERM / Windows Ctrl+C）
    pub fn installSignalHandlers(self: *Server) void {
        const handle = signal.ShutdownHandle{
            .flag = &self.shutdown.stats.shutting_down,
        };
        signal.setHandle(handle);
        signal.install();
    }

    /// Server 的初始化入口
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: http_app.Config,
        router: *const http_router.Router,
    ) !Server {
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

    /// 初始化 Listener 与 Shutdown，准备好运行
    pub fn setup(self: *Server) !void {
        self.listener = try Listener.init(self.io, &self.config.network, &self.runtime);
        self.shutdown = Shutdown.init(&self.runtime);
    }

    /// 反初始化 Listener
    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    /// 注册生命周期钩子
    pub fn setLifecycle(self: *Server, lifecycle: http_app.Lifecycle) void {
        self.lifecycle = lifecycle;
    }

    /// 发起优雅关机
    pub fn beginShutdown(self: *Server) void {
        self.shutdown.begin();
        // 注意：不要在这里关闭监听 socket。Windows 下从 Ctrl 处理器线程关闭
        // socket 会让阻塞中的 accept() 命中 std 的 `unreachable` 分支而 panic。
        // 主循环通过 Listener.accept() 的轮询超时周期性检查 shutting_down
        // 标志，因此只需置位标志即可让 run() 及时退出。
    }

    /// 统计信息（用于监控）
    pub fn stats(self: *const Server) http_app.ServerStats {
        return .{
            .active_connections = self.runtime.active_connections.load(.monotonic),
            .total_connections = self.runtime.total_connections.load(.monotonic),
            .active_requests = self.runtime.active_requests.load(.monotonic),
            .accept_errors = self.runtime.accept_errors.load(.monotonic),
            .shutting_down = self.runtime.shutting_down.load(.monotonic),
        };
    }

    /// 主运行循环
    pub fn run(self: *Server) !void {
        if (comptime is_windows) {
            try self.runWindows();
        } else {
            try self.runPosix();
        }

        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
        self.shutdown.drain(self.io);
    }

    /// POSIX：信号会打断阻塞的 accept()（EINTR），直接阻塞 accept 即可。
    fn runPosix(self: *Server) !void {
        while (true) {
            if (self.shutdown.isShuttingDown()) break;

            const stream = self.listener.accept() catch |err| {
                if (err == error.Canceled) break;
                if (self.shutdown.isShuttingDown()) break;
                _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.spawnConnection(stream);
        }
    }

    /// Windows：阻塞的 accept() 不会被 Ctrl+C 打断，因此用一个关闭事件
    /// 唤醒主循环。WaitForMultipleObjects 同时等待“有关可接收连接”和
    /// “关闭事件”——按下 Ctrl+C 时只置位关闭事件，绝不碰监听 socket，
    /// 从而避免踩进 std.Io 的 `.CANCELLED => unreachable` 分支。
    fn runWindows(self: *Server) !void {
        // 手动复位事件：置位后一直保持 signaled，确保循环一定能醒来。
        const event = CreateEventW(null, windows.BOOL.TRUE, windows.BOOL.FALSE, null) orelse
            return error.SystemResources;
        signal.setEventHandle(event);
        defer {
            signal.setEventHandle(null);
            _ = CloseHandle(event);
        }

        while (true) {
            if (self.shutdown.isShuttingDown()) break;

            const listen = self.listener.tcp_server.socket.handle;
            // 关闭事件放在 index 0：若关闭事件与连接同时就绪，优先返回关闭。
            const handles = [_]windows.HANDLE{ event, listen };
            const r = WaitForMultipleObjects(2, &handles, windows.BOOL.FALSE, 0xffffffff);
            if (r == 0) break; // 关闭事件
            if (r == 1) {
                const stream = self.listener.accept() catch |err| {
                    if (self.shutdown.isShuttingDown()) break;
                    _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                    std.log.warn("accept error: {s}", .{@errorName(err)});
                    continue;
                };
                self.spawnConnection(stream);
            } else {
                // WAIT_TIMEOUT / WAIT_FAILED：回到循环顶部重新检查。
                if (self.shutdown.isShuttingDown()) break;
                continue;
            }
        }
    }

    /// 将已接受的连接交给连接池处理（抽离出来供两个平台复用）。
    fn spawnConnection(self: *Server, stream: net.Stream) void {
        const runner = self.allocator.create(ConnectionRunner) catch {
            stream.close(self.io);
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
            return;
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
            return;
        };

        self.group.concurrent(self.io, connectionTask, .{runner}) catch {
            runner.run();
            runner.deinit();
            self.allocator.destroy(runner);
        };
    }
};
