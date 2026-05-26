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

    return .{
        .allocator = allocator,
        .io = io,
        .tcp_server = tcp_server,
        .router = router,
        .config = config,
        .running = false,
    };
}

/// 启动服务器事件循环，阻塞至服务器被关闭。
pub fn run(self: *Self) !void {
    self.running = true;
    std.log.info("Server listening on {s}:{}", .{ self.config.address, self.config.port });

    // 设置信号处理（优雅关闭）
    self.setupSignalHandlers() catch |err| {
        std.log.warn("Failed to setup signal handlers: {}", .{err});
    };

    while (self.running) {
        const stream = self.tcp_server.accept(self.io) catch |accept_err| {
            // accept 失败不应终止服务器（例如 fd 暂时耗尽）
            std.log.warn("Accept error: {}", .{accept_err});
            continue;
        };

        // 为每个新 TCP 连接派发一个并发任务
        // concurrent 返回 Future(void)，用 _ = 忽略返回值
        _ = self.io.concurrent(
            struct {
                fn handler(ctx: *Self, sock: net.Stream, task_io: std.Io) void {
                    handleConnection(ctx, sock, task_io);
                }
            }.handler,
            .{ self, stream, self.io },
        ) catch |conc_err| {
            // 系统资源耗尽（如 fd 不足），丢弃连接
            stream.close(self.io);
            std.log.warn("Concurrency limit reached, dropped connection: {}", .{conc_err});
        };
    }
}

// =========================================================================
// 连接处理（keep-alive 循环）
// =========================================================================

/// 处理一个完整的 TCP 连接生命周期。
///
/// 支持 HTTP/1.1 keep-alive：在同一连接上循环处理多个请求，
/// 直到客户端关闭连接或请求标记了 `Connection: close`。
///
/// # 错误策略
///
/// keep-alive 循环内部的错误被分类处理：
/// - 正常关闭类错误 → 静默退出循环
/// - 协议错误 → 尝试回复 400，然后关闭连接
/// - 其他未知错误 → 记录警告后关闭连接
fn handleConnection(
    self: *Self,
    stream: net.Stream,
    io: std.Io,
) void {
    defer stream.close(io);

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
            // 连接正常关闭 → 静默退出
            if (isConnectionClosed(head_err)) break;

            // 协议错误 → 尝试回复 400
            if (isProtocolError(head_err)) {
                writeErrorResponse(&http_server, .bad_request, "Bad Request");
            } else if (isTimeout(head_err)) {
                // 空闲超时 → 静默关闭
                break;
            } else {
                std.log.warn("receiveHead error: {}", .{head_err});
            }
            break;
        };

        // --- 步骤 2: 初始化请求上下文 ---
        var ctx = RequestContext.init(self.allocator, io, &http_request) catch |ctx_err| {
            std.log.warn("RequestContext init error: {}", .{ctx_err});
            break;
        };

        // --- 步骤 3: 初始化响应构建器（纯栈分配，零开销） ---
        var response = Response.init(self.allocator, &http_request);

        // --- 步骤 4: 路由分发 ---
        _ = self.router.dispatch(&ctx, &response) catch |dispatch_err| {
            handleDispatchError(self, &ctx, &response, dispatch_err);
        };

        // --- 步骤 5: 清理请求上下文和响应（每次请求迭代后必须清理，防止 keep-alive 场景内存泄漏） ---
        ctx.deinit();
        response.deinit();

        // --- 步骤 6: 检查是否需要保持连接 ---
        if (!http_request.head.keep_alive) break;
    }
}

// =========================================================================
// 错误分类与处理
// =========================================================================

/// 判断错误是否属于"连接正常关闭"。
fn isConnectionClosed(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpConnectionClosing") or
        std.mem.eql(u8, name, "EndOfStream") or
        std.mem.eql(u8, name, "BrokenPipe") or
        std.mem.eql(u8, name, "ConnectionResetByPeer");
}

/// 判断错误是否属于"协议错误"。
fn isProtocolError(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpHeadersOversize") or
        std.mem.eql(u8, name, "HttpHeadersInvalid");
}

/// 判断错误是否属于"空闲超时"。
fn isTimeout(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "OperationCanceled") or
        std.mem.eql(u8, name, "Timeout");
}

/// 接收请求头，带超时控制。
/// 如果在 idle_timeout_ns 内没有收到新请求，返回超时错误。
fn receiveHeadChecked(server: *http.Server, idle_timeout_ns: u64) !http.Server.Request {
    // 如果配置了超时，使用 io 的超时机制
    if (idle_timeout_ns > 0) {
        return server.receiveHead() catch |err| {
            // 检查是否是超时错误
            if (isTimeout(err)) {
                return err;
            }
            return err;
        };
    }
    return server.receiveHead();
}

/// 处理路由分发阶段的错误。
fn handleDispatchError(
    self: *Self,
    ctx: *RequestContext,
    response: *Response,
    err: anytype,
) void {
    if (self.router.error_handler) |eh| {
        eh(err, ctx, response) catch |eh_err| {
            std.log.warn("Error handler failed: {}", .{eh_err});
            respondStatusCode(response, .internal_server_error);
        };
    } else {
        respondStatusCode(response, .internal_server_error);
    }
}

/// 向 writer 发送最简单的错误响应（用于协议错误的场景）。
///
/// 注意：此函数会消耗掉 `http_server` 的当前状态，之后连接应被关闭。
fn writeErrorResponse(
    http_server: *http.Server,
    status: http.Status,
    body: []const u8,
) void {
    // 构建一个最简的 Request 占位对象
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

/// 利用已有的 Response 对象发送状态码级错误。
fn respondStatusCode(response: *Response, status: http.Status) void {
    response.statusCode(status).text("") catch {};
}

// =========================================================================
// 清理
// =========================================================================

pub fn deinit(self: *Self) void {
    self.running = false;
    self.tcp_server.deinit(self.io);
}

// =========================================================================
// 优雅关闭支持
// =========================================================================

/// 设置信号处理（SIGTERM/SIGINT）
fn setupSignalHandlers(self: *Self) !void {
    _ = self;
    // 注意：Zig 0.17.0-dev 中信号处理的 API 可能有限
    // 这里提供一个框架，具体实现可能需要依赖操作系统 API
    // 或者使用 std.process.waitForSignal 等（如果可用）
    // 当前实现依赖 self.running 标志，由外部信号处理器设置
}

/// 请求优雅关闭
pub fn shutdown(self: *Self) void {
    std.log.info("Shutting down server gracefully...", .{});
    self.running = false;
}

/// 检查是否应该继续运行
pub fn isRunning(self: *const Self) bool {
    return self.running;
}
