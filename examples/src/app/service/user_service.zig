//! 用户服务：CRUD + 状态机 + 密码重置 + 角色分配。
//!
//! 每个写操作都写审计日志（含字段级 diff），并对关键操作发实时通知。

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");
const audit_service = @import("audit_service.zig");
const actor_mod = @import("actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const Row = model.user.Row;
const errors = core.errors;
const codes = core.errors.codes;

/// 把 ORM 行装配成对外视图（补 org_name / roles，去掉 password_hash）。
pub fn toView(svc: *AppServices, alloc: std.mem.Allocator, row: Row) !model.user.View {
    var org_name: []const u8 = "";
    if (row.org_id != 0) {
        if (try svc.orgs.findById(alloc, row.org_id)) |o| org_name = try alloc.dupe(u8, o.name);
    }
    const role_ids = try svc.rbac.roleIdsOfUser(alloc, row.id);
    const roles = try alloc.alloc(model.user.RoleRef, role_ids.len);
    for (role_ids, 0..) |rid, i| {
        if (try svc.rbac.findRoleById(alloc, rid)) |r| {
            roles[i] = .{ .id = r.id, .code = try alloc.dupe(u8, r.code), .name = try alloc.dupe(u8, r.name) };
        } else {
            roles[i] = .{ .id = rid, .code = "", .name = "" };
        }
    }
    return .{
        .id = row.id,
        .username = try alloc.dupe(u8, row.username),
        .display_name = try alloc.dupe(u8, row.display_name),
        .email = try alloc.dupe(u8, row.email),
        .org_id = row.org_id,
        .org_name = org_name,
        .status = try alloc.dupe(u8, row.status),
        .failed_attempts = row.failed_attempts,
        .locked_until = row.locked_until,
        .last_login_at = row.last_login_at,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
        .roles = roles,
    };
}

pub fn list(svc: *AppServices, ctx: *framework.Context, filter: @import("../repo/mod.zig").UserFilter, page: usize, page_size: usize) !struct { items: []model.user.View, total: usize } {
    const result = try svc.users.search(ctx.arena, filter, page, page_size);
    const views = try ctx.arena.alloc(model.user.View, result.items.len);
    for (result.items, 0..) |r, i| {
        views[i] = try toView(svc, ctx.arena, r);
    }
    return .{ .items = views, .total = result.total };
}

pub fn get(svc: *AppServices, ctx: *framework.Context, id: u64) !model.user.View {
    const row = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };
    return toView(svc, ctx.arena, row);
}

pub fn create(svc: *AppServices, ctx: *framework.Context, actor: *Actor, req: model.dto.CreateUserRequest) !model.user.View {
    try validateCreate(svc, ctx, req);

    const now = svc.nowMs();
    const hash = try core.password.encode(svc.allocator, req.password, core.password.randomSalt(svc.io));
    defer svc.allocator.free(hash);

    // 唯一性由 `model.user.Table` 的 unique 约束兜底（不用「先查再插」：
    // 那样 check 与 insert 之间有个窗口，两个并发请求能同时通过检查）。
    const id = svc.users.insert(.{
        .username = req.username,
        .display_name = req.display_name,
        .email = req.email,
        .password_hash = hash,
        .org_id = req.org_id,
        .status = req.status,
        .failed_attempts = 0,
        .locked_until = 0,
        .last_login_at = 0,
        .created_at = now,
        .updated_at = now,
    }) catch |err| switch (err) {
        error.UniqueViolation => {
            // ORM 只回一个不带字段名的 UniqueViolation，而契约要求用户名/邮箱
            // 分开报。insert 失败意味着**一行都没写进去**，所以事后重查不会
            // 查到自己，可以据此还原具体 code：users 表只有 username / email
            // 两条唯一约束，不是前者就是后者。
            if (try svc.users.findByUsername(ctx.arena, req.username) != null) {
                try errors.fail(ctx, errors.ApiError.conflict(codes.username_taken, "用户名已被占用"));
            } else {
                try errors.fail(ctx, errors.ApiError.conflict(codes.email_taken, "邮箱已被占用"));
            }
            return error.Unreachable;
        },
        else => return err,
    };
    if (req.role_ids.len > 0) {
        try validateRoleIds(svc, ctx, req.role_ids);
        try svc.rbac.setUserRoles(id, req.role_ids);
    }

    const row = (try svc.users.findById(ctx.arena, id)).?;
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_create,
        .target_type = "user",
        .target_id = id,
        .target_label = req.username,
        .message = try std.fmt.allocPrint(ctx.arena, "创建用户 {s}", .{req.display_name}),
    });
    try notifyUserEvent(svc, "user.created", id, req.username);
    return toView(svc, ctx.arena, row);
}

pub fn update(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, req: model.dto.UpdateUserRequest) !model.user.View {
    const before = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };

    var after = before;
    if (req.display_name) |v| {
        if (core.validate.displayName(v)) |m| {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
            return error.Unreachable;
        }
        after.display_name = v;
    }
    if (req.email) |v| {
        if (core.validate.email(v)) |m| {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
            return error.Unreachable;
        }
        after.email = v;
    }
    if (req.org_id) |v| {
        if (v != 0 and (try svc.orgs.findById(ctx.arena, v)) == null) {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.org_not_found, "所属组织不存在"));
            return error.Unreachable;
        }
        after.org_id = v;
    }
    if (req.status) |v| {
        const target = model.user.parseStatus(v) orelse {
            try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, "状态取值必须是 active/disabled/locked"));
            return error.Unreachable;
        };
        if (!model.user.transitionAllowed(before.statusEnum(), target)) {
            const msg = try std.fmt.allocPrint(
                ctx.arena,
                "非法状态流转：{s} → {s}",
                .{ @tagName(before.statusEnum()), v },
            );
            try errors.fail(ctx, errors.ApiError.conflict(codes.illegal_status_transition, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .from = before.status, .to = v })));
            return error.Unreachable;
        }
        after.status = v;
        if (target == .active) {
            after.failed_attempts = 0;
            after.locked_until = 0;
        }
    }
    after.updated_at = svc.nowMs();

    const changes = try core.diff.diffStruct(Row, ctx.arena, before, after, &model.user.diff_ignore);
    const changes_json = if (changes.len > 0) try core.diff.changesToJson(ctx.arena, changes) else core.diff.empty_json;
    // update 里可变的唯一字段只有 email（用户名不可改），所以冲突只可能是它；
    // 校验在 ORM 的锁内完成，不存在 check 与 write 之间的竞态窗口。
    _ = svc.users.update(after) catch |err| switch (err) {
        error.UniqueViolation => {
            try errors.fail(ctx, errors.ApiError.conflict(codes.email_taken, "邮箱已被占用"));
            return error.Unreachable;
        },
        else => return err,
    };

    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_update,
        .target_type = "user",
        .target_id = id,
        .target_label = after.username,
        .message = try std.fmt.allocPrint(ctx.arena, "更新用户 {s}", .{after.display_name}),
        .changes = changes_json,
    });
    try notifyUserEvent(svc, "user.updated", id, after.username);
    return toView(svc, ctx.arena, after);
}

pub fn remove(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64) !void {
    if (actor.id == id) {
        try errors.fail(ctx, errors.ApiError.conflict(codes.cannot_delete_self, "不能删除当前登录的用户"));
        return error.Unreachable;
    }
    const row = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };
    _ = try svc.users.delete(id);
    try svc.rbac.setUserRoles(id, &.{});
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_delete,
        .target_type = "user",
        .target_id = id,
        .target_label = row.username,
        .message = try std.fmt.allocPrint(ctx.arena, "删除用户 {s}", .{row.display_name}),
    });
    try notifyUserEvent(svc, "user.deleted", id, row.username);
}

/// 状态流转（启用 / 禁用 / 锁定）。
pub fn changeStatus(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, status: []const u8, reason: []const u8) !model.user.View {
    if (core.validate.reason(reason)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    const target = model.user.parseStatus(status) orelse {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, "状态取值必须是 active/disabled/locked"));
        return error.Unreachable;
    };
    const before = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };
    if (!model.user.transitionAllowed(before.statusEnum(), target)) {
        const msg = try std.fmt.allocPrint(ctx.arena, "非法状态流转：{s} → {s}", .{ @tagName(before.statusEnum()), status });
        try errors.fail(ctx, errors.ApiError.conflict(codes.illegal_status_transition, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .from = before.status, .to = status })));
        return error.Unreachable;
    }
    if (actor.id == id and target != .active) {
        try errors.fail(ctx, errors.ApiError.conflict(codes.cannot_demote_self, "不能禁用或锁定自己"));
        return error.Unreachable;
    }

    var after = before;
    after.status = status;
    after.updated_at = svc.nowMs();
    if (target == .active) {
        after.failed_attempts = 0;
        after.locked_until = 0;
    } else if (target == .locked) {
        after.locked_until = svc.nowMs() + @import("auth_service.zig").LOCK_DURATION_MS;
    }
    _ = try svc.users.update(after);

    const changes = [_]core.diff.FieldChange{.{ .field = "status", .before = before.status, .after = status }};
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_status_change,
        .target_type = "user",
        .target_id = id,
        .target_label = after.username,
        .message = if (reason.len > 0) reason else try std.fmt.allocPrint(ctx.arena, "状态变更为 {s}", .{status}),
        .changes = try core.diff.changesToJson(ctx.arena, &changes),
    });
    try notifyUserEvent(svc, "user.status_changed", id, after.username);
    return toView(svc, ctx.arena, after);
}

/// 解锁（等价于 locked → active，并清零失败计数）。
pub fn unlock(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64) !model.user.View {
    return changeStatus(svc, ctx, actor, id, @tagName(model.user.Status.active), "管理员解除锁定");
}

pub fn resetPassword(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, new_password: []const u8) !void {
    if (core.validate.password(new_password)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.weak_password, m));
        return error.Unreachable;
    }
    const before = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };
    const hash = try core.password.encode(svc.allocator, new_password, core.password.randomSalt(svc.io));
    defer svc.allocator.free(hash);

    var after = before;
    after.password_hash = hash;
    after.failed_attempts = 0;
    after.locked_until = 0;
    after.updated_at = svc.nowMs();
    _ = try svc.users.update(after);

    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_reset_password,
        .target_type = "user",
        .target_id = id,
        .target_label = after.username,
        .message = "重置密码",
    });
    try notifyUserEvent(svc, "user.password_reset", id, after.username);
}

/// 分配角色（全量替换）。
pub fn assignRoles(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, role_ids: []const u64) !model.user.View {
    const before = (try svc.users.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "用户不存在"));
        return error.Unreachable;
    };
    try validateRoleIds(svc, ctx, role_ids);

    const before_ids = try svc.rbac.roleIdsOfUser(ctx.arena, id);
    try svc.rbac.setUserRoles(id, role_ids);
    const after_ids = try svc.rbac.roleIdsOfUser(ctx.arena, id);

    const changes = [_]core.diff.FieldChange{
        .{ .field = "roles", .before = try joinIds(ctx.arena, before_ids), .after = try joinIds(ctx.arena, after_ids) },
    };
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "user",
        .action = model.audit.actions.user_assign_roles,
        .target_type = "user",
        .target_id = id,
        .target_label = before.username,
        .message = "分配角色",
        .changes = try core.diff.changesToJson(ctx.arena, &changes),
    });
    try notifyUserEvent(svc, "user.roles_changed", id, before.username);
    const after = (try svc.users.findById(ctx.arena, id)).?;
    return toView(svc, ctx.arena, after);
}

// ── 内部 ────────────────────────────────────────────────────────────

fn validateCreate(svc: *AppServices, ctx: *framework.Context, req: model.dto.CreateUserRequest) !void {
    if (core.validate.username(req.username)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return;
    }
    if (core.validate.password(req.password)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.weak_password, m));
        return;
    }
    if (core.validate.displayName(req.display_name)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return;
    }
    if (core.validate.email(req.email)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return;
    }
    if (model.user.parseStatus(req.status) == null) {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, "状态取值必须是 active/disabled/locked"));
        return;
    }
    // 用户名/邮箱是否已被占用**不在这里查**——交给 ORM 的唯一约束（见 create
    // 里的 catch 分支）。这里只做与存储无关的格式校验。
    if (req.org_id != 0 and (try svc.orgs.findById(ctx.arena, req.org_id)) == null) {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.org_not_found, "所属组织不存在"));
        return;
    }
}

fn validateRoleIds(svc: *AppServices, ctx: *framework.Context, role_ids: []const u64) !void {
    for (role_ids) |rid| {
        if (try svc.rbac.findRoleById(ctx.arena, rid) == null) {
            const msg = try std.fmt.allocPrint(ctx.arena, "角色 {d} 不存在", .{rid});
            try errors.fail(ctx, errors.ApiError.badRequest(codes.role_not_found, msg));
            return;
        }
    }
}

fn joinIds(alloc: std.mem.Allocator, ids: []const u64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    for (ids, 0..) |id, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{d}", .{id});
    }
    if (ids.len == 0) try w.writeAll("-");
    return alloc.dupe(u8, out.written());
}

fn notifyUserEvent(svc: *AppServices, event_type: []const u8, id: u64, username: []const u8) !void {
    const text = try core.respond.toJson(svc.allocator, .{
        .type = event_type,
        .data = .{ .id = id, .username = username },
        .ts = svc.nowMs(),
    });
    defer svc.allocator.free(text);
    svc.notifier.broadcast(text) catch {};
}

// ── 测试：纯逻辑 ────────────────────────────────────────────────────

test "joinIds 空列表返回占位符" {
    try std.testing.expectEqualStrings("-", try joinIds(std.testing.allocator, &.{}));
    try std.testing.expectEqualStrings("1,2,3", try joinIds(std.testing.allocator, &.{ 1, 2, 3 }));
}

test {
    std.testing.refAllDecls(@This());
}
