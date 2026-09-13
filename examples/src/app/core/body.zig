//! 请求体解析（统一 JSON 错误处理）。

const std = @import("std");
const framework = @import("http_framework");
const errors = @import("errors.zig");

/// 读取并解析 JSON 请求体。必须传 `ctx.arena`。
/// 解析失败统一回 `INVALID_JSON`（不是 500），body 过大回 413 并关连接。
pub fn json(
    comptime T: type,
    ctx: *framework.Context,
    res: *framework.Response,
) !T {
    const body = ctx.readBody(ctx.arena, 1024 * 1024) catch |err| {
        if (err == error.BodyTooLarge) {
            res.keep_alive = false;
            try errors.fail(ctx, errors.ApiError.badRequest(errors.codes.invalid_json, "请求体过大"));
        }
        return err;
    };
    if (body.len == 0) {
        try errors.fail(ctx, errors.ApiError.badRequest(errors.codes.invalid_json, "请求体不能为空"));
        return error.Unreachable;
    }
    const parsed = framework.parseJson(T, ctx.arena, body) catch {
        try errors.fail(ctx, errors.ApiError.badRequest(errors.codes.invalid_json, "JSON 解析失败"));
        return error.Unreachable;
    };
    return parsed.*;
}
