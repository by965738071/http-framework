//! 组织管理 handler。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const model = @import("../model/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

pub fn tree(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    try core.respond.ok(res, try service.org_service.tree(svc, ctx.arena));
}

pub fn list(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const keyword = core.util.queryStr(ctx, "keyword", "");
    try core.respond.ok(res, try service.org_service.list(svc, ctx.arena, keyword));
}

pub fn create(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const req = try core.body.json(model.dto.CreateOrgRequest, ctx, res);
    const view = try service.org_service.create(svc, ctx, actor, req);
    _ = res.statusCode(.created);
    try core.respond.ok(res, view);
}

pub fn get(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try core.respond.ok(res, try service.org_service.get(svc, ctx, id));
}

pub fn update(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.UpdateOrgRequest, ctx, res);
    try core.respond.ok(res, try service.org_service.update(svc, ctx, actor, id, req));
}

pub fn move(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.MoveOrgRequest, ctx, res);
    try core.respond.ok(res, try service.org_service.move(svc, ctx, actor, id, req.parent_id));
}

pub fn remove(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try service.org_service.remove(svc, ctx, actor, id);
    try core.respond.okEmpty(res);
}

/// 组织成员列表（配合组织树使用）。
pub fn members(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const p = mod.paging(ctx);
    const org_ids = try service.org_service.subtreeIds(svc, ctx.arena, id);
    const result = try service.user_service.list(svc, ctx, .{ .org_ids = org_ids, .include_sub_orgs = true }, p.page, p.page_size);
    try core.respond.page(res, result.items, result.total, p.page + 1, p.page_size);
}
