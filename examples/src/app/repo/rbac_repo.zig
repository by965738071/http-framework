//! RBAC 仓储：角色 / 权限点 / 用户-角色 / 角色-权限。

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const repo_mod = @import("mod.zig");

const Database = repo_mod.Database;
const rbac = model.rbac;

pub const RbacRepository = struct {
    db: *Database,

    // ── 角色 ────────────────────────────────────────────────────

    pub fn findRoleById(self: RbacRepository, alloc: std.mem.Allocator, id: u64) !?rbac.RoleRow {
        return self.db.roles.findById(alloc, id);
    }

    pub fn findRoleByCode(self: RbacRepository, alloc: std.mem.Allocator, code: []const u8) !?rbac.RoleRow {
        return self.db.roles.findBy(alloc, "code", code);
    }

    pub fn allRoles(self: RbacRepository, alloc: std.mem.Allocator) ![]rbac.RoleRow {
        return self.db.roles.all(alloc);
    }

    pub fn insertRole(self: RbacRepository, row: rbac.RoleRow) !u64 {
        const id = try self.db.roles.insert(row);
        try self.db.roles.flush();
        return id;
    }

    pub fn updateRole(self: RbacRepository, row: rbac.RoleRow) !bool {
        const ok = try self.db.roles.updateById(row.id, row);
        if (ok) try self.db.roles.flush();
        return ok;
    }

    pub fn deleteRole(self: RbacRepository, id: u64) !bool {
        const ok = try self.db.roles.deleteById(id);
        if (ok) {
            try self.db.roles.flush();
            try self.deleteRolePermissions(id);
            try self.deleteUserRolesByRole(id);
        }
        return ok;
    }

    pub fn countRoleUsers(self: RbacRepository, role_id: u64) !usize {
        const rows = try self.db.user_roles.all(self.db.allocator);
        defer self.db.user_roles.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| { if (r.role_id == role_id) n += 1; }
        return n;
    }

    // ── 权限点 ──────────────────────────────────────────────────

    pub fn allPermissions(self: RbacRepository, alloc: std.mem.Allocator) ![]rbac.PermissionRow {
        return self.db.permissions.all(alloc);
    }

    pub fn findPermissionByCode(self: RbacRepository, alloc: std.mem.Allocator, code: []const u8) !?rbac.PermissionRow {
        return self.db.permissions.findBy(alloc, "code", code);
    }

    pub fn insertPermission(self: RbacRepository, row: rbac.PermissionRow) !u64 {
        const id = try self.db.permissions.insert(row);
        try self.db.permissions.flush();
        return id;
    }

    pub fn countRoles(self: RbacRepository) !usize {
        const rows = try self.db.roles.all(self.db.allocator);
        defer self.db.roles.freeRows(self.db.allocator, rows);
        return rows.len;
    }

    pub fn countPermissions(self: RbacRepository) !usize {
        const rows = try self.db.permissions.all(self.db.allocator);
        defer self.db.permissions.freeRows(self.db.allocator, rows);
        return rows.len;
    }

    // ── 角色-权限 ────────────────────────────────────────────────

    /// 某角色持有的权限点编码列表（按插入顺序）。
    pub fn permissionsOfRole(self: RbacRepository, alloc: std.mem.Allocator, role_id: u64) ![]const []const u8 {
        const rows = try self.db.role_permissions.all(alloc);
        var out = std.ArrayList([]const u8).empty;
        for (rows) |r| {
            if (r.role_id == role_id) try out.append(alloc, try alloc.dupe(u8, r.permission));
        }
        return out.toOwnedSlice(alloc);
    }

    /// 全量替换某角色的权限点（先删后插）。ORM 没有事务，两步之间没有原子性。
    pub fn setRolePermissions(self: RbacRepository, role_id: u64, permissions: []const []const u8) !void {
        try self.deleteRolePermissions(role_id);
        for (permissions) |p| {
            _ = try self.db.role_permissions.insert(.{ .role_id = role_id, .permission = p });
        }
        try self.db.role_permissions.flush();
    }

    fn deleteRolePermissions(self: RbacRepository, role_id: u64) !void {
        var query = framework.orm.Query(rbac.RolePermissionRow).init(self.db.allocator);
        defer query.deinit();
        _ = query.where(.Eq, "role_id", .{ .integer = @intCast(role_id) }).delete();
        _ = try self.db.role_permissions.delete(&query);
        try self.db.role_permissions.flush();
    }

    // ── 用户-角色 ────────────────────────────────────────────────

    pub fn roleIdsOfUser(self: RbacRepository, alloc: std.mem.Allocator, user_id: u64) ![]u64 {
        const rows = try self.db.user_roles.all(alloc);
        var out = std.ArrayList(u64).empty;
        for (rows) |r| if (r.user_id == user_id) try out.append(alloc, r.role_id);
        return out.toOwnedSlice(alloc);
    }

    /// 全量替换某用户的角色。
    pub fn setUserRoles(self: RbacRepository, user_id: u64, role_ids: []const u64) !void {
        try self.deleteUserRolesByUser(user_id);
        for (role_ids) |rid| {
            _ = try self.db.user_roles.insert(.{ .user_id = user_id, .role_id = rid });
        }
        try self.db.user_roles.flush();
    }

    fn deleteUserRolesByUser(self: RbacRepository, user_id: u64) !void {
        var query = framework.orm.Query(rbac.UserRoleRow).init(self.db.allocator);
        defer query.deinit();
        _ = query.where(.Eq, "user_id", .{ .integer = @intCast(user_id) }).delete();
        _ = try self.db.user_roles.delete(&query);
        try self.db.user_roles.flush();
    }

    fn deleteUserRolesByRole(self: RbacRepository, role_id: u64) !void {
        var query = framework.orm.Query(rbac.UserRoleRow).init(self.db.allocator);
        defer query.deinit();
        _ = query.where(.Eq, "role_id", .{ .integer = @intCast(role_id) }).delete();
        _ = try self.db.user_roles.delete(&query);
        try self.db.user_roles.flush();
    }

    /// 用户通过所有角色合并得到的权限点（去重）。
    pub fn permissionsOfUser(self: RbacRepository, alloc: std.mem.Allocator, user_id: u64) ![]const []const u8 {
        const role_ids = try self.roleIdsOfUser(alloc, user_id);
        const batches = try alloc.alloc([]const []const u8, role_ids.len);
        for (role_ids, 0..) |rid, i| {
            batches[i] = try self.permissionsOfRole(alloc, rid);
        }
        return rbac.mergePermissions(alloc, batches);
    }
};
