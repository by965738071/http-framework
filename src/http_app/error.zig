//! 应用错误 — 错误是一等公民（回应 bug.md §11）
//!
//! `AppError` 携带 HTTP 状态码和响应体。handler 可以返回业务错误
//! 而不需要手动写响应。错误渲染中间件（管道最后一层）把 AppError 转成
//! 响应，用户可以替换渲染策略。

const std = @import("std");
const http = std.http;
const Response = @import("http_protocol").Response;
const Context = @import("context.zig").Context;
const Next = @import("middleware.zig").Next;

pub const AppError = struct {
    status: http.Status,
    message: []const u8,
    cause: ?anyerror = null,

    pub fn notFound(msg: []const u8) AppError {
        return .{ .status = .not_found, .message = msg };
    }

    pub fn badRequest(msg: []const u8) AppError {
        return .{ .status = .bad_request, .message = msg };
    }

    pub fn unauthorized(msg: []const u8) AppError {
        return .{ .status = .unauthorized, .message = msg };
    }

    pub fn forbidden(msg: []const u8) AppError {
        return .{ .status = .forbidden, .message = msg };
    }

    pub fn conflict(msg: []const u8) AppError {
        return .{ .status = .conflict, .message = msg };
    }

    pub fn payloadTooLarge(msg: []const u8) AppError {
        return .{ .status = .payload_too_large, .message = msg };
    }

    pub fn tooManyRequests(msg: []const u8) AppError {
        return .{ .status = .too_many_requests, .message = msg };
    }

    pub fn internal(msg: []const u8) AppError {
        return .{ .status = .internal_server_error, .message = msg };
    }

    pub fn notImplemented(msg: []const u8) AppError {
        return .{ .status = .not_implemented, .message = msg };
    }

    pub fn toResponse(self: AppError, res: *Response) !void {
        _ = res.statusCode(self.status);
        try res.text(self.message);
    }
};

/// 错误渲染中间件 — 管道最后一层，把 AppError 转成 HTTP 响应。
///
/// 用法：
/// ```zig
/// var renderer = ErrorRenderer{};
/// router.use(Middleware.init(ErrorRenderer, &renderer));
/// ```
///
/// ErrorRenderer 拦截 handler 返回的错误：
/// - `error.AppError` → 从 ctx.state.user_data 取出 AppError，用其
///   自带的状态码和消息渲染（fix.md §一.3：之前永远渲染 500，丢失细节）
/// - `error.OutOfMemory` → 冒泡（不可恢复）
/// - 其它 → 500 Internal Server Error，记录原始错误名
pub const ErrorRenderer = struct {
    pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
        _ = self;
        next.call(ctx, res) catch |err| {
            // 框架错误直接冒泡（OOM 等）
            if (err == error.OutOfMemory) return err;

            // 如果响应已经发送（handler 自己处理了错误），不重复发
            if (res.sent) return;

            // 启用缓冲模式，确保 toResponse 写入 pending 而非直接发送
            res.setBuffered();

            // 业务错误：从 ctx.state 取出 handler 通过 failWith 存入的 AppError
            if (err == error.AppError) {
                if (ctx.state.getUserData(AppError)) |app_err| {
                    app_err.toResponse(res) catch |render_err| {
                        std.log.err("ErrorRenderer failed to render AppError: {s}", .{@errorName(render_err)});
                        return render_err;
                    };
                    return;
                }
                // 找不到 AppError 实例——降级为 500
                std.log.warn("error.AppError propagated but no AppError in ctx.state", .{});
            }

            // 未知错误：500 + 原始错误名（便于排查）
            std.log.err("unhandled error in pipeline: {s}", .{@errorName(err)});
            const app_err = AppError.internal("Internal Server Error");
            app_err.toResponse(res) catch |render_err| {
                std.log.err("ErrorRenderer failed to render fallback: {s}", .{@errorName(render_err)});
                return render_err;
            };
        };
    }
};

test "ErrorRenderer extracts AppError from ctx.state (fix.md §一.3)" {
    // 验证 failWith 把 AppError 存进 ctx.state.user_data 并返回 error.AppError
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    // 调 failWith：应返回 error.AppError 并把 AppError 存进 ctx.state
    const fail_err = ctx.failWith(&res, AppError.unauthorized("bad token"));
    try std.testing.expectError(error.AppError, fail_err);
    const stored = ctx.state.getUserData(AppError);
    try std.testing.expect(stored != null);
    try std.testing.expectEqual(std.http.Status.unauthorized, stored.?.status);
    try std.testing.expectEqualStrings("bad token", stored.?.message);
}

test "AppError factories produce correct status codes" {
    try std.testing.expectEqual(http.Status.not_found, AppError.notFound("x").status);
    try std.testing.expectEqual(http.Status.bad_request, AppError.badRequest("x").status);
    try std.testing.expectEqual(http.Status.unauthorized, AppError.unauthorized("x").status);
    try std.testing.expectEqual(http.Status.forbidden, AppError.forbidden("x").status);
    try std.testing.expectEqual(http.Status.conflict, AppError.conflict("x").status);
    try std.testing.expectEqual(http.Status.payload_too_large, AppError.payloadTooLarge("x").status);
    try std.testing.expectEqual(http.Status.too_many_requests, AppError.tooManyRequests("x").status);
    try std.testing.expectEqual(http.Status.internal_server_error, AppError.internal("x").status);
    try std.testing.expectEqual(http.Status.not_implemented, AppError.notImplemented("x").status);
}

test{
    std.testing.refAllDecls(@This());
}