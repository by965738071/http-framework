//! TCP 监听器 — accept + 连接数背压（回应 bug.md §7）
//!
//! 只负责 TCP accept 和连接数背压。不负责 HTTP 解析、dispatch、
//! 信号、worker——那些在 ConnectionRunner / Shutdown / Server 里。

const std = @import("std");
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
    pub fn accept(self: *Listener) !net.Stream {
        try self.semaphore.wait(self.io);
        return self.tcp_server.accept(self.io);
    }
};
