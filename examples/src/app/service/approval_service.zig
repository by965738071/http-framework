//! 审批服务：以「用户角色变更申请」为例的状态机。
//!
//! 规则：
//!   - 只有 pending 单可以流转（approve / reject / cancel）
//!   - 审批人不能是自己发起的单（申请人与审批人必须不同）
//!   - approve 成功后才真正把角色赋给目标用户，并留痕
//!   - 同一目标用户 + 同一角色存在 pending 单时不允许重复提交

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const repo = @import("../repo/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");
const audit_service = @import("audit_service.zig");
const actor_mod = @import("actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const Row = model.approval.Row;
const Status = model.approval.Status;
const errors = core.errors;
const codes = core.errors.codes;

pub fn get(svc: *AppServices, ctx: *framework.Context, id: u64) !Row {
    return (try svc.approvals.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "审批单不存在"));
        return error.Unreachable;
    };
}

pub fn list(
    svc: *AppServices,
    alloc: std.mem.Allocator,
    filter: repo.ApprovalFilter,
    page: usize,
    page_size: usize,
) !repo.SearchResult(Row) {
    return svc.approvals.search(alloc, filter, page, page_size);
}

pub fn create(svc: *AppServices, ctx: *framework.Context, actor: *Actor, req: model.dto.CreateApprovalRequest) !Row {
    if (core.validate.reason(req.reason)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    const target = (try svc.users.findById(ctx.arena, req.target_user_id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "目标用户不存在"));
        return error.Unreachable;
    };
    const role = (try svc.rbac.findRoleById(ctx.arena, req.role_id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.role_not_found, "角色不存在"));
        return error.Unreachable;
    };
    // 已有相同目标的 pending 单 → 拒绝重复提交
    const existing = try svc.approvals.searchAll(ctx.arena, .{ .status = "pending", .target_user_id = req.target_user_id });
    for (existing) |e| {
        if (e.role_id == req.role_id) {
            try errors.fail(ctx, errors.ApiError.conflict(codes.validation_error, "该用户已有一份针对此角色的待审批申请"));
            return error.Unreachable;
        }
    }

    const now = svc.nowMs();
    const id = try svc.approvals.insert(.{
        .kind = @tagName(model.approval.Kind.role_change),
        .applicant_id = actor.id,
        .applicant_name = actor.username,
        .target_user_id = target.id,
        .target_user_name = target.display_name,
        .role_id = role.id,
        .role_name = role.name,
        .reason = req.reason,
        .status = @tagName(Status.pending),
        .reviewer_id = 0,
        .reviewer_name = "",
        .review_comment = "",
        .created_at = now,
        .updated_at = now,
    });
    const row = (try svc.approvals.findById(ctx.arena, id)).?;
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "approval",
        .action = model.audit.actions.approval_create,
        .target_type = "approval",
        .target_id = id,
        .target_label = try std.fmt.allocPrint(ctx.arena, "{s} → {s}", .{ target.display_name, role.name }),
        .message = "发起角色变更申请",
    });
    try broadcast(svc, "approval.created", id, row.status);
    return row;
}

/// 审批。动作：approve / reject / cancel。
pub fn review(svc: *AppServices, ctx: *framework.Context, actor: *Actor, id: u64, action_str: []const u8, comment: []const u8) !Row {
    if (core.validate.reason(comment)) |m| {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, m));
        return error.Unreachable;
    }
    const action = model.approval.parseAction(action_str) orelse {
        try errors.fail(ctx, errors.ApiError.badRequest(codes.validation_error, "动作必须是 approve/reject/cancel"));
        return error.Unreachable;
    };
    const before = (try svc.approvals.findById(ctx.arena, id)) orelse {
        try errors.fail(ctx, errors.ApiError.notFound(codes.not_found, "审批单不存在"));
        return error.Unreachable;
    };
    const current = model.approval.parseStatus(before.status) orelse .pending;
    const next = model.approval.applyAction(current, action) orelse {
        const msg = try std.fmt.allocPrint(ctx.arena, "非法流转：{s} 单不能执行 {s}", .{ before.status, action_str });
        try errors.fail(ctx, errors.ApiError.conflict(codes.illegal_approval_transition, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .from = before.status, .action = action_str })));
        return error.Unreachable;
    };
    if (action == .cancel and before.applicant_id != actor.id and !actor.isSuperAdmin()) {
        try errors.fail(ctx, errors.ApiError.forbidden(codes.permission_denied, "只能撤回自己发起的申请"));
        return error.Unreachable;
    }
    if (action != .cancel and before.applicant_id == actor.id) {
        try errors.fail(ctx, errors.ApiError.forbidden(codes.permission_denied, "不能审批自己发起的申请"));
        return error.Unreachable;
    }

    var after = before;
    after.status = @tagName(next);
    after.reviewer_id = actor.id;
    after.reviewer_name = actor.username;
    after.review_comment = comment;
    after.updated_at = svc.nowMs();
    _ = try svc.approvals.update(after);

    // 通过 → 真正落地角色变更
    if (next == .approved) {
        const role_ids = try svc.rbac.roleIdsOfUser(ctx.arena, after.target_user_id);
        var merged = std.ArrayList(u64).empty;
        for (role_ids) |rid| try merged.append(ctx.arena, rid);
        if (!containsId(merged.items, after.role_id)) try merged.append(ctx.arena, after.role_id);
        try svc.rbac.setUserRoles(after.target_user_id, merged.items);
        try audit_service.record(svc, ctx, actor.id, actor.username, .{
            .module = "user",
            .action = model.audit.actions.user_assign_roles,
            .target_type = "user",
            .target_id = after.target_user_id,
            .target_label = after.target_user_name,
            .message = try std.fmt.allocPrint(ctx.arena, "审批通过，授予角色 {s}", .{after.role_name}),
        });
    }

    const changes = [_]core.diff.FieldChange{.{ .field = "status", .before = before.status, .after = after.status }};
    try audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "approval",
        .action = model.audit.actions.approval_review,
        .target_type = "approval",
        .target_id = id,
        .target_label = try std.fmt.allocPrint(ctx.arena, "{s} → {s}", .{ after.target_user_name, after.role_name }),
        .message = try std.fmt.allocPrint(ctx.arena, "审批单 {s}", .{action_str}),
        .changes = try core.diff.changesToJson(ctx.arena, &changes),
    });
    try broadcast(svc, "approval.reviewed", id, after.status);
    return after;
}

fn containsId(ids: []const u64, id: u64) bool {
    for (ids) |i| if (i == id) return true;
    return false;
}

fn broadcast(svc: *AppServices, event_type: []const u8, id: u64, status: []const u8) !void {
    const text = try core.respond.toJson(svc.allocator, .{
        .type = event_type,
        .data = .{ .id = id, .status = status },
        .ts = svc.nowMs(),
    });
    defer svc.allocator.free(text);
    svc.notifier.broadcast(text) catch {};
}

test {
    std.testing.refAllDecls(@This());
}
