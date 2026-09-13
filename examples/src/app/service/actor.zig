//! 当前登录主体（Actor）——由鉴权中间件解析后挂到 ctx user_data 槽。
//!
//! 所有鉴权判断都基于 `permissions`（细粒度权限点），**不基于角色名**。

const std = @import("std");
const rbac = @import("../model/rbac.zig");

pub const Actor = struct {
    id: u64,
    username: []const u8,
    display_name: []const u8,
    org_id: u64,
    status: []const u8,
    permissions: []const []const u8,

    pub fn can(self: Actor, permission: []const u8) bool {
        return rbac.hasPermission(self.permissions, permission);
    }

    /// 全部满足才通过（用于一次操作需要多个权限点的场景）。
    pub fn canAll(self: Actor, permissions: []const []const u8) bool {
        for (permissions) |p| {
            if (!self.can(p)) return false;
        }
        return true;
    }

    pub fn canAny(self: Actor, permissions: []const []const u8) bool {
        for (permissions) |p| {
            if (self.can(p)) return true;
        }
        return false;
    }

    pub fn isSuperAdmin(self: Actor) bool {
        return self.can("*");
    }
};

test "Actor.can 走权限点判定" {
    const a = Actor{
        .id = 1,
        .username = "u",
        .display_name = "U",
        .org_id = 1,
        .status = "active",
        .permissions = &.{"user:create"},
    };
    try std.testing.expect(a.can("user:create"));
    try std.testing.expect(!a.can("user:delete"));
    try std.testing.expect(!a.isSuperAdmin());

    const sa = Actor{ .id = 1, .username = "s", .display_name = "S", .org_id = 1, .status = "active", .permissions = &.{"*"} };
    try std.testing.expect(sa.can("anything"));
    try std.testing.expect(sa.isSuperAdmin());
}

test "Actor.canAll / canAny" {
    const a = Actor{
        .id = 1,
        .username = "u",
        .display_name = "U",
        .org_id = 1,
        .status = "active",
        .permissions = &.{ "user:create", "user:update" },
    };
    try std.testing.expect(a.canAll(&.{ "user:create", "user:update" }));
    try std.testing.expect(!a.canAll(&.{ "user:create", "user:delete" }));
    try std.testing.expect(a.canAny(&.{ "user:delete", "user:update" }));
    try std.testing.expect(!a.canAny(&.{ "org:delete", "org:move" }));
}

test {
    std.testing.refAllDecls(@This());
}
