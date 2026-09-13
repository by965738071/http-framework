//! 角色与权限点 handler。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const model = @import("../model/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

pub fn listRoles(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    try core.respond.ok(res, try service.rbac_service.listRoles(svc, ctx.arena));
}

pub fn createRole(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const req = try core.body.json(model.dto.CreateRoleRequest, ctx, res);
    const view = try service.rbac_service.createRole(svc, ctx, actor, req);
    _ = res.statusCode(.created);
    try core.respond.ok(res, view);
}

pub fn updateRole(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.UpdateRoleRequest, ctx, res);
    try core.respond.ok(res, try service.rbac_service.updateRole(svc, ctx, actor, id, req));
}

pub fn deleteRole(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    try service.rbac_service.deleteRole(svc, ctx, actor, id);
    try core.respond.okEmpty(res);
}

pub fn assignPermissions(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const id = (try core.util.pathId(ctx, "id")) orelse return;
    const req = try core.body.json(model.dto.AssignPermissionsRequest, ctx, res);
    try core.respond.ok(res, try service.rbac_service.assignPermissions(svc, ctx, actor, id, req.permissions));
}

pub fn listPermissions(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    try core.respond.ok(res, try service.rbac_service.listPermissions(svc, ctx.arena));
}

pub fn permissionGroups(_: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    try core.respond.ok(res, try service.rbac_service.permissionModules(ctx.arena));
}
