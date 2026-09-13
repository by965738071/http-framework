//! 审批流 handler。

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
    const filter = repo.ApprovalFilter{
        .status = core.util.queryStr(ctx, "status", ""),
        .keyword = core.util.queryStr(ctx, "keyword", ""),
    };
    const result = try service.approval_service.list(svc, ctx.arena, filter, p.page, p.page_size);
    try core.respond.page(res, result.items, result.total, p.page + 1, p.page_size);
}

pub fn get(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try core.respond.ok(res, try service.approval_service.get(svc, ctx, id));
}

pub fn create(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const req = try core.body.json(model.dto.CreateApprovalRequest, ctx, res);
    const row = try service.approval_service.create(svc, ctx, actor, req);
    _ = res.statusCode(.created);
    try core.respond.ok(res, row);
}

pub fn review(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.ReviewApprovalRequest, ctx, res);
    try core.respond.ok(res, try service.approval_service.review(svc, ctx, actor, id, req.action, req.comment));
}
