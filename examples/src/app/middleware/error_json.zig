//! 统一错误渲染中间件。
//!
//! 必须挂在业务路由组的最外层（组内第一个 `use`），否则 `core.errors.fail`
//! 抛出的 `error.ApiFailure` 会被框架的 `ErrorRenderer` 兜底成 500 纯文本。

const std = @import("std");
const framework = @import("http_framework");
const errors = @import("../core/errors.zig");
const respond = @import("../core/respond.zig");

pub const ErrorJson = struct {
    pub fn process(_: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        next.call(ctx, res) catch |err| {
            // 已经写过响应（handler 自己发了）→ 不再重复渲染
            if (res.sent) return err;
            // OOM 不可恢复，交给上层（ErrorRenderer 会原样冒泡）
            if (err == error.OutOfMemory) return err;

            if (err == error.ApiFailure) {
                if (ctx.getUserData(errors.ApiError)) |e| {
                    try respond.writeError(ctx.arena, res, e.*);
                    return;
                }
            }
            // 框架自己的 AppError（ctx.failWith）也翻成同一套 JSON 结构
            if (err == error.AppError) {
                if (ctx.getUserData(framework.AppError)) |app_err| {
                    try respond.writeError(ctx.arena, res, .{
                        .status = app_err.status,
                        .code = errors.codes.internal_error,
                        .message = app_err.message,
                    });
                    return;
                }
            }
            std.log.err("api error: {s}", .{@errorName(err)});
            try respond.writeError(ctx.arena, res, errors.ApiError.internal(errors.codes.internal_error, "服务器内部错误"));
        };
    }
};
