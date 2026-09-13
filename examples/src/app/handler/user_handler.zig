//! 用户管理 handler。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const model = @import("../model/mod.zig");
const repo = @import("../repo/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

pub fn list(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const p = mod.paging(ctx);
    var filter = repo.UserFilter{
        .keyword = core.util.queryStr(ctx, "keyword", ""),
        .status = if (core.util.queryStr(ctx, "status", "").len > 0) core.util.queryStr(ctx, "status", "") else null,
    };
    const org_raw = core.util.queryStr(ctx, "org_id", "");
    if (org_raw.len > 0) {
        const oid = std.fmt.parseInt(u64, org_raw, 10) catch {
            try core.errors.fail(ctx, core.errors.ApiError.badRequest(core.errors.codes.validation_error, "org_id 必须是整数"));
            return;
        };
        filter.org_id = oid;
        filter.include_sub_orgs = std.mem.eql(u8, core.util.queryStr(ctx, "include_sub", ""), "true");
        if (filter.include_sub_orgs) {
            filter.org_ids = try service.org_service.subtreeIds(svc, ctx.arena, oid);
        }
    }
    const result = try service.user_service.list(svc, ctx, filter, p.page, p.page_size);
    try core.respond.page(res, result.items, result.total, p.page + 1, p.page_size);
}

pub fn create(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const req = try core.body.json(model.dto.CreateUserRequest, ctx, res);
    const view = try service.user_service.create(svc, ctx, actor, req);
    _ = res.statusCode(.created);
    try core.respond.ok(res, view);
}

pub fn get(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try core.respond.ok(res, try service.user_service.get(svc, ctx, id));
}

pub fn update(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.UpdateUserRequest, ctx, res);
    try core.respond.ok(res, try service.user_service.update(svc, ctx, actor, id, req));
}

pub fn remove(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try service.user_service.remove(svc, ctx, actor, id);
    try core.respond.okEmpty(res);
}

pub fn changeStatus(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.ChangeStatusRequest, ctx, res);
    try core.respond.ok(res, try service.user_service.changeStatus(svc, ctx, actor, id, req.status, req.reason));
}

pub fn unlock(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try core.respond.ok(res, try service.user_service.unlock(svc, ctx, actor, id));
}

pub fn resetPassword(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.ResetPasswordRequest, ctx, res);
    try service.user_service.resetPassword(svc, ctx, actor, id, req.password);
    try core.respond.okEmpty(res);
}

pub fn assignRoles(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.AssignRolesRequest, ctx, res);
    try core.respond.ok(res, try service.user_service.assignRoles(svc, ctx, actor, id, req.role_ids));
}
