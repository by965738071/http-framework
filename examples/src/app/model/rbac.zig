//! RBAC：角色 + 权限点 + 两张关联表。
//!
//! 权限点是细粒度的字符串（如 `user:create`），角色自由持有若干权限点，
//! 后端**只按权限点鉴权**（不按角色名）。超管角色额外持有通配符 `*`。

const std = @import("std");
const framework = @import("http_framework");

pub const WILDCARD: []const u8 = "*";

pub const RoleRow = struct {
    id: u64 = 0,
    code: []const u8,
    name: []const u8,
    description: []const u8,
    is_builtin: bool = false,
    created_at: u64 = 0,
    updated_at: u64 = 0,
};

pub const PermissionRow = struct {
    id: u64 = 0,
    code: []const u8,
    module: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const UserRoleRow = struct {
    id: u64 = 0,
    user_id: u64,
    role_id: u64,
};

pub const RolePermissionRow = struct {
    id: u64 = 0,
    role_id: u64,
    permission: []const u8,
};

// 角色编码与权限点编码都唯一（理由同 user.Table）。
pub const RoleTable = framework.orm.ModelWith(RoleRow, "roles", .{
    .unique = &.{ &.{"code"} },
});
pub const PermissionTable = framework.orm.ModelWith(PermissionRow, "permissions", .{
    .unique = &.{ &.{"code"} },
});
pub const UserRoleTable = framework.orm.Model(UserRoleRow, "user_roles");
pub const RolePermissionTable = framework.orm.Model(RolePermissionRow, "role_permissions");

pub const RoleStore = RoleTable.Store;
pub const PermissionStore = PermissionTable.Store;
pub const UserRoleStore = UserRoleTable.Store;
pub const RolePermissionStore = RolePermissionTable.Store;

pub const RoleView = struct {
    id: u64,
    code: []const u8,
    name: []const u8,
    description: []const u8,
    is_builtin: bool,
    permissions: []const []const u8,
    user_count: u64 = 0,
    created_at: u64,
    updated_at: u64,
};

pub const PermissionView = struct {
    code: []const u8,
    module: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Permission = struct {
    code: []const u8,
    module: []const u8,
    name: []const u8,
};

/// 权限点清单（seed 的基准，也是权限守卫实例数组的基准）。
pub const ALL_PERMISSIONS: []const Permission = &.{
    .{ .code = "user:view", .module = "user", .name = "查看用户" },
    .{ .code = "user:create", .module = "user", .name = "新建用户" },
    .{ .code = "user:update", .module = "user", .name = "修改用户" },
    .{ .code = "user:delete", .module = "user", .name = "删除用户" },
    .{ .code = "user:reset-password", .module = "user", .name = "重置密码" },
    .{ .code = "user:assign-role", .module = "user", .name = "分配角色" },
    .{ .code = "user:unlock", .module = "user", .name = "解除锁定" },
    .{ .code = "org:view", .module = "org", .name = "查看组织" },
    .{ .code = "org:create", .module = "org", .name = "新建组织" },
    .{ .code = "org:update", .module = "org", .name = "修改组织" },
    .{ .code = "org:delete", .module = "org", .name = "删除组织" },
    .{ .code = "org:move", .module = "org", .name = "移动组织" },
    .{ .code = "role:view", .module = "role", .name = "查看角色" },
    .{ .code = "role:create", .module = "role", .name = "新建角色" },
    .{ .code = "role:update", .module = "role", .name = "修改角色" },
    .{ .code = "role:delete", .module = "role", .name = "删除角色" },
    .{ .code = "role:assign", .module = "role", .name = "配置角色权限" },
    .{ .code = "log:view", .module = "log", .name = "查看审计日志" },
    .{ .code = "log:export", .module = "log", .name = "导出审计日志" },
    .{ .code = "log:purge", .module = "log", .name = "清理审计日志" },
    .{ .code = "approval:view", .module = "approval", .name = "查看审批" },
    .{ .code = "approval:create", .module = "approval", .name = "发起审批" },
    .{ .code = "approval:review", .module = "approval", .name = "审批" },
};

pub fn isKnownPermission(code: []const u8) bool {
    if (std.mem.eql(u8, code, WILDCARD)) return true;
    for (ALL_PERMISSIONS) |p| {
        if (std.mem.eql(u8, p.code, code)) return true;
    }
    return false;
}

/// 权限判定：持有 `*` 即通过；否则必须显式持有该权限点。
pub fn hasPermission(granted: []const []const u8, required: []const u8) bool {
    for (granted) |g| {
        if (std.mem.eql(u8, g, WILDCARD)) return true;
        if (std.mem.eql(u8, g, required)) return true;
    }
    return false;
}

/// 合并去重多个角色的权限点。返回的切片由 `allocator` 拥有。
pub fn mergePermissions(allocator: std.mem.Allocator, batches: []const []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (batches) |batch| {
        for (batch) |p| {
            if (!contains(out.items, p)) try out.append(allocator, p);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn contains(list: []const []const u8, v: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, v)) return true;
    return false;
}

// ── 测试 ────────────────────────────────────────────────────────────────

test "hasPermission 精确匹配" {
    try std.testing.expect(hasPermission(&.{"user:create"}, "user:create"));
    try std.testing.expect(!hasPermission(&.{"user:create"}, "user:delete"));
    try std.testing.expect(!hasPermission(&.{}, "user:create"));
}

test "hasPermission 通配符 * 放行一切" {
    try std.testing.expect(hasPermission(&.{"*"}, "user:create"));
    try std.testing.expect(hasPermission(&.{ "user:view", "*" }, "log:export"));
}

test "hasPermission 大小写敏感且不做前缀匹配" {
    try std.testing.expect(!hasPermission(&.{"USER:CREATE"}, "user:create"));
    try std.testing.expect(!hasPermission(&.{"user:"}, "user:create"));
}

test "mergePermissions 去重" {
    const a = [_][]const u8{ "user:view", "user:create" };
    const b = [_][]const u8{ "user:create", "org:view" };
    const merged = try mergePermissions(std.testing.allocator, &.{ &a, &b });
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("user:view", merged[0]);
    try std.testing.expectEqualStrings("user:create", merged[1]);
    try std.testing.expectEqualStrings("org:view", merged[2]);
}

test "isKnownPermission 认识清单内与通配符" {
    try std.testing.expect(isKnownPermission("user:create"));
    try std.testing.expect(isKnownPermission("*"));
    try std.testing.expect(!isKnownPermission("user:nope"));
}

test "权限清单内无重复编码" {
    for (ALL_PERMISSIONS, 0..) |p, i| {
        for (ALL_PERMISSIONS[(i + 1)..]) |q| {
            try std.testing.expect(!std.mem.eql(u8, p.code, q.code));
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
