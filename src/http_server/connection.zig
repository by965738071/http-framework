//! 连接运行器 — 单连接的 keep-alive 循环 + dispatch。
//!
//! **后端无关、非泛型的纯 HTTP 引擎**。这是整个 http_server 里唯一被证明
//! "与运行时无关"的部分：它只依赖 `*std.Io.Reader` / `*std.Io.Writer`
//! （汇合点）+ 一个 std.Io 值，不 `@import` 任何具体运行时。
//!
//! 职责边界：
//! - 不负责建 socket/stream、不设超时、不 close 连接——那些是后端的事
//!   （见 zio_server.zig）。调用方把已建好、已设好超时的 reader/writer 传进来。
//! - 只负责：HTTP 状态机（ConnectionLoop）+ keep-alive 循环 + dispatch +
//!   arena 管理 + 生命周期事件。

const std = @import("std");
const http = std.http;
const http_protocol = @import("http_protocol");
const http_app = @import("http_app");
const http_router = @import("http_router");

pub const ConnectionRunner = struct {
    /// 汇合点：已建好、已设好超时的读写接口（由后端提供）。
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    io: std.Io,
    router: *const http_router.Router,
    config: *const http_app.Config,
    lifecycle: http_app.Lifecycle,
    stats: *http_app.RuntimeState,
    allocator: std.mem.Allocator,
    /// 应用级服务容器（由后端注入），传递给每个请求的 Context。
    services: ?*const http_app.Services = null,

    /// 跑完一条连接的完整 keep-alive 生命周期。不 close 连接（调用方负责）。
    pub fn run(self: *ConnectionRunner) void {
        if (self.stats.shutting_down.load(.monotonic)) return;

        _ = self.stats.active_connections.fetchAdd(1, .monotonic);
        _ = self.stats.total_connections.fetchAdd(1, .monotonic);
        defer _ = self.stats.active_connections.fetchSub(1, .monotonic);

        self.lifecycle.emit(.connection_open, .{});

        var arenas = http_app.Arenas.init(self.allocator);
        defer arenas.deinit();

        var http_server = http.Server.init(self.reader, self.writer);
        var conn_loop = http_protocol.ConnectionLoop.init(self.io, &http_server, &arenas.request);

        while (true) {
            if (self.stats.shutting_down.load(.monotonic)) break;

            const idle_start = std.Io.Timestamp.now(self.io, .real).nanoseconds;

            const result = conn_loop.next() catch |err| {
                writeError(self.writer, .bad_request, "Bad Request");
                if (err != error.HttpConnectionClosing) {
                    std.log.warn("conn_loop: {s}", .{@errorName(err)});
                }
                break;
            };
            const next_result = result orelse break; // connection closed
            var request = next_result.parsed;
            const http_request = next_result.raw;

            _ = self.stats.active_requests.fetchAdd(1, .monotonic);
            const hijack = self.processRequest(&request, http_request, &arenas) catch |err| blk: {
                std.log.err("processRequest: {s}", .{@errorName(err)});
                break :blk null;
            };
            _ = self.stats.active_requests.fetchSub(1, .monotonic);

            // 连接劫持（WebSocket 升级等）：把裸 reader/writer 交给回调，
            // 回调返回后结束整条连接（不再跑 keep-alive）。
            if (hijack) |h| {
                h.run(h.ctx, self.io, self.reader, self.writer, self.allocator) catch |err| {
                    if (err != error.ConnectionClosed and err != error.EndOfStream and err != error.Canceled) {
                        std.log.warn("hijack: {s}", .{@errorName(err)});
                    }
                };
                break;
            }

            const keep_alive = conn_loop.shouldKeepAlive(&request);
            arenas.endRequest(self.config.pool.request_arena_retain_bytes);
            if (!keep_alive) break;

            const idle_elapsed = std.Io.Timestamp.now(self.io, .real).nanoseconds - idle_start;
            if (idle_elapsed > @as(i96, @intCast(self.config.network.idle_timeout_ns))) break;
        }

        self.lifecycle.emit(.connection_close, .{});
    }

    fn processRequest(
        self: *ConnectionRunner,
        request: *http_protocol.Request,
        http_request: *http.Server.Request,
        arenas: *http_app.Arenas,
    ) !?http_app.Hijack {
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
            .services = self.services,
        };

        var res = http_protocol.Response.init(arena_alloc, http_protocol.Sink.fromHttp(http_request));
        defer res.deinit();

        self.lifecycle.emit(.request_start, .{
            .ctx = &ctx,
            .method = request.method,
            .path = request.path,
        });

        const dispatch_start = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        _ = self.router.dispatch(&ctx, &res) catch |err| {
            self.lifecycle.emit(.request_error, .{
                .ctx = &ctx,
                .method = request.method,
                .path = request.path,
                .err = err,
                .route_pattern = state.route_pattern,
            });
            // 兵底：若无 ErrorRenderer（或其未能写响应），handler 抛错后 response 仍未发送，
            // 直接回 500，避免 client 收不到任何响应、挂到超时。
            if (!res.sent) {
                _ = res.statusCode(.internal_server_error);
                res.text("Internal Server Error") catch {};
            }
            return err;
        };
        const latency = std.Io.Timestamp.now(self.io, .real).nanoseconds - dispatch_start;

        self.lifecycle.emit(.request_end, .{
            .ctx = &ctx,
            .method = request.method,
            .path = request.path,
            .status = res.status,
            .route_pattern = state.route_pattern,
            .duration_ns = @intCast(latency),
        });
        if (@backingInt(res.status) >= 500) {
            self.lifecycle.emit(.request_error, .{
                .ctx = &ctx,
                .method = request.method,
                .path = request.path,
                .status = res.status,
                .route_pattern = state.route_pattern,
                .duration_ns = @intCast(latency),
            });
        }

        // 连接劫持（WebSocket 升级）：handler 已经通过 ctx.hijack 注册了接管回调，
        // 不发送常规 HTTP 响应（101 + 后续帧由回调自行写）。把 hijack 钩子上传给 run()。
        // 注意：state 在本函数返回后会随 arena reset 失效，但 Hijack 是值拷贝，
        // 其 ctx 指针指向用户稳定存储（singleton handler 实例等），不依赖 arena。
        if (state.hijack) |h| return h;

        // 兵底：非缓冲模式下 handler 若只设了 status 而从未写 body，补发一个空响应，
        // 避免 client 挂到超时（缓冲模式由 res.flush 处理）。
        if (!res.buffered and !res.sent) {
            res.text("") catch {};
        }
        try res.flush();
        return null;
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
