//! TCP 监听器 — accept + 连接数背压（回应 bug.md §7）
//!
//! 只负责 TCP accept 和连接数背压。不负责 HTTP 解析、dispatch、
//! 信号、worker——那些在 ConnectionRunner / Shutdown / Server 里。
//!
//! Windows 下阻塞的 accept() 不会被 Ctrl+C 打断，因此 Server.run 用
//! WaitForMultipleObjects 同时等待“有关可接收连接”和“关闭事件”，
//! 由关闭事件唤醒主循环，而不是在这里做轮询。

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
    /// 返回 error.Canceled 时调用方应退出。
    pub fn accept(self: *Listener) !net.Stream {
        try self.semaphore.wait(self.io);
        return self.tcp_server.accept(self.io) catch |err| {
            // accept 失败也要归还信号量许可，避免背压计数器泄漏。
            self.semaphore.post(self.io);
            return err;
        };
    }
};
