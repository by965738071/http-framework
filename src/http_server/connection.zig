//! 连接运行器 — 单连接的 keep-alive 循环 + dispatch（回应 bug.md §7）
//!
//! 从 Server 里拆出来的关注点：
//! - HTTP 状态机 + keep-alive 循环（用 http_protocol.ConnectionLoop）
//! - 构建 Context（Request + State + Config + arena）
//! - router.dispatch
//! - arena 管理（两级：request + connection）
//! - 生命周期事件发射
//!
//! 不负责 TCP accept（Listener）、信号（Shutdown）、组装（Server）。

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const net = std.Io.net;
const posix = std.posix;
const windows = std.os.windows;
const http_protocol = @import("http_protocol");
const http_app = @import("http_app");
const http_router = @import("http_router");

/// winsock 的 setsockopt（std 未导出，需自行声明；需在 Windows 链接 ws2_32）。
extern "ws2_32" fn setsockopt(
    s: usize,
    level: c_int,
    optname: c_int,
    optval: ?*const anyopaque,
    optlen: c_int,
) c_int;

pub const ConnectionRunner = struct {
    stream: net.Stream,
    io: std.Io,
    router: *const http_router.Router,
    config: *const http_app.Config,
    lifecycle: http_app.Lifecycle,
    stats: *http_app.RuntimeState,
    allocator: std.mem.Allocator,
    read_buf: []u8,
    write_buf: []u8,

    /// 每连接独立分配缓冲区——并发安全（回应 bug.md §7 + async dispatch）
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: net.Stream,
        router: *const http_router.Router,
        config: *const http_app.Config,
        lifecycle: http_app.Lifecycle,
        stats: *http_app.RuntimeState,
    ) !ConnectionRunner {
        const read_size = @max(config.http.read_buffer_size, MIN_READ_BUF);
        const write_size = @max(config.http.write_buffer_size, MIN_WRITE_BUF);
        return .{
            .stream = stream,
            .io = io,
            .router = router,
            .config = config,
            .lifecycle = lifecycle,
            .stats = stats,
            .allocator = allocator,
            .read_buf = try allocator.alloc(u8, read_size),
            .write_buf = try allocator.alloc(u8, write_size),
        };
    }

    pub fn deinit(self: *ConnectionRunner) void {
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
    }

    /// 设置 SO_RCVTIMEO / SO_SNDTIMEO（fix.md §二.6：防慢攻击）。
    /// 阻塞 read/write 超时后返回错误，conn_loop.next() catch 到后 break。
    /// 调用方（run）通过 idle 超时兜底，所以这里 setsockopt 失败不致命。
    ///
    /// POSIX 用 std.posix.setsockopt；Windows 的 std.posix.setsockopt 已被
    /// 移除（"use std.Io instead"），改用 winsock 的 setsockopt，二者语义
    /// 等价：都用毫秒级超时让阻塞 recv/send 超时。
    fn applySocketTimeouts(self: *ConnectionRunner) void {
        const rcv_ns = self.config.network.read_timeout_ns;
        const snd_ns = self.config.network.write_timeout_ns;

        if (comptime builtin.target.os.tag == .windows) {
            const ws2_32 = @import("std").os.windows.ws2_32;
            // winsock 的 SO_RCVTIMEO/SO_SNDTIMEO 接受毫秒 DWORD。
            var rcv_ms: c_ulong = @intCast(@divTrunc(rcv_ns, 1_000_000));
            var snd_ms: c_ulong = @intCast(@divTrunc(snd_ns, 1_000_000));
            const sock: usize = @intFromPtr(self.stream.socket.handle);
            _ = setsockopt(sock, @intCast(ws2_32.SOL.SOCKET), @intCast(ws2_32.SO.RCVTIMEO), &rcv_ms, @sizeOf(c_ulong));
            _ = setsockopt(sock, @intCast(ws2_32.SOL.SOCKET), @intCast(ws2_32.SO.SNDTIMEO), &snd_ms, @sizeOf(c_ulong));
        } else {
            const fd = self.stream.socket.handle;
            const read_tv = posix.timeval{
                .sec = @intCast(rcv_ns / 1_000_000_000),
                .usec = @intCast((rcv_ns % 1_000_000_000) / 1_000),
            };
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&read_tv)) catch {};
            const write_tv = posix.timeval{
                .sec = @intCast(snd_ns / 1_000_000_000),
                .usec = @intCast((snd_ns % 1_000_000_000) / 1_000),
            };
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&write_tv)) catch {};
        }
    }

    pub fn run(self: *ConnectionRunner) void {
        defer self.stream.close(self.io);

        if (self.stats.shutting_down.load(.monotonic)) return;

        // 设置 socket 读写超时（fix.md §二.6：防慢攻击）。
        // SO_RCVTIMEO / SO_SNDTIMEO 让阻塞 read/write 在超时后返回错误，
        // conn_loop.next() catch 到错误后 break 关闭连接。
        self.applySocketTimeouts();

        _ = self.stats.active_connections.fetchAdd(1, .monotonic);
        _ = self.stats.total_connections.fetchAdd(1, .monotonic);
        defer _ = self.stats.active_connections.fetchSub(1, .monotonic);

        self.lifecycle.emit(.connection_open, .{});

        // 两级 arena（回应 bug.md §12）
        var arenas = http_app.Arenas.init(self.allocator);
        defer arenas.deinit();

        var reader = self.stream.reader(self.io, self.read_buf);
        var writer = self.stream.writer(self.io, self.write_buf);
        var http_server = http.Server.init(&reader.interface, &writer.interface);

        var conn_loop = http_protocol.ConnectionLoop.init(self.io, &http_server, &arenas.request);

        const recoverable_errors: u32 = 0;
        const max_recoverable: u32 = 10;

        while (true) {
            if (self.stats.shutting_down.load(.monotonic)) break;

            // idle timeout：记录等待新请求的开始时间（fix.md §二.6）
            const idle_start = std.Io.Timestamp.now(self.io, .real).nanoseconds;

            const result = conn_loop.next() catch |err| {
                // Protocol error → send 400 and close
                writeError(&writer.interface, .bad_request, "Bad Request");
                if (err != error.HttpConnectionClosing) {
                    std.log.warn("conn_loop: {s}", .{@errorName(err)});
                }
                break;
            };
            const next_result = result orelse break; // connection closed
            var request = next_result.parsed;
            // next_result.raw 已是 arena 分配的指针，生命周期覆盖整个请求，无需修正
            const http_request = next_result.raw;

            _ = self.stats.active_requests.fetchAdd(1, .monotonic);

            // request_start 在 processRequest 内部发射——那时 ctx 已创建，
            // LoggingHook 能拿到 rid/method/path（回应 fix.md §三：request_start 无 ctx）
            self.processRequest(&request, http_request, &arenas) catch |err| {
                std.log.err("processRequest: {s}", .{@errorName(err)});
            }; // 注意：processRequest 内部 try dispatch，错误会冒泡到 ErrorRenderer

            _ = self.stats.active_requests.fetchSub(1, .monotonic);

            // 先检查 keep-alive（需要 request.head_bytes），再 reset arena
            const keep_alive = conn_loop.shouldKeepAlive(&request);

            // 请求结束：reset request arena
            arenas.endRequest(self.config.pool.request_arena_retain_bytes);

            if (recoverable_errors >= max_recoverable) break;

            if (!keep_alive) break;

            // idle timeout 检查：如果处理完一个请求后已超过 idle 超时，关闭连接。
            // 这主要保护 keep-alive 等待期——SO_RCVTIMEO 会在读阶段超时，
            // 这里是处理完成后到下一个读之间的空闲判断。
            const idle_elapsed = std.Io.Timestamp.now(self.io, .real).nanoseconds - idle_start;
            if (idle_elapsed > @as(i96, @intCast(self.config.network.idle_timeout_ns))) break;

            // 响应发送完成后， http_request 的内部状态已经推进到下一个请求位置。
        }

        self.lifecycle.emit(.connection_close, .{});
    }

    fn processRequest(
        self: *ConnectionRunner,
        request: *http_protocol.Request,
        http_request: *http.Server.Request,
        arenas: *http_app.Arenas,
    ) !void {
        const arena_alloc = arenas.requestAllocator();

        var state = http_app.RequestState{};
        defer state.deinit(arena_alloc);

        const req_config = http_app.RequestConfig{
            .trust_proxy = self.config.body.trust_proxy_headers,
            .body_size_limit = self.config.body.size_limit,
            .lazy_read_size = self.config.body.lazy_read_size,
        };

        var ctx = http_app.Context{
            .request = request,
            .state = &state,
            .config = &req_config,
            .arena = arena_alloc,
            .io = self.io,
        };

        // 用真实 http.Server.Request 构建 Sink（回应 bug.md §8）
        // 现在不再用 testSink，而是通过 fromHttp 调用 req.respond()。
        var res = http_protocol.Response.init(arena_alloc, http_protocol.Sink.fromHttp(http_request));
        defer res.deinit();

        // ctx 已创建，发射 request_start——hook 能拿到 rid/method/path
        self.lifecycle.emit(.request_start, .{
            .ctx = &ctx,
            .method = request.method,
            .path = request.path,
        });

        const dispatch_start = std.Io.Timestamp.now(self.io, .real).nanoseconds;

        _ = try self.router.dispatch(&ctx, &res);
        const latency = std.Io.Timestamp.now(self.io, .real).nanoseconds - dispatch_start;

        self.lifecycle.emit(.request_end, .{
            .ctx = &ctx,
            .method = request.method,
            .path = request.path,
            .status = res.status,
            .route_pattern = state.route_pattern,
            .duration_ns = @intCast(latency),
        });
        // dispatch 内部已处理 404/405（走全局中间件管道），这里只做兜底 flush
        // 确保缓冲模式的响应被发送（中间件可能忘记 flush）
        try res.flush();
    }
};

fn writeError(writer: *std.Io.Writer, status: http.Status, msg: []const u8) void {
    _ = writer.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{
        @backingInt(status),
        @tagName(status),
        msg.len,
        msg,
    }) catch {};
}

const MIN_READ_BUF = 2 * 1024;
const MIN_WRITE_BUF = 512;

/// 并发任务入口——由 Server 通过 Io.Group.concurrent 派发。
/// runner 在堆上分配，run() 结束后自行释放。
/// 返回 Cancelable!void 以满足 Io concurrent API 的要求。
pub fn connectionTask(runner: *ConnectionRunner) std.Io.Cancelable!void {
    runner.run();
    runner.deinit();
    runner.allocator.destroy(runner);
}
