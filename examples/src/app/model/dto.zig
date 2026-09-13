//! 请求 DTO —— 前后端契约的一部分（字段与 examples/API.md 一一对应）。
//!
//! 约定：
//! - 创建类 DTO：必填字段无默认值；可选项给默认值。
//! - 更新类 DTO：所有字段都是 `?T`，`null` = 不修改该字段（JSON 里传 null 或缺省）。

pub const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
};

pub const CreateUserRequest = struct {
    username: []const u8,
    password: []const u8,
    display_name: []const u8,
    email: []const u8,
    org_id: u64 = 0,
    status: []const u8 = "active",
    role_ids: []u64 = &.{},
};

pub const UpdateUserRequest = struct {
    display_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    org_id: ?u64 = null,
    status: ?[]const u8 = null,
};

pub const ResetPasswordRequest = struct {
    password: []const u8,
};

pub const AssignRolesRequest = struct {
    role_ids: []u64 = &.{},
};

pub const ChangeStatusRequest = struct {
    status: []const u8,
    reason: []const u8 = "",
};

pub const CreateOrgRequest = struct {
    name: []const u8,
    code: []const u8,
    parent_id: u64 = 0,
    leader: []const u8 = "",
    sort_order: u64 = 0,
};

pub const UpdateOrgRequest = struct {
    name: ?[]const u8 = null,
    leader: ?[]const u8 = null,
    sort_order: ?u64 = null,
};

pub const MoveOrgRequest = struct {
    parent_id: u64,
};

pub const CreateRoleRequest = struct {
    code: []const u8,
    name: []const u8,
    description: []const u8 = "",
};

pub const UpdateRoleRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const AssignPermissionsRequest = struct {
    permissions: [][]const u8 = &.{},
};

pub const CreateApprovalRequest = struct {
    target_user_id: u64,
    role_id: u64,
    reason: []const u8 = "",
};

pub const ReviewApprovalRequest = struct {
    action: []const u8,
    comment: []const u8 = "",
};
