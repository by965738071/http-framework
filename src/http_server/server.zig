//! Server — 纯组装器（回应 bug.md §7）
//!
//! 原来 Server 一个 struct 扛 9 种关注点。现在只做组装：
//! Listener + Router + Lifecycle + Shutdown + Io.Group 用 Io 串起来。
//! 每种关注点可独立测试。
//!
//! 信号处理（SIGINT/SIGTERM）由 installSignalHandlers() 注册，
//! handler 只做 atomic store shutdown flag。
//! Listener.accept() 使用 poll timeout 定期检查 flag，无需 pipe。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const http_app = @import("http_app");
const http_router = @import("http_router");
const Listener = @import("listener.zig").Listener;
const ConnectionRunner = @import("connection.zig").ConnectionRunner;
const connectionTask = @import("connection.zig").connectionTask;
const Shutdown = @import("shutdown.zig").Shutdown;

const is_windows = builtin.target.os.tag == .windows;

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

    var global_instance: ?*Server = null;

    /// 信号处理器：只需 atomic store shutdown flag。
    /// Listener.accept() 的 poll timeout 会检测到 flag 并退出。
    fn signalHandler(sig: posix.SIG) callconv(.c) void {
        _ = sig;
        // Use raw write (async-signal-safe) to confirm handler fires
        const prefix = "SIGNAL HANDLER CALLED\n";
        _ = std.c.write(2, prefix, prefix.len);
        if (global_instance) |s| {
            s.shutdown.begin();
        }
    }

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
        // DEBUG: confirm handler is installed
        var check: posix.Sigaction = undefined;
        posix.sigaction(.INT, null, &check);
        if (check.handler.handler) |h| {
            _ = h; // handler is set
            const msg = "SIGINT handler installed OK\n";
            _ = std.c.write(2, msg, msg.len);
        } else {
            const msg = "SIGINT handler is NULL - FAILED\n";
            _ = std.c.write(2, msg, msg.len);
        }
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

    pub fn run(self: *Server) !void {
        while (!self.shutdown.isShuttingDown()) {
            const stream = self.listener.accept() catch |err| {
                if (err == error.Canceled) break;
                if (self.shutdown.isShuttingDown()) break;
                _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

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

            self.group.concurrent(self.io, connectionTask, .{runner}) catch {
                runner.run();
                runner.deinit();
                self.allocator.destroy(runner);
            };
        }

        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
        self.shutdown.drain(self.io);
    }
};
