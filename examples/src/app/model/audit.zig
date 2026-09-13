//! 审计日志：谁 / 何时 / 哪个模块 / 做了什么 / 结果 + 字段级 diff。

const std = @import("std");
const framework = @import("http_framework");

pub const Result = enum { success, failure };

pub fn parseResult(s: []const u8) ?Result {
    return std.meta.stringToEnum(Result, s);
}

pub const Row = struct {
    id: u64 = 0,
    actor_id: u64 = 0,
    actor_name: []const u8,
    module: []const u8,
    action: []const u8,
    target_type: []const u8,
    target_id: u64 = 0,
    target_label: []const u8,
    result: []const u8,
    message: []const u8,
    /// 字段级 diff 的 JSON 文本（core/diff.zig 产出），无变更时为 "[]"
    changes: []const u8,
    ip: []const u8,
    request_id: []const u8,
    created_at: u64 = 0,
};

pub const Table = framework.orm.Model(Row, "audit_logs");
pub const Store = Table.Store;

pub const View = struct {
    id: u64,
    actor_id: u64,
    actor_name: []const u8,
    module: []const u8,
    action: []const u8,
    target_type: []const u8,
    target_id: u64,
    target_label: []const u8,
    result: []const u8,
    message: []const u8,
    changes: []const u8,
    ip: []const u8,
    created_at: u64,
};

/// 审计动作常量（前后端契约）。
pub const actions = struct {
    pub const login_success = "login.success";
    pub const login_failure = "login.failure";
    pub const login_locked = "login.locked";
    pub const logout = "logout";
    pub const user_create = "user.create";
    pub const user_update = "user.update";
    pub const user_delete = "user.delete";
    pub const user_status_change = "user.status.change";
    pub const user_reset_password = "user.reset_password";
    pub const user_assign_roles = "user.assign_roles";
    pub const org_create = "org.create";
    pub const org_update = "org.update";
    pub const org_delete = "org.delete";
    pub const org_move = "org.move";
    pub const role_create = "role.create";
    pub const role_update = "role.update";
    pub const role_delete = "role.delete";
    pub const role_assign_permissions = "role.assign_permissions";
    pub const approval_create = "approval.create";
    pub const approval_review = "approval.review";
};

test "parseResult 解析成功/失败" {
    try std.testing.expectEqual(Result.success, parseResult("success").?);
    try std.testing.expectEqual(Result.failure, parseResult("failure").?);
    try std.testing.expect(parseResult("maybe") == null);
}

test {
    std.testing.refAllDecls(@This());
}
