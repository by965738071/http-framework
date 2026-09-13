//! RBAC 服务：角色 CRUD、权限点分配、权限清单。
//!
//! 鉴权一律基于权限点（如 `user:create`），角色只是权限点的集合。

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");
const audit_service = @import("audit_service.zig");
const actor_mod = @import("actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const rbac = model.rbac;
const errors = core.errors;
const codes = core.errors.codes;

pub fn toRoleView(svc: *AppServices, alloc: std.mem.Allocator, row: rbac.RoleRow) !rbac.RoleView {
    return .{
        .id = row.id,
        .code = try alloc.dupe(u8, row.code),
        .name = try alloc.dupe(u8, row.name),
        .description = try alloc.dupe(u8, row.description),
        .is_builtin = row.is_builtin,
        .permissions = try svc.rbac.permissionsOfRole(alloc, row.id),
        .user_count = try svc.rbac.countRoleUsers(row.id),
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

pub fn listRoles(svc: *AppServices, alloc: std.mem.Allocator) ![]rbac.RoleView {
    const rows = try svc.rbac.allRoles(alloc);
    const views = try alloc.alloc(rbac.RoleView, rows.len);
    for (rows, 0..) |r, i| {
        views[i] = try toRoleView(svc, alloc, r);
    }
    return views;
}

pub fn listPermissions(svc: *AppServices, alloc: std.mem.Allocator) ![]rbac.PermissionView {
    const rows = try svc.rbac.allPermissions(alloc);
    const views = try alloc.alloc(rbac.PermissionView, rows.len);
    for (rows, 0..) |r, i| {
        views[i] = .{
            .code = try alloc.dupe(u8, r.code),
            .module = try alloc.dupe(u8, r.module),
            .name = try alloc.dupe(u8, r.name),
            .description = try alloc.dupe(u8, r.description),
        };
    }
    return views;
}

/// 按模块分组的权限清单（前端渲染权限树用）。
pub fn permissionModules(alloc: std.mem.Allocator) ![]ModuleGroup {
    const all = rbac.ALL_PERMISSIONS;
    var groups = std.ArrayList(ModuleGroup).empty;
    for (all) |p| {
        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.module, p.module)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        var items = std.ArrayList(rbac.PermissionView).empty;
        for (all) |q| {
            if (std.mem.eql(u8, q.module, p.module)) {
                try items.append(alloc, .{ .code = q.code, .module = q.module, .name = q.name, .description = q.name });
            }
        }
        try groups.append(alloc, .{ .module = p.module, .permissions = try items.toOwnedSlice(alloc) });
    }
    return groups.toOwnedSlice(alloc);
}

pub const ModuleGroup = struct {
    module: []const u8,
    permissions: []rbac.PermissionView,
};

pub fn createRole(svc: *AppServices, ctx: *framework.Context, actor: *Actor, req: model.dto.CreateRoleRequest) !rbac.RoleView {
    if (core.validate.code(req.code)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    if (core.validate.displayName(req.name)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    // 编码是否已被占用交给 `model.rbac.RoleTable` 的 unique 约束
    // （见下面 insertRole 的 catch 分支），不在这里预查。
    const now = svc.nowMs();
    const id = svc.rbac.insertRole(.{
        .code = req.code,
        .name = req.name,
        .description = req.description,
        .is_builtin = false,
        .created_at = now,
        .updated_at = now,
    }) catch |err| switch (err) {
        // roles 表只有 code 一条唯一约束，冲突只可能是它。
        error.UniqueViolation => {
            try errors.fail(ctx, errors.ApiError.conflict(codes.role_code_taken, "角色编码已被占用"));
            return error.Unreachable;
        },
        else => return err,
    };
    const row = (try svc.rbac.findRoleById(ctx.arena, id)).?;
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "role",
        .action = model.audit.actions.role_create,
        .target_type = "role",
        .target_id = id,
        .target_label = req.code,
        .message = try std.fmt.allocPrint(ctx.arena, "创建角色 {s}", .{req.name}),
    });
    return toRoleView(svc, ctx.arena, row);
}

pub fn updateRole(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, req: model.dto.UpdateRoleRequest) !rbac.RoleView {
    const before = (try svc.rbac.findRoleById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.role_not_found, "角色不存在"));
        return error.Unreachable;
    };
    var after = before;
    if (req.name) |v| {
        if (core.validate.displayName(v)) |m| {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
            return error.Unreachable;
        }
        after.name = v;
    }
    if (req.description) |v| after.description = v;
    after.updated_at = svc.nowMs();
    _ = try svc.rbac.updateRole(after);

    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "role",
        .action = model.audit.actions.role_update,
        .target_type = "role",
        .target_id = id,
        .target_label = after.code,
        .message = "更新角色",
        .changes = try core.diff.changesToJson(ctx.arena, try core.diff.diffStruct(rbac.RoleRow, ctx.arena, before, after, &.{ "id", "updated_at", "created_at" })),
    });
    return toRoleView(svc, ctx.arena, after);
}

pub fn deleteRole(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64) !void {
    const row = (try svc.rbac.findRoleById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.role_not_found, "角色不存在"));
        return error.Unreachable;
    };
    if (row.is_builtin) {
        try errors.fail(ctx, errors.ApiError.conflict(codes.role_is_builtin, "内置角色不可删除"));
        return error.Unreachable;
    }
    const users = try svc.rbac.countRoleUsers(id);
    if (users > 0) {
        const msg = try std.fmt.allocPrint(ctx.arena, "角色「{s}」还被 {d} 名用户持有，不能删除", .{ row.name, users });
        try errors.fail(ctx, errors.ApiError.conflict(codes.role_in_use, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .users = users })));
        return error.Unreachable;
    }
    _ = try svc.rbac.deleteRole(id);
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "role",
        .action = model.audit.actions.role_delete,
        .target_type = "role",
        .target_id = id,
        .target_label = row.code,
        .message = try std.fmt.allocPrint(ctx.arena, "删除角色 {s}", .{row.name}),
    });
}

/// 配置角色的权限点（全量替换）。未知权限点直接拒绝。
pub fn assignPermissions(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, permissions: []const []const u8) !rbac.RoleView {
    const role = (try svc.rbac.findRoleById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.role_not_found, "角色不存在"));
        return error.Unreachable;
    };
    for (permissions) |p| {
        if (!rbac.isKnownPermission(p)) {
            const msg = try std.fmt.allocPrint(ctx.arena, "未知权限点：{s}", .{p});
            try errors.fail(ctx, errors.ApiError.badRequest(codes.unknown_permission, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .permission = p })));
            return error.Unreachable;
        }
    }
    const before = try svc.rbac.permissionsOfRole(ctx.arena, id);
    try svc.rbac.setRolePermissions(id, permissions);
    const after = try svc.rbac.permissionsOfRole(ctx.arena, id);

    const changes = [_]core.diff.FieldChange{
        .{ .field = "permissions", .before = try joinPerms(ctx.arena, before), .after = try joinPerms(ctx.arena, after) },
    };
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "role",
        .action = model.audit.actions.role_assign_permissions,
        .target_type = "role",
        .target_id = id,
        .target_label = role.code,
        .message = "配置角色权限",
        .changes = try core.diff.changesToJson(ctx.arena, &changes),
    });
    return toRoleView(svc, ctx.arena, role);
}

fn joinPerms(alloc: std.mem.Allocator, perms: []const []const u8) ![]const u8 {
    if (perms.len == 0) return alloc.dupe(u8, "-");
    return std.mem.join(alloc, ",", perms);
}

// ── 测试：按模块分组是纯逻辑 ────────────────────────────────────────

test "permissionModules 每个模块只出现一次且权限齐全" {
    const groups = try permissionModules(std.testing.allocator);
    defer {
        for (groups) |g| std.testing.allocator.free(g.permissions);
        std.testing.allocator.free(groups);
    }
    var total: usize = 0;
    for (groups) |g| {
        total += g.permissions.len;
        for (groups) |h| {
            if (g.module == h.module and @intFromPtr(&g) != @intFromPtr(&h)) {
                try std.testing.expect(false);
            }
        }
    }
    try std.testing.expectEqual(rbac.ALL_PERMISSIONS.len, total);
}

test "joinPerms 空集合输出占位符" {
    try std.testing.expectEqualStrings("-", try joinPerms(std.testing.allocator, &.{}));
    const p = [_][]const u8{ "a:b", "c:d" };
    try std.testing.expectEqualStrings("a:b,c:d", try joinPerms(std.testing.allocator, &p));
}

test {
    std.testing.refAllDecls(@This());
}
