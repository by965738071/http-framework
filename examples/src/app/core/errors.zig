//! 统一业务错误类型。
//!
//! 框架自带的 `framework.AppError`（src/http_app/error.zig）只有
//! `status + message`（默认渲染是 JSON 包络，但 code 只能由状态码派生），
//! 而前后端契约需要稳定的 `code`（机器可读）+ `message`（人可读）+
//! `details`（可选结构化信息），所以业务层自己定义一套，由
//! `middleware/error_json.zig` 统一渲染成 JSON。

const std = @import("std");
const framework = @import("http_framework");

pub const ApiError = struct {
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
    /// 已序列化好的 JSON 片段（对象或数组）。为 null 时响应里不带 details 字段。
    details_json: ?[]const u8 = null,

    pub fn badRequest(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .bad_request, .code = code, .message = message };
    }
    pub fn unauthorized(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .unauthorized, .code = code, .message = message };
    }
    pub fn forbidden(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .forbidden, .code = code, .message = message };
    }
    pub fn notFound(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .not_found, .code = code, .message = message };
    }
    pub fn conflict(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .conflict, .code = code, .message = message };
    }
    pub fn locked(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .locked, .code = code, .message = message };
    }
    pub fn internal(code: []const u8, message: []const u8) ApiError {
        return .{ .status = .internal_server_error, .code = code, .message = message };
    }

    pub fn withDetails(self: ApiError, details_json: ?[]const u8) ApiError {
        return .{ .status = self.status, .code = self.code, .message = self.message, .details_json = details_json };
    }
};

/// 中止当前请求并交出结构化错误。
///
/// 与 `ctx.failWith(AppError)` 同构：把错误体挂到请求 arena 的 user_data 槽，
/// 返回一个专门的 error 值，由挂在组上的 `ErrorJson` 中间件渲染成 JSON。
/// **必须 `try`**，不要 `catch {}` 吞掉（吞掉就没有任何响应）。
pub fn fail(ctx: *framework.Context, err: ApiError) !void {
    const slot = try ctx.arena.create(ApiError);
    slot.* = err;
    try ctx.setUserData(ApiError, slot);
    return error.ApiFailure;
}

/// 错误码常量（前后端契约，改动需同步 API.md）。
pub const codes = struct {
    pub const invalid_json = "INVALID_JSON";
    pub const validation_error = "VALIDATION_ERROR";
    pub const unauthorized = "UNAUTHORIZED";
    pub const session_expired = "SESSION_EXPIRED";
    pub const permission_denied = "PERMISSION_DENIED";
    pub const account_disabled = "ACCOUNT_DISABLED";
    pub const account_locked = "ACCOUNT_LOCKED";
    pub const invalid_credentials = "INVALID_CREDENTIALS";
    pub const not_found = "NOT_FOUND";
    pub const username_taken = "USERNAME_TAKEN";
    pub const email_taken = "EMAIL_TAKEN";
    pub const org_not_found = "ORG_NOT_FOUND";
    pub const org_has_children = "ORG_HAS_CHILDREN";
    pub const org_has_members = "ORG_HAS_MEMBERS";
    pub const org_cycle = "ORG_CYCLE";
    pub const org_code_taken = "ORG_CODE_TAKEN";
    pub const role_not_found = "ROLE_NOT_FOUND";
    pub const role_code_taken = "ROLE_CODE_TAKEN";
    pub const role_in_use = "ROLE_IN_USE";
    pub const role_is_builtin = "ROLE_IS_BUILTIN";
    pub const unknown_permission = "UNKNOWN_PERMISSION";
    pub const illegal_status_transition = "ILLEGAL_STATUS_TRANSITION";
    pub const illegal_approval_transition = "ILLEGAL_APPROVAL_TRANSITION";
    pub const cannot_delete_self = "CANNOT_DELETE_SELF";
    pub const cannot_demote_self = "CANNOT_DEMOTE_SELF";
    pub const weak_password = "WEAK_PASSWORD";
    pub const internal_error = "INTERNAL_ERROR";
};

test "ApiError 工厂函数映射到预期状态码" {
    try std.testing.expectEqual(std.http.Status.bad_request, ApiError.badRequest("X", "m").status);
    try std.testing.expectEqual(std.http.Status.unauthorized, ApiError.unauthorized("X", "m").status);
    try std.testing.expectEqual(std.http.Status.forbidden, ApiError.forbidden("X", "m").status);
    try std.testing.expectEqual(std.http.Status.not_found, ApiError.notFound("X", "m").status);
    try std.testing.expectEqual(std.http.Status.conflict, ApiError.conflict("X", "m").status);
    try std.testing.expectEqual(std.http.Status.locked, ApiError.locked("X", "m").status);
    try std.testing.expectEqual(std.http.Status.internal_server_error, ApiError.internal("X", "m").status);
}

test "ApiError.withDetails 保留状态码与错误码" {
    const e = ApiError.conflict("C", "m").withDetails("{\"n\":1}");
    try std.testing.expectEqual(std.http.Status.conflict, e.status);
    try std.testing.expectEqualStrings("C", e.code);
    try std.testing.expectEqualStrings("{\"n\":1}", e.details_json.?);
}

test {
    std.testing.refAllDecls(@This());
}
