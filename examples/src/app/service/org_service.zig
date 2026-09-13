//! 组织服务：树形结构 + 移动（防环）+ 删除前业务校验。

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");
const audit_service = @import("audit_service.zig");
const actor_mod = @import("actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const Row = model.org.Row;
const errors = core.errors;
const codes = core.errors.codes;

pub fn toView(svc: *AppServices, alloc: std.mem.Allocator, row: Row) !model.org.View {
    return .{
        .id = row.id,
        .name = try alloc.dupe(u8, row.name),
        .code = try alloc.dupe(u8, row.code),
        .parent_id = row.parent_id,
        .leader = try alloc.dupe(u8, row.leader),
        .sort_order = row.sort_order,
        .member_count = try svc.orgs.countMembers(row.id),
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

/// 整棵树（森林形式）。
pub fn tree(svc: *AppServices, alloc: std.mem.Allocator) ![]model.org.TreeNode {
    const rows = try svc.orgs.all(alloc);
    const views = try alloc.alloc(model.org.View, rows.len);
    for (rows, 0..) |r, i| {
        views[i] = try toView(svc, alloc, r);
    }
    return model.org.buildTree(alloc, views);
}

pub fn list(svc: *AppServices, alloc: std.mem.Allocator, keyword: []const u8) ![]model.org.View {
    const rows = try svc.orgs.search(alloc, keyword);
    const views = try alloc.alloc(model.org.View, rows.len);
    for (rows, 0..) |r, i| {
        views[i] = try toView(svc, alloc, r);
    }
    return views;
}

pub fn get(svc: *AppServices, ctx: *framework.Context, id: u64) !model.org.View {
    const row = (try svc.orgs.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.org_not_found, "组织不存在"));
        return error.Unreachable;
    };
    return toView(svc, ctx.arena, row);
}

pub fn create(svc: *AppServices, ctx: *framework.Context, actor: *Actor, req: model.dto.CreateOrgRequest) !model.org.View {
    if (core.validate.displayName(req.name)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    if (core.validate.code(req.code)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    // 编码是否已被占用不在这里查：交给 `model.org.Table` 的 unique 约束
    // （见下面 insert 的 catch 分支），避免 check 与 insert 之间的竞态。
    if (req.parent_id != 0 and (try svc.orgs.findById(ctx.arena, req.parent_id)) == null) {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.org_not_found, "父组织不存在"));
        return error.Unreachable;
    }

    const now = svc.nowMs();
    const id = svc.orgs.insert(.{
        .name = req.name,
        .code = req.code,
        .parent_id = req.parent_id,
        .leader = req.leader,
        .sort_order = req.sort_order,
        .created_at = now,
        .updated_at = now,
    }) catch |err| switch (err) {
        // orgs 表只有 code 一条唯一约束，冲突只可能是它。
        error.UniqueViolation => {
            try errors.fail(ctx, errors.ApiError.conflict(codes.org_code_taken, "组织编码已被占用"));
            return error.Unreachable;
        },
        else => return err,
    };
    const row = (try svc.orgs.findById(ctx.arena, id)).?;
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "org",
        .action = model.audit.actions.org_create,
        .target_type = "org",
        .target_id = id,
        .target_label = req.name,
        .message = try std.fmt.allocPrint(ctx.arena, "创建组织 {s}", .{req.name}),
    });
    try broadcastOrg(svc, "org.created", id, req.name);
    return toView(svc, ctx.arena, row);
}

pub fn update(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, req: model.dto.UpdateOrgRequest) !model.org.View {
    const before = (try svc.orgs.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.org_not_found, "组织不存在"));
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
    if (req.leader) |v| {
        if (v.len > core.validate.Limits.name_max) {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, "负责人最多 64 个字符"));
            return error.Unreachable;
        }
        after.leader = v;
    }
    if (req.sort_order) |v| after.sort_order = v;
    after.updated_at = svc.nowMs();

    const changes = try core.diff.diffStruct(Row, ctx.arena, before, after, &model.org.diff_ignore);
    const changes_json = if (changes.len > 0) try core.diff.changesToJson(ctx.arena, changes) else core.diff.empty_json;
    _ = try svc.orgs.update(after);

    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "org",
        .action = model.audit.actions.org_update,
        .target_type = "org",
        .target_id = id,
        .target_label = after.name,
        .message = try std.fmt.allocPrint(ctx.arena, "更新组织 {s}", .{after.name}),
        .changes = changes_json,
    });
    try broadcastOrg(svc, "org.updated", id, after.name);
    return toView(svc, ctx.arena, after);
}

/// 移动部门：改父节点。禁止挂到自己或自己的子孙下（防环）。
pub fn move(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, new_parent_id: u64) !model.org.View {
    const before = (try svc.orgs.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.org_not_found, "组织不存在"));
        return error.Unreachable;
    };
    if (new_parent_id == id) {
        try errors.fail(ctx, errors.ApiError.conflict(codes.org_cycle, "不能把组织挂到自己下面"));
        return error.Unreachable;
    }
    if (new_parent_id != 0) {
        const parent = (try svc.orgs.findById(ctx.arena, new_parent_id)) orelse {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.org_not_found, "目标父组织不存在"));
            return error.Unreachable;
        };
        _ = parent;
        const rows = try svc.orgs.all(ctx.arena);
        if (model.org.isAncestor(rows, id, new_parent_id)) {
            try errors.fail(ctx, errors.ApiError.conflict(codes.org_cycle, "不能把组织移动到自己的子组织下（会形成环）"));
            return error.Unreachable;
        }
    }
    if (before.parent_id == new_parent_id) {
        return toView(svc, ctx.arena, before);
    }

    var after = before;
    after.parent_id = new_parent_id;
    after.updated_at = svc.nowMs();
    _ = try svc.orgs.update(after);

    const changes = [_]core.diff.FieldChange{
        .{ .field = "parent_id", .before = try std.fmt.allocPrint(ctx.arena, "{d}", .{before.parent_id}), .after = try std.fmt.allocPrint(ctx.arena, "{d}", .{new_parent_id}) },
    };
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "org",
        .action = model.audit.actions.org_move,
        .target_type = "org",
        .target_id = id,
        .target_label = after.name,
        .message = try std.fmt.allocPrint(ctx.arena, "移动组织 {s} 到父节点 {d}", .{ after.name, new_parent_id }),
        .changes = try core.diff.changesToJson(ctx.arena, &changes),
    });
    try broadcastOrg(svc, "org.moved", id, after.name);
    return toView(svc, ctx.arena, after);
}

/// 删除：有子组织或有成员时拒绝，并给出明确原因。
pub fn remove(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64) !void {
    const row = (try svc.orgs.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.org_not_found, "组织不存在"));
        return error.Unreachable;
    };
    const children = try svc.orgs.countChildren(id);
    if (children > 0) {
        const msg = try std.fmt.allocPrint(ctx.arena, "组织「{s}」下还有 {d} 个子组织，不能删除", .{ row.name, children });
        try errors.fail(ctx, errors.ApiError.conflict(codes.org_has_children, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .children = children })));
        return error.Unreachable;
    }
    const members = try svc.orgs.countMembers(id);
    if (members > 0) {
        const msg = try std.fmt.allocPrint(ctx.arena, "组织「{s}」下还有 {d} 名成员，请先转移成员", .{ row.name, members });
        try errors.fail(ctx, errors.ApiError.conflict(codes.org_has_members, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .members = members })));
        return error.Unreachable;
    }

    _ = try svc.orgs.delete(id);
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "org",
        .action = model.audit.actions.org_delete,
        .target_type = "org",
        .target_id = id,
        .target_label = row.name,
        .message = try std.fmt.allocPrint(ctx.arena, "删除组织 {s}", .{row.name}),
    });
    try broadcastOrg(svc, "org.deleted", id, row.name);
}

/// 某组织及其全部子孙组织的 id（用于「含子组织」的成员检索）。
pub fn subtreeIds(svc: *AppServices, alloc: std.mem.Allocator, id: u64) ![]u64 {
    const rows = try svc.orgs.all(alloc);
    return model.org.subtreeIds(alloc, rows, id);
}

fn broadcastOrg(svc: *AppServices, event_type: []const u8, id: u64, name: []const u8) !void {
    const text = try core.respond.toJson(svc.allocator, .{
        .type = event_type,
        .data = .{ .id = id, .name = name },
        .ts = svc.nowMs(),
    });
    defer svc.allocator.free(text);
    svc.notifier.broadcast(text) catch {};
}

test {
    std.testing.refAllDecls(@This());
}
