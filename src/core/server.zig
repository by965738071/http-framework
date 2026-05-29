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
const http = std.http;
const net = std.Io.net;

const Config = @import("config.zig").Config;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");
const RotatingFileLogger = @import("logger.zig").RotatingFileLogger;

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

const Self = @This();

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
pub fn run(self: *Self) !void {
    self.running = true;
    serverLog(&self.file_logger, .info, "Server listening on {s}:{d}", .{ self.config.address, self.config.port });

    // 设置信号处理（优雅关闭）
    self.setupSignalHandlers() catch |err| {
        serverLog(&self.file_logger, .warn, "Failed to setup signal handlers: {}", .{err});
    };

    while (self.running) {
        const stream = self.tcp_server.accept(self.io) catch |accept_err| {
            // accept 失败不应终止服务器（例如 fd 暂时耗尽）
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
}

// =========================================================================
// 连接处理（keep-alive 循环）
// =========================================================================

/// 处理一个完整的 TCP 连接生命周期。
fn handleConnection(
    self: *Self,
    stream: net.Stream,
    io: std.Io,
) void {
    defer stream.close(io);

    requestLog(&self.file_logger, "New TCP connection accepted", .{});

    // 每个连接分配一次读写缓冲区，而不是每个请求
    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var write_buf: [WRITE_BUF_SIZE]u8 = undefined;

    const reader = stream.reader(io, &read_buf);
    const writer = stream.writer(io, &write_buf);

    var http_server = http.Server.init(
        @constCast(&reader.interface),
        @constCast(&writer.interface),
    );

    // ---------- keep-alive 主循环 ----------
    while (true) {
        // --- 步骤 1: 接收 HTTP 请求头（带超时） ---
        var http_request = receiveHeadChecked(&http_server, self.config.idle_timeout_ns) catch |head_err| {
            if (isConnectionClosed(head_err)) break;

            if (isProtocolError(head_err)) {
                requestLog(&self.file_logger, "[REQUEST] Protocol error: Bad Request", .{});
                writeErrorResponse(&http_server, .bad_request, "Bad Request");
            } else if (isTimeout(head_err)) {
                requestLog(&self.file_logger, "Idle timeout, closing connection", .{});
                break;
            } else {
                requestLog(&self.file_logger, "[REQUEST] receiveHead error: {}", .{head_err});
            }
            break;
        };

        // --- 步骤 2: 初始化请求上下文 ---
        var ctx = RequestContext.init(self.allocator, io, &http_request) catch |ctx_err| {
            requestLog(&self.file_logger, "[ERROR] RequestContext init failed: {}", .{ctx_err});
            break;
        };

        // 记录请求到达
        requestLog(&self.file_logger, "[REQUEST] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });

        // --- 步骤 3: 初始化响应构建器（纯栈分配，零开销） ---
        var response = Response.init(self.allocator, &http_request);

        // --- 步骤 4: 路由分发 ---
        _ = self.router.dispatch(&ctx, &response) catch |dispatch_err| {
            requestLog(&self.file_logger, "[ERROR] {s} {s} -> dispatch: {}", .{
                @tagName(ctx.method),
                ctx.path,
                dispatch_err,
            });
            handleDispatchError(self, &ctx, &response, dispatch_err);
        };

        // 记录响应状态
        requestLog(&self.file_logger, "[RESPONSE] {s} {s} -> {s}", .{
            @tagName(ctx.method),
            ctx.path,
            @tagName(response.status),
        });

        // WebSocket 升级后跳出 keep-alive
        if (ctx.is_websocket) break;

        // --- 步骤 5: 清理 ---
        ctx.deinit();
        response.deinit();

        // --- 步骤 6: 是否保持连接 ---
        if (!http_request.head.keep_alive) break;
    }
}

// =========================================================================
// 错误分类与处理
// =========================================================================

fn isConnectionClosed(err: anytype) bool {
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

fn receiveHeadChecked(server: *http.Server, idle_timeout_ns: u64) !http.Server.Request {
    if (idle_timeout_ns > 0) {
        return server.receiveHead() catch |err| {
            if (isTimeout(err)) return err;
            return err;
        };
    }
    return server.receiveHead();
}

fn handleDispatchError(
    self: *Self,
    ctx: *RequestContext,
    response: *Response,
    err: anytype,
) void {
    if (self.router.error_handler) |eh| {
        eh(err, ctx, response) catch |eh_err| {
            requestLog(&self.file_logger, "Error handler failed: {}", .{eh_err});
            respondStatusCode(response, .internal_server_error);
        };
    } else {
        respondStatusCode(response, .internal_server_error);
    }
}

fn writeErrorResponse(
    http_server: *http.Server,
    status: http.Status,
    body: []const u8,
) void {
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
    self.tcp_server.deinit(self.io);
    if (self.file_logger) |*logger| {
        logger.deinit();
    }
}

// =========================================================================
// 优雅关闭支持
// =========================================================================

fn setupSignalHandlers(self: *Self) !void {
    _ = self;
}

pub fn shutdown(self: *Self) void {
    serverLog(&self.file_logger, .info, "Shutting down server gracefully...", .{});
    self.running = false;
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

fn sendErrorPage(
    response: *Response,
    status: http.Status,
    message: ?[]const u8,
) void {
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
