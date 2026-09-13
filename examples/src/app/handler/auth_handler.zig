//! 认证相关 handler：登录 / 登出 / 当前用户 / 我的权限。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const model = @import("../model/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

pub fn login(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const req = try core.body.json(model.dto.LoginRequest, ctx, res);
    const actor = try service.auth_service.login(svc, ctx, res, req.username, req.password);
    try core.respond.ok(res, .{
        .id = actor.id,
        .username = actor.username,
        .display_name = actor.display_name,
        .org_id = actor.org_id,
        .permissions = actor.permissions,
    });
}

pub fn logout(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    try service.auth_service.logout(svc, ctx, res);
    try core.respond.okEmpty(res);
}

pub fn me(_: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    try core.respond.ok(res, .{
        .id = actor.id,
        .username = actor.username,
        .display_name = actor.display_name,
        .org_id = actor.org_id,
        .status = actor.status,
        .permissions = actor.permissions,
        .is_super_admin = actor.isSuperAdmin(),
    });
}

pub fn permissions(_: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    try core.respond.ok(res, .{ .permissions = actor.permissions, .is_super_admin = actor.isSuperAdmin() });
}
