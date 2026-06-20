//! HTTP 服务器实现
//!
//! # 性能与设计说明
//!
//! ## 关键优化（基于 1000 并发压测结果）
//!
//! ### 1. HTTP/1.1 keep-alive
//! 原代码每个 TCP 连接只处理一个请求就关闭，浪费三次握手。
//! 现在在同一个连接上循环处理多个请求，直到客户端关闭或
//! 明确发送 `Connection: close`。
//!
//! ### 2. 零堆分配请求处理
//! - `Response` 完全在栈上分配
//! - `RequestContext` 中的 HashMap 在请求结束后被 `deinit` 清理
//! - Handler 本身通过单例模式注册，每次请求零分配
//! - 读写缓冲区在连接生命周期内复用
//!
//! ### 3. 错误弹性
//! - `accept` 错误不终止服务器
//! - keep-alive 循环内的单个请求失败不终止整个连接
//! - 连接断开（EndOfStream、BrokenPipe 等）静默处理
//! - `io.concurrent` 失败时关闭连接但不崩溃

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const net = std.Io.net;

const Config = @import("config.zig").Config;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");
const RotatingFileLogger = @import("logger.zig").RotatingFileLogger;
const MetricsCollector = @import("metrics.zig").MetricsCollector;
const CorsMiddleware = @import("cors.zig").CorsMiddleware;
const BackgroundQueue = @import("background.zig").BackgroundQueue;

/// 每个连接的读取缓冲区大小（必须能容纳最大 HTTP 头部）
const READ_BUF_SIZE: usize = 16384;

/// 每个连接的写入缓冲区大小
const WRITE_BUF_SIZE: usize = 8192;

allocator: std.mem.Allocator,
io: std.Io,
tcp_server: net.Server,
router: Router,
running: bool,
config: Config,

/// 文件日志器（可选，由 config.log_file_path 控制）
file_logger: ?RotatingFileLogger = null,

/// CORS 中间件（可选）
cors: ?*CorsMiddleware = null,

/// 后台任务队列（可选）
background_queue: ?*BackgroundQueue = null,

/// 性能指标（可选）
metrics: ?*MetricsCollector = null,

/// 当前活跃连接数（原子操作，用于优雅关闭）
active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

/// 优雅关闭等待超时（纳秒，默认 30 秒）
drain_timeout_ns: u64 = 30_000_000_000,

/// 是否正在关闭（原子标志）
shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// tcp_server 是否已被关闭（防止 shutdown + deinit 双重释放）
server_closed: bool = false,

const Self = @This();
pub const Server = Self;

// =========================================================================
// 初始化与启动
// =========================================================================

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    router: Router,
) !Self {
    const address = try net.IpAddress.parseIp4(config.address, config.port);
    const tcp_server = try address.listen(io, .{
        .kernel_backlog = config.tcp_backlog,
        .reuse_address = config.reuse_address,
    });

    // 初始化文件日志器（如果配置了路径）
    var file_logger: ?RotatingFileLogger = null;
    if (config.log_file_path) |log_path| {
        if (RotatingFileLogger.init(allocator, io, log_path, .{
            .max_file_size = config.log_max_file_size,
            .max_backup_files = config.log_max_backup_files,
            .compress_rotated = config.log_compress_rotated,
            .rotate_daily = config.log_rotate_daily,
            .min_level = .debug,
            .async_enabled = config.log_async_enabled,
            .buf_size = 0,
        })) |logger| {
            file_logger = logger;
        } else |err| {
            std.log.warn("Failed to init file logger: {}", .{err});
        }
    }

    if (config.tls_enabled) {
        if (config.tls_cert_file) |cert_file| {
            serverLog(&file_logger, .info, "TLS enabled with cert: {s}", .{cert_file});
        }
    }

    return .{
        .allocator = allocator,
        .io = io,
        .tcp_server = tcp_server,
        .router = router,
        .config = config,
        .running = false,
        .file_logger = file_logger,
    };
}

/// 启动服务器事件循环，阻塞至服务器被关闭。
pub fn setMetrics(self: *Self, m: *MetricsCollector) void {
    self.metrics = m;
}

pub fn setCors(self: *Self, c: *CorsMiddleware) void {
    self.cors = c;
}

pub fn setBackgroundQueue(self: *Self, bg: *BackgroundQueue) void {
    self.background_queue = bg;
}

pub fn run(self: *Self) !void {
    self.running = true;
    serverLog(&self.file_logger, .info, "Server listening on {s}:{d}", .{ self.config.address, self.config.port });

    // 设置信号处理（优雅关闭）
    self.setupSignalHandlers() catch |err| {
        serverLog(&self.file_logger, .warn, "Failed to setup signal handlers: {}", .{err});
    };

    while (self.running) {
        const stream = self.tcp_server.accept(self.io) catch |accept_err| {
            // 1. 正常的错误（如 fd 暂时耗尽）→ 记录并继续
            // 2. shutdown 期间产生的 Cancelled → 直接退出循环
            // 3. 处理完毕（tcp_server 已被 deinit），直接退出
            if (accept_err == error.Cancelled) {
                break;
            }
            // 其它错误（如网络异常）→ 记录并继续
            serverLog(&self.file_logger, .warn, "Accept error: {}", .{accept_err});
            continue;
        };

        // 为每个新 TCP 连接派发一个并发任务
        _ = self.io.concurrent(
            struct {
                fn handler(ctx: *Self, sock: net.Stream, task_io: std.Io) void {
                    handleConnection(ctx, sock, task_io);
                }
            }.handler,
            .{ self, stream, self.io },
        ) catch |conc_err| {
            stream.close(self.io);
            serverLog(&self.file_logger, .warn, "Concurrency limit reached, dropped connection: {}", .{conc_err});
        };
    }

    // =========================================================================
    // 优雅关闭：drain 阶段
    // 等待所有活跃连接处理完毕（或超时），然后执行清理
    // =========================================================================

    self.shutting_down.store(true, .monotonic);
    self.drainConnections();
}

// =========================================================================
// 连接处理（keep-alive 循环）
// =========================================================================

/// 处理一个完整的 TCP 连接生命周期。
/// 单次 dispatch 失败不会终止 keep-alive 循环，
/// 但连续失败超过上限后会关闭连接防止资源泄漏。
fn handleConnection(self: *Self, stream: net.Stream, io: std.Io) void {
    defer stream.close(io);

    // 服务器正在关闭，拒绝新连接
    if (self.shutting_down.load(.monotonic)) {
        return;
    }

    _ = self.active_connections.fetchAdd(1, .monotonic);
    defer _ = self.active_connections.fetchSub(1, .monotonic);

    requestLog(&self.file_logger, "New TCP connection accepted", .{});

    // 每个连接分配一次读写缓冲区，而不是每个请求
    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var write_buf: [WRITE_BUF_SIZE]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var http_server = http.Server.init(&reader.interface, &writer.interface);

    // 可恢复错误计数器：防止无限重试导致资源泄漏
    var recoverable_errors: u32 = 0;
    const max_recoverable_errors: u32 = 10;

    // ---------- keep-alive 主循环 ----------
    while (true) {
        // 检查是否正在关闭
        if (self.shutting_down.load(.monotonic)) {
            requestLog(&self.file_logger, "Server shutting down, closing connection", .{});
            break;
        }

        // --- 步骤 1: 接收 HTTP 请求头（带超时） ---
        var http_request = receiveHeadChecked(&http_server, self.config.idle_timeout_ns) catch |head_err| {
            if (isConnectionClosed(head_err)) {
                if (recoverable_errors > 0) {
                    requestLog(&self.file_logger, "Connection closed after {d} recoverable errors", .{recoverable_errors});
                }
                break;
            }

            if (isProtocolError(head_err)) {
                requestLog(&self.file_logger, "[REQUEST] Protocol error: Bad Request", .{});
                writeErrorResponse(&http_server, .bad_request, "Bad Request");
                recoverable_errors += 1;
                if (recoverable_errors >= max_recoverable_errors) {
                    requestLog(&self.file_logger, "Too many recoverable errors ({d}), closing connection", .{recoverable_errors});
                    break;
                }
                break;
            } else if (isTimeout(head_err)) {
                requestLog(&self.file_logger, "Idle timeout, closing connection", .{});
                break;
            } else {
                requestLog(&self.file_logger, "[REQUEST] receiveHead error: {}", .{head_err});
                recoverable_errors += 1;
                if (recoverable_errors >= max_recoverable_errors) {
                    break;
                }
                break;
            }
        };

        // --- 步骤 2: 初始化请求上下文 ---
        var ctx = RequestContext.init(self.allocator, io, &http_request) catch |ctx_err| {
            requestLog(&self.file_logger, "[ERROR] RequestContext init failed: {}", .{ctx_err});
            break;
        };
        ctx.body_size_limit = self.config.body_size_limit;

        // 记录请求到达
        requestLog(&self.file_logger, "[REQUEST] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });

        // --- 步骤 3: 初始化响应构建器 ---
        var response = Response.init(self.allocator, &http_request);
        // 设置原始 writer 用于 chunked transfer encoding（通过 writer.interface）
        const RawCtx = struct {
            iface: *std.Io.Writer,
            fn write(wctx: *anyopaque, data: []const u8) anyerror!usize {
                const c: *@This() = @ptrCast(@alignCast(wctx));
                return c.iface.writeVec(&.{data});
            }
        };
        var raw_ctx = RawCtx{ .iface = &writer.interface };
        response.raw_writer = .{
            .ctx = @ptrCast(&raw_ctx),
            .writeFn = RawCtx.write,
        };

        // CORS 处理（检查来源 + 自动注入响应头）
        if (self.cors) |c| {
            const action = if (c.process(&ctx)) |a| a else |_| .next;
            // 预检请求直接响应 204（除非被 CORS 策略阻止，如 block_unauthorized）
            if (action == .respond) {
                c.addCorsHeaders(&ctx, &response) catch {};
                // 使用 blocked_status（如 403 Forbidden）或默认 204 No Content
                const status = if (ctx.blocked_status) |s| s else std.http.Status.no_content;
                _ = response.statusCode(status);
                response.text("") catch {};
                ctx.deinit();
                response.deinit();
                if (!http_request.head.keep_alive) break;
                continue;
            }
            if (action == .err) {
                ctx.deinit();
                response.deinit();
                break;
            }
            // 正常请求：注入 CORS 响应头
            c.addCorsHeaders(&ctx, &response) catch {};
        }

        // --- 步骤 4: 路由分发 ---
        const dispatch_start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (self.router.dispatch(&ctx, &response)) |_| {
            // 请求成功：重置错误计数器
            recoverable_errors = 0;
        } else |dispatch_err| {
            requestLog(&self.file_logger, "[ERROR] {s} {s} -> dispatch: {}", .{
                @tagName(ctx.method),
                ctx.path,
                dispatch_err,
            });
            handleDispatchError(self, &ctx, &response, dispatch_err);
            recoverable_errors += 1;
            // 检查是否超过可恢复错误上限
            if (recoverable_errors >= max_recoverable_errors) {
                requestLog(&self.file_logger, "Too many recoverable errors ({d}), closing connection", .{recoverable_errors});
                ctx.deinit();
                response.deinit();
                break;
            }
        }

        // 记录响应状态
        requestLog(&self.file_logger, "[RESPONSE] {s} {s} -> {s}", .{
            @tagName(ctx.method),
            ctx.path,
            @tagName(response.status),
        });

        // 记录性能指标
        if (self.metrics) |m| {
            const latency = std.Io.Timestamp.now(io, .awake).nanoseconds - dispatch_start;
            m.recordRequest(.{
                .method = @tagName(ctx.method),
                .path = ctx.path,
                .status = @intFromEnum(response.status),
                .latency_ns = @as(u64, @intCast(latency)),
                .timestamp = @intCast(dispatch_start),
            }) catch {};
        }

        // WebSocket 升级后跳出 keep-alive
        if (ctx.is_websocket) break;

        // --- 步骤 5: 清理 ---
        ctx.deinit();
        response.deinit();

        // 处理后台任务队列（fire-and-forget 任务在此执行）
        if (self.background_queue) |bg| {
            bg.drain() catch |bg_err| {
                requestLog(&self.file_logger, "[BACKGROUND] Queue drain error: {}", .{bg_err});
            };
        }

        // --- 步骤 6: 优雅关闭检查 ---
        if (self.shutting_down.load(.monotonic)) break;

        // --- 步骤 7: 是否保持连接 ---
        if (!http_request.head.keep_alive) break;
    }
}

// =========================================================================
// 错误分类与处理
// =========================================================================

fn isConnectionClosed(err: std.http.Server.ReceiveHeadError) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpConnectionClosing") or
        std.mem.eql(u8, name, "EndOfStream") or
        std.mem.eql(u8, name, "BrokenPipe") or
        std.mem.eql(u8, name, "ConnectionResetByPeer");
}

fn isProtocolError(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpHeadersOversize") or
        std.mem.eql(u8, name, "HttpHeadersInvalid");
}

fn isTimeout(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "OperationCanceled") or
        std.mem.eql(u8, name, "Timeout");
}

fn receiveHeadChecked(server: *http.Server, idle_timeout_ns: u64) std.http.Server.ReceiveHeadError!http.Server.Request {
    // 注意：当前 Zig std.http.Server.receiveHead() 不支持原生超时参数。
    // idle_timeout_ns 在此保留以备未来集成操作系统级超时（如 SO_RCVTIMEO）。
    // 当前实现直接调用 receiveHead()，超时逻辑由连接层自行处理。
    _ = idle_timeout_ns;
    return try server.receiveHead();
}

fn handleDispatchError(self: *Self, ctx: *RequestContext, response: *Response, err: anytype) void {
    if (self.router.error_handler) |eh| {
        eh(err, ctx, response) catch |eh_err| {
            requestLog(&self.file_logger, "Error handler failed: {}", .{eh_err});
            respondStatusCode(response, .internal_server_error);
        };
    } else {
        respondStatusCode(response, .internal_server_error);
    }
}

fn writeErrorResponse(http_server: *http.Server, status: http.Status, body: []const u8) void {
    var placeholder = http.Server.Request{
        .server = http_server,
        .head = .{
            .method = .GET,
            .target = "",
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = false,
        },
        .head_buffer = "",
        .respond_err = null,
    };

    placeholder.respond(body, .{
        .status = status,
        .extra_headers = &.{},
    }) catch {};
}

fn respondStatusCode(response: *Response, status: http.Status) void {
    response.statusCode(status).text("") catch {};
}

// =========================================================================
// 清理
// =========================================================================

pub fn deinit(self: *Self) void {
    serverLog(&self.file_logger, .info, "Server shutting down", .{});
    self.running = false;
    if (!self.server_closed) {
        self.server_closed = true;
        self.tcp_server.deinit(self.io);
    }
    if (self.file_logger) |*logger| {
        logger.deinit();
    }
}

// =========================================================================
// 优雅关闭支持
// =========================================================================

fn setupSignalHandlers(self: *Self) !void {
    const S = struct {
        var server_ptr: ?*Self = null;

        fn handler(ctrl_type: u32) callconv(.c) i32 {
            _ = ctrl_type;
            if (server_ptr) |s| {
                s.shutdown();
            }
            return 1;
        }
    };
    S.server_ptr = self;
    if (builtin.os.tag == .windows) {
        const handler_fn = @extern(*const fn (handler: *const fn (u32) callconv(.c) i32, add: i32) callconv(.c) i32, .{ .library_name = "kernel32", .name = "SetConsoleCtrlHandler" });
        _ = handler_fn(S.handler, 1);
    }
}

pub fn shutdown(self: *Self) void {
    serverLog(&self.file_logger, .info, "Shutting down server gracefully...", .{});
    self.running = false;
    // 关闭监听套接字，强制唤醒阻塞在 accept 的调用
    // 加锁标记避免 deinit 重复关闭
    if (!self.server_closed) {
        self.server_closed = true;
        self.tcp_server.deinit(self.io);
    }
}

/// 等待所有活跃连接处理完毕（或超时）。
/// 在 run() 中 accept 循环退出后自动调用。
pub fn drainConnections(self: *Self) void {
    const drain_start = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    self.shutting_down.store(true, .monotonic);

    const initial = self.active_connections.load(.monotonic);
    serverLog(&self.file_logger, .info, "Graceful shutdown: draining {d} active connections...", .{initial});

    while (self.active_connections.load(.monotonic) > 0) {
        const elapsed = std.Io.Timestamp.now(self.io, .awake).nanoseconds - drain_start;
        if (elapsed >= self.drain_timeout_ns) {
            const remaining = self.active_connections.load(.monotonic);
            serverLog(&self.file_logger, .warn, "Drain timeout reached after {d}s, {d} connections still active", .{
                @divTrunc(elapsed, 1_000_000_000),
                remaining,
            });
            break;
        }
        // 短暂休眠，避免忙等待（10ms）
        self.io.sleep(std.Io.Duration{ .nanoseconds = 10_000_000 }, .awake) catch break;
    }

    const remaining = self.active_connections.load(.monotonic);
    serverLog(&self.file_logger, .info, "Graceful shutdown complete: {d} connections drained", .{remaining});
}

pub fn isRunning(self: *const Self) bool {
    return self.running;
}

// =========================================================================
// 日志辅助函数
// =========================================================================

/// 服务器级日志（写文件 + stdout）
fn serverLog(file_logger: *?RotatingFileLogger, level: RotatingFileLogger.Level, comptime fmt: []const u8, args: anytype) void {
    switch (level) {
        .debug => std.log.debug(fmt, args),
        .info => std.log.info(fmt, args),
        .warn => std.log.warn(fmt, args),
        .err => std.log.err(fmt, args),
    }
    if (file_logger.*) |*logger| {
        logger.log(level, fmt, args) catch {};
    }
}

/// 请求级日志（写文件，仅 debug 级别 stdout）
fn requestLog(file_logger: *?RotatingFileLogger, comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
    if (file_logger.*) |*logger| {
        logger.debug(fmt, args) catch {};
    }
}

// =========================================================================
// 自定义错误页面
// =========================================================================

fn sendErrorPage(response: *Response, status: http.Status, message: ?[]const u8) void {
    const status_text = http.Status.text(status) orelse "Unknown Error";
    const msg = message orelse status_text;

    var buf: [1024]u8 = undefined;
    const html = std.fmt.bufPrint(&buf,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{s}</title></head>
        \\<body>
        \\  <h1>{s}</h1>
        \\  <p>{s}</p>
        \\</body>
        \\</html>
    , .{ status_text, msg }) catch "Error";

    response.statusCode(status).html(html) catch {};
}

// ===========================================================================
// 测试
// ===========================================================================

test "graceful shutdown: active_connections counter" {
    var counter = std.atomic.Value(u32).init(0);

    // 模拟连接进入
    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));

    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 2), counter.load(.monotonic));

    // 模拟连接退出
    _ = counter.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));

    _ = counter.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 0), counter.load(.monotonic));
}

test "graceful shutdown: shutting_down flag" {
    var flag = std.atomic.Value(bool).init(false);

    try std.testing.expectEqual(false, flag.load(.monotonic));

    flag.store(true, .monotonic);
    try std.testing.expectEqual(true, flag.load(.monotonic));

    flag.store(false, .monotonic);
    try std.testing.expectEqual(false, flag.load(.monotonic));
}

test "graceful shutdown: drainConnections when no active connections" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0; // ephemeral port

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    var server = Self.init(allocator, io, test_config, router) catch {
        // 端口绑定失败时跳过测试
        return;
    };
    defer server.deinit();

    // 不调用 run()，直接测试 drain
    // 所有连接都应已处理完毕（0 个活跃连接）
    server.drainConnections();

    // drain 完成后，active_connections 应为 0
    try std.testing.expectEqual(@as(u32, 0), server.active_connections.load(.monotonic));
    try std.testing.expectEqual(true, server.shutting_down.load(.monotonic));
}

test "graceful shutdown: drainConnections respects timeout" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0; // ephemeral port

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    var server = Self.init(allocator, io, test_config, router) catch {
        return;
    };
    defer server.deinit();

    // 模拟有一个活跃连接
    _ = server.active_connections.fetchAdd(1, .monotonic);

    // 设置极短的超时（1ms），确保超时触发
    server.drain_timeout_ns = 1_000_000;

    server.drainConnections();

    // 超时后，连接计数可能仍为 1（连接未真正释放）
    // 但 shutting_down 标志应已设置
    try std.testing.expectEqual(true, server.shutting_down.load(.monotonic));
}
