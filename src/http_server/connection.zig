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
        var conn_loop = http_protocol.ConnectionLoop.init(&http_server, &arenas.request);

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
                    // 静默名单与 http_protocol/conn_loop.zig 的 classifyHeadError
                    // 保持同口径（唯一权威来源）：那里把 `ReadFailed` 归为
                    // connection_closed —— "传输层错误或读超时，对端多半已经走了"。
                    // 劫持回调跑在同一条连接上，客户端粗暴断开时它读到的必然也是
                    // ReadFailed；两边口径不一致只会刷出毫无信息量的 noise。
                    //
                    // 为什么不加一套日志分级/ faucet 而是直接对齐静默名单：
                    // 这条路径上没有"部分失败"可言——回调返回后连接立即结束，
                    // 区分 warn/debug 的唯一用途是给人看，而这个事件既不可操作
                    // 也不代表框架出错。等真出现"需要区分对端主动断开与超时"的
                    // 运维需求，正确做法是给整个连接层统一分级，而不是在这里
                    // 单独开一个口子。
                    if (!isConnectionGone(err)) {
                        std.log.warn("hijack: {s}", .{@errorName(err)});
                    }
                };
                break;
            }

            // response_keep_alive 与旧的 keep_alive 是两个逐字相同的表达式（同一
            // shutting_down 快照），合并消除「看起来像两个决策」的误导。
            arenas.endRequest(self.config.pool.request_arena_retain_bytes);
            // 请求处理报错后不再复用连接：body 是否读净、协议状态是否一致
            // 都不确定，继续 keep-alive 可能错帧（回应审查发现 #7）。
            if (request_failed or !response_keep_alive) break;
            // 真正的空闲等待发生在下一次 conn_loop.next() 的阻塞读里，
            // 由 reader 的 read_timeout_ns 约束。旧代码在 next() 前采样 idle_start、
            // 在处理完后算差，实际测的是“读+处理”总耗时，既无法在真正空闲时
            // 关连接，又可能因慢请求误关（回应审查发现 #5），故移除。
        }

        self.lifecycle.emit(.connection_close, .{});
    }

    /// 处理单个请求：建 Context / Response → dispatch → 发响应 → 返回劫持钩子。
    ///
    /// 为什么是 `pub`：`run()` 是完整的 keep-alive 循环，测试要覆盖它就得喂真实
    /// 字节并接受 EOF 收尾；而"这一个请求到底回了几字节"才是绝大多数回归点所在。
    /// 把单请求处理暴露成接缝后，测试可以只驱动它（见 integration_test.zig），
    /// 不必为了测兜底逻辑去复刻一遍 run() 的错误处理。
    pub fn processRequest(
        self: *ConnectionRunner,
        request: *http_protocol.Request,
        http_request: *http.Server.Request,
        arenas: *http_app.Arenas,
        keep_alive: bool,
    ) !?http_app.Hijack {
        const arena_alloc = arenas.requestAllocator();

        var state = http_app.RequestState{ .arena = arena_alloc };
        defer state.deinit();

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
            // 兜底：若无 ErrorRenderer（或其未能写响应），handler 抛错后 response 仍未发送。
            // 若 handler 通过 failWith 存入了 AppError，用其状态码渲染（避免
            // 静默 500 丢失业务错误细节）；否则回 500，避免 client 挂到超时。
            // 413（body_too_large）后强制关连接，防请求走私。
            if (state.body_too_large) res.keep_alive = false;
            if (!res.sent) {
                renderAppErrorOr500(&res, ctx.state.getUserData(http_app.AppError));
            }
            // 缓冲模式下（压缩/计时中间件会开启）res.text 只存入 pending_body，
            // 必须 flush 才会真正写出。不在这里 flush 会导致 client 永远收不到响应
            // → 连接死锁到超时（回应审查发现 #2）。
            // 尽力而为：flush 自身失败（连接已死等）不得顶替原始 handler 错误——
            // 否则 run() 记录的是 flush 的错误名，真实病因被掩蔽。
            res.flush() catch |flush_err| std.log.warn(
                "flush after dispatch error failed: {s}",
                .{@errorName(flush_err)},
            );
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

        // 兜底：handler 若只设了 status 而从未写 body（典型：204 No Content），
        // 补发一个空响应，避免 client 挂到超时。旧条件带 !res.buffered（R2）：
        // 缓冲模式（Timing/Compress 中间件会开）下 flush() 对 !sent 是 no-op，
        // 于是「只设 status + 缓冲模式」的响应一个字节都写不出去。
        // text("") 在缓冲模式只存 pending_body，由下面的 flush() 统一写出。
        //
        // 若 handler 通过 failWith 存入了 AppError 但错误被吞（catch {} return），
        // res.sent 仍为 false——用 AppError 的状态码渲染，避免静默 200 空 body。
        // 413（body_too_large）后强制关连接，防请求走私。
        if (state.body_too_large) res.keep_alive = false;
        if (!res.sent) {
            if (ctx.state.getUserData(http_app.AppError)) |app_err| {
                // 与错误路径同口径（见 renderAppErrorOr500）：渲染失败必须退回
                // 500。旧代码这里是 `catch {}`，于是渲染一失败就留下一个
                // 没有任何响应体的连接——客户端只能挂到超时，而服务端日志
                // 里什么都没有。
                renderAppErrorOr500(&res, app_err);
            } else {
                try res.text("");
            }
        }
        try res.flush();
        return null;
    }
};

/// 兜底渲染：有 AppError 就按它的状态码渲染，渲染失败（典型是 OOM 导致
/// `res.text` 分配不出 Content-Type 头）则退回 500；没有 AppError 则直接 500。
///
/// 成功路径与错误路径共用它，是因为这两处的语义本来就相同——同一个 AppError
/// 不应该因为"handler 有没有把错误抛上来"而得到不同的响应。分成两份写已经
/// 漂过一次（成功路径静默吞掉，错误路径退 500）。
///
/// 注意 `res.text` 失败也要先置 500：`status` 是 lifecycle / 访问日志唯一
/// 拿得到的东西，body 没了至少状态码不能撒谎。
fn renderAppErrorOr500(res: *http_protocol.Response, app_err: ?*const http_app.AppError) void {
    if (app_err) |e| {
        e.toResponse(res) catch {
            _ = res.statusCode(.internal_server_error);
            res.text("Internal Server Error") catch {};
        };
        return;
    }
    _ = res.statusCode(.internal_server_error);
    res.text("Internal Server Error") catch {};
}

/// 连接已经没了，不值得告警。
///
/// 名单与 `http_protocol/conn_loop.zig` 的 `classifyHeadError` 的
/// `connection_closed` 分支对齐——那是唯一权威来源（注释：`ReadFailed` =
/// "传输层错误或读超时，对端多半已经走了"）。劫持回调跑在同一条连接上，
/// 客户端粗暴断开时它读到的必然也是 ReadFailed；两边口径不一致只会刷出
/// 毫无信息量的 noise。
fn isConnectionGone(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed, error.EndOfStream, error.Canceled, error.ReadFailed => true,
        else => false,
    };
}

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

// ===========================================================================
// Tests
// ===========================================================================

test "renderAppErrorOr500：AppError 渲染失败时退回 500（成功路径兜底回归）" {
    // 成功路径（handler 吞掉 failWith 的错误）以前写的是 `catch {}`：渲染一失败
    // 就留下一个没有响应体的连接，客户端挂到超时，服务端日志什么都没有。
    // 用 failing_allocator 让 res.text 在写 Content-Type 头时分配失败——这是
    // toResponse 唯一可控的失败点。
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = http_protocol.Response.init(
        std.testing.failing_allocator,
        http_protocol.Sink.testSink(&writer),
    );
    defer res.deinit();

    const app_err = http_app.AppError.notFound("resource gone");
    renderAppErrorOr500(&res, &app_err);

    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
}

test "renderAppErrorOr500：正常渲染用 AppError 自己的状态码，不是一律 500" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = http_protocol.Response.init(
        std.testing.allocator,
        http_protocol.Sink.testSink(&writer),
    );
    defer res.deinit();

    const app_err = http_app.AppError.notFound("resource gone");
    renderAppErrorOr500(&res, &app_err);

    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "resource gone") != null);
}

test "renderAppErrorOr500：无 AppError 时直接 500" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = http_protocol.Response.init(
        std.testing.allocator,
        http_protocol.Sink.testSink(&writer),
    );
    defer res.deinit();

    renderAppErrorOr500(&res, null);

    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "Internal Server Error") != null);
}

test "isConnectionGone 与 conn_loop.classifyHeadError 同口径（ReadFailed 静默）" {
    // ReadFailed 被 conn_loop 归为 connection_closed（传输层错误/读超时），
    // 劫持回调读到它时同样不该告警。
    try std.testing.expect(isConnectionGone(error.ReadFailed));
    try std.testing.expect(isConnectionGone(error.ConnectionClosed));
    try std.testing.expect(isConnectionGone(error.EndOfStream));
    try std.testing.expect(isConnectionGone(error.Canceled));
    // 真正的异常仍然要打出来
    try std.testing.expect(!isConnectionGone(error.OutOfMemory));
    try std.testing.expect(!isConnectionGone(error.WriteFailed));
}
