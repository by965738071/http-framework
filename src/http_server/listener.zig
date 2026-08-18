//! TCP 监听器 — accept + 连接数背压（回应 bug.md §7）
//!
//! 只负责 TCP accept 和连接数背压。不负责 HTTP 解析、dispatch、
//! 信号、worker——那些在 ConnectionRunner / Shutdown / Server 里。
//!
//! 接受循环使用 poll() + 短超时：每次超时后检查 shutdown flag。
//! 信号处理器只需 atomic store，不需要 pipe。

const std = @import("std");
const posix = std.posix;
const c = std.c;
const net = std.Io.net;
const http_app = @import("http_app");

pub const Listener = struct {
    io: std.Io,
    tcp_server: net.Server,
    config: *const http_app.NetworkConfig,
    semaphore: std.Io.Semaphore,
    stats: *http_app.RuntimeState,

    pub fn init(io: std.Io, config: *const http_app.NetworkConfig, stats: *http_app.RuntimeState) !Listener {
        const address = try net.IpAddress.parseIp4(config.address, config.port);
        const tcp_server = try address.listen(io, .{
            .kernel_backlog = config.tcp_backlog,
            .reuse_address = config.reuse_address,
        });

        return .{
            .io = io,
            .tcp_server = tcp_server,
            .config = config,
            .semaphore = .{ .permits = config.max_connections },
            .stats = stats,
        };
    }

    pub fn deinit(self: *Listener) void {
        self.tcp_server.deinit(self.io);
    }

    /// 接受新连接。达到 max_connections 时阻塞（背压）。
    /// 取消（shutdown）时返回 error.Canceled。
    ///
    /// 使用 poll() 设置超时，每次超时后检查 shutdown flag。
    /// 信号处理器只需 atomic store shutdown flag，不需要额外唤醒机制。
    pub fn accept(self: *Listener) !net.Stream {
        const listen_fd = self.tcp_server.socket.handle;
        const poll_in: c_short = @intCast(c.POLL.IN);
        const poll_err: c_short = @intCast(c.POLL.ERR);
        const poll_hup: c_short = @intCast(c.POLL.HUP);

        while (true) {
            try self.semaphore.wait(self.io);

            // poll with 1s timeout — 超时后检查 shutdown flag
            var fds = [_]posix.pollfd{
                .{ .fd = listen_fd, .events = poll_in | poll_err | poll_hup, .revents = 0 },
            };

            const n = posix.poll(&fds, 1000) catch |err| {
                // EINTR: signal interrupted, check shutdown flag then retry
                if (self.stats.shutting_down.load(.monotonic)) return error.Canceled;
                if (err == error.Interrupted) continue;
                return err;
            };

            if (n == 0) {
                // Timeout: check shutdown flag
                if (self.stats.shutting_down.load(.monotonic)) return error.Canceled;
                continue;
            }

            // Listener socket readable → accept
            if (fds[0].revents & poll_in != 0) {
                return self.tcp_server.accept(self.io);
            }

            // POLLERR/POLLHUP on listener → treat as shutdown
            return error.Canceled;
        }
    }
};
