//! 应用错误 — 错误是一等公民（回应 bug.md §11）
//!
//! `AppError` 携带 HTTP 状态码和响应体。handler 可以返回业务错误
//! 而不需要手动写响应。错误渲染中间件（管道最后一层）把 AppError 转成
//! 响应，用户可以替换渲染策略。

const std = @import("std");
const http = std.http;
const Response = @import("http_protocol").Response;
const Context = @import("context.zig").Context;
const Handler = @import("handler.zig").Handler;
const Next = @import("middleware.zig").Next;
const Middleware = @import("middleware.zig").Middleware;

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

    /// 机器可读错误码（前端按它分支，而非解析 message）。
    /// 由 status 的 tag 名派生（如 "bad_request"）；Status 是非穷举枚举，
    /// 可能持有无 tag 名的未知值（@enumFromInt 构造），此时格式化为 "status_<n>"。
    /// 不用 @tagName：本工具链对未知值会 safety panic，Release 关安全检查后更是 UB。
    pub fn codeName(self: AppError, buf: []u8) []const u8 {
        inline for (@typeInfo(http.Status).@"enum".field_names) |name| {
            if (self.status == @field(http.Status, name)) return name;
        }
        return std.fmt.bufPrint(buf, "status_{d}", .{@intFromEnum(self.status)}) catch "unknown_status";
    }

    /// 默认渲染：JSON 包络（Issue 4），与成功侧 JSON 响应格式对称，前端拦截器
    /// 不必再按 Content-Type 分支解析纯文本错误体：
    /// `{"ok":false,"error":{"code":"<status tag 名>","message":"..."}}`。
    /// 要换错误体形状，挂 `ErrorRenderer.render` 钩子，不必替换整个中间件。
    pub fn toResponse(self: AppError, res: *Response) !void {
        var code_buf: [24]u8 = undefined;
        _ = res.statusCode(self.status);
        try res.json(.{
            .ok = false,
            .@"error" = .{
                .code = self.codeName(&code_buf),
                .message = self.message,
            },
        });
    }
};

/// 错误渲染中间件 — 管道最后一层，把 AppError 转成 HTTP 响应。
///
/// 默认渲染为 JSON 包络（AppError.toResponse，Issue 4）。应用可通过
/// `render` 钩子替换错误体形状（自定义包络、i18n 等），无需替换整个中间件。
///
/// 用法：
/// ```zig
/// var renderer = ErrorRenderer{};                     // 默认 JSON 包络
/// var renderer = ErrorRenderer{ .render = myRender }; // 自定义渲染
/// router.use(Middleware.init(ErrorRenderer, &renderer));
/// ```
///
/// ErrorRenderer 拦截 handler 返回的错误：
/// - `error.AppError` → 从 ctx.state.user_data 取出 AppError，用其
///   自带的状态码和消息渲染（fix.md §一.3：之前永远渲染 500，丢失细节）
/// - `error.OutOfMemory` → 冒泡（不可恢复）
/// - 其它 → 500 Internal Server Error，记录原始错误名
pub const ErrorRenderer = struct {
    /// 错误渲染钩子（Issue 4）：null → 内置 JSON 包络（defaultRender）。
    pub const RenderFn = *const fn (ctx: *Context, res: *Response, app_err: AppError) anyerror!void;
    render: ?RenderFn = null,

    fn defaultRender(_: *Context, res: *Response, app_err: AppError) !void {
        try app_err.toResponse(res);
    }

    fn renderFn(self: *const ErrorRenderer) RenderFn {
        return self.render orelse defaultRender;
    }

    pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
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
                    self.renderFn()(ctx, res, app_err.*) catch |render_err| {
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
            self.renderFn()(ctx, res, app_err) catch |render_err| {
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

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
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
    const fail_err = ctx.failWith(AppError.unauthorized("bad token"));
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

test "AppError.codeName 由 status tag 名派生，未知值回退 status_<n>" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("bad_request", AppError.badRequest("x").codeName(&buf));
    try std.testing.expectEqualStrings("internal_server_error", AppError.internal("x").codeName(&buf));
    // Status 非穷举：未知值不得触 safety panic（旧实现用 @tagName 会 panic）。
    const odd = AppError{ .status = @enumFromInt(599), .message = "x" };
    try std.testing.expectEqualStrings("status_599", odd.codeName(&buf));
}

test "ErrorRenderer 默认渲染 JSON 包络，render 钩子可覆盖（Issue 4）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/err",
        .path = "/err",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /err HTTP/1.1\r\n\r\n",
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    // handler 通过 failWith 抛出业务错误（与真实链路同路径）。
    const fail_handler = Handler.fromFn(struct {
        fn f(ctx: *Context, _: *Response) !void {
            return ctx.failWith(AppError.unauthorized("login required"));
        }
    }.f);

    // 1) 默认：JSON 包络，含机器可读 code 与 message。
    var buf1: [512]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&buf1);
    var res1 = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&w1));
    defer res1.deinit();
    var ctx1 = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };
    var renderer = ErrorRenderer{};
    try renderer.process(&ctx1, &res1, Next.root(&[_]Middleware{}, fail_handler));
    // ErrorRenderer 置了缓冲模式，真实链路里由外层统一 flush；测试里自己补。
    try res1.flush();
    const written1 = buf1[0..w1.end];
    try std.testing.expect(std.mem.indexOf(u8, written1,
        "{\"ok\":false,\"error\":{\"code\":\"unauthorized\",\"message\":\"login required\"}}") != null);
    // 状态码仍是 401（包络只换 body，不改 status line）。
    try std.testing.expect(std.mem.indexOf(u8, written1, "401") != null);

    // 2) render 钩子覆盖默认实现：这里改回纯文本。
    var buf2: [512]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    var res2 = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&w2));
    defer res2.deinit();
    var ctx2 = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };
    const custom = struct {
        fn render(_: *Context, res: *Response, e: AppError) !void {
            _ = res.statusCode(e.status);
            try res.text(e.message);
        }
    }.render;
    var renderer2 = ErrorRenderer{ .render = custom };
    try renderer2.process(&ctx2, &res2, Next.root(&[_]Middleware{}, fail_handler));
    try res2.flush();
    const written2 = buf2[0..w2.end];
    try std.testing.expect(std.mem.indexOf(u8, written2, "login required") != null);
    // 非 JSON 包络即可（testSink 故意丢弃 headers，不能断言 Content-Type）。
    try std.testing.expect(std.mem.indexOf(u8, written2, "\"ok\"") == null);
}

test {
    std.testing.refAllDecls(@This());
}
