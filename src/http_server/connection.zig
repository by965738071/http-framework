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
    /// 对端 IP 地址（由后端从 accept 结果注入），透传到每个请求的 Context。
    /// null 表示后端未提供（如内存测试后端或 Unix socket）。
    peer_ip: ?std.Io.net.IpAddress = null,

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

            const result = conn_loop.next() catch |err| {
                // 只有真正的客户端协议错误才写响应。
                // 旧代码在判断错误类型「之前」就无条件写了 400，于是每一个正常关闭
                // 的 keep-alive 连接、每一次读超时都会往（多半已关闭的）连接里塞一个
                // 伪造的 400 Bad Request。conn_loop 现在把三类情况分开：
                //   - 返回 null      → 连接正常结束（EOF / HttpConnectionClosing / 读超时）
                //   - ProtocolError  → 400
                //   - HeadTooLarge   → 431（RFC 6585 §5）
                switch (err) {
                    error.ProtocolError => writeError(self.writer, .bad_request, "Bad Request"),
                    error.HeadTooLarge => writeError(
                        self.writer,
                        .request_header_fields_too_large,
                        "Request Header Fields Too Large",
                    ),
                    else => std.log.warn("conn_loop: {s}", .{@errorName(err)}),
                }
                break;
            };
            const next_result = result orelse break; // connection closed
            var request = next_result.parsed;
            const http_request = next_result.raw;

            _ = self.stats.active_requests.fetchAdd(1, .monotonic);
            var request_failed = false;
            // keep-alive 决策提前到这里，并传给 processRequest：服务端主动断连
            // （报错 / 优雅关机）时，Response 底层才能写出 `Connection: close`（P1-3），
            // 否则客户端连接池把死连接当可复用 → 下一个请求 ECONNRESET。
            const client_keep_alive = conn_loop.shouldKeepAlive(&request);
            const shutting_down = self.stats.shutting_down.load(.monotonic);
            // P2-38：尊重 HttpConfig.keep_alive_enabled——旧代码从不读这个开关，
            // 运维设 false 以为关了 keep-alive 实际仍在复用连接（虚假的控制感）。
            const response_keep_alive = client_keep_alive and !shutting_down and self.config.http.keep_alive_enabled;
            const hijack = self.processRequest(&request, http_request, &arenas, response_keep_alive) catch |err| blk: {
                std.log.err("processRequest: {s}", .{@errorName(err)});
                request_failed = true;
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

            const keep_alive = client_keep_alive and !shutting_down and self.config.http.keep_alive_enabled;
            arenas.endRequest(self.config.pool.request_arena_retain_bytes);
            // 请求处理报错后不再复用连接：body 是否读净、协议状态是否一致
            // 都不确定，继续 keep-alive 可能错帧（回应审查发现 #7）。
            if (request_failed or !keep_alive) break;
            // 真正的空闲等待发生在下一次 conn_loop.next() 的阻塞读里，
            // 由 reader 的 read_timeout_ns 约束。旧代码在 next() 前采样 idle_start、
            // 在处理完后算差，实际测的是“读+处理”总耗时，既无法在真正空闲时
            // 关连接，又可能因慢请求误关（回应审查发现 #5），故移除。
        }

        self.lifecycle.emit(.connection_close, .{});
    }

    fn processRequest(
        self: *ConnectionRunner,
        request: *http_protocol.Request,
        http_request: *http.Server.Request,
        arenas: *http_app.Arenas,
        keep_alive: bool,
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
            .peer_ip = self.peer_ip,
        };

        var res = http_protocol.Response.init(arena_alloc, http_protocol.Sink.fromHttp(http_request));
        defer res.deinit();
        // keep-alive 决策由 ConnectionRunner 统一下发：为 false 时 std 写
        // `Connection: close`，客户端不会把即将关闭的连接当可复用（P1-3）。
        res.keep_alive = keep_alive;

        // P2-38：尊重 HttpConfig.server_name——旧代码从不发 `Server:` 头，配置项形同虚设。
        // 在 dispatch 前写入，handler / 中间件仍可覆盖。空串视为"不发"。
        // setHeader（去重）而非 header（追加）：若 SecurityHeaders 中间件也配置了
        // `server`，两边同值不应输出两行（bug.md §6）。
        if (self.config.http.server_name.len > 0) {
            _ = try res.setHeader("Server", self.config.http.server_name);
        }

        self.lifecycle.emit(.request_start, .{
            .ctx = &ctx,
            .method = request.method,
            .path = request.path,
        });

        const dispatch_start = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
            // 缓冲模式下（压缩/计时中间件会开启）res.text 只存入 pending_body，
            // 必须 flush 才会真正写出。不在这里 flush 会导致 client 永远收不到响应
            // → 连接死锁到超时（回应审查发现 #2）。
            try res.flush();
            return err;
        };
        const latency = std.Io.Timestamp.now(self.io, .awake).nanoseconds - dispatch_start;

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
            try res.text("");
        }
        try res.flush();
        return null;
    }
};

fn writeError(writer: *std.Io.Writer, status: http.Status, msg: []const u8) void {
    _ = writer.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        @backingInt(status),
        reasonPhrase(status),
        msg.len,
        msg,
    }) catch return;
    // 写入的是带缓冲 writer，必须 flush，否则紧接着的连接关闭会丢弃缓冲
    // 区内容，client 收不到 400 → 挂到超时（回应审查发现 #4）。
    writer.flush() catch {};
}

/// HTTP reason phrase（标准描述短语）。@tagName 会得到 "bad_request" 而非 "Bad Request"。
fn reasonPhrase(status: http.Status) []const u8 {
    return status.phrase() orelse "Error";
}
