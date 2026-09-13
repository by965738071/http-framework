//! 杂项 handler：健康检查、仪表盘统计、WebSocket 实时通知。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

/// /api/v1 下未命中路径的兜底（挂在组内最后一条 `GET /*` 上）。
///
/// 404 现在虽然会走最长前缀组的中间件链，但框架的两个默认 handler 仍各自写
/// 纯文本 / 另一种 JSON 格式，组里的 ErrorJson 只在**有 error 抛出**时才介入，
/// 拦不住它们。所以还需要这条 catch-all 把 /api/v1 的 404 拉回业务契约格式，
/// 详见 FRICTION.md F-12（含实测记录）。
pub fn notFound(svc: *AppServices, _: *framework.Context, res: *framework.Response) !void {
    try core.respond.writeError(
        svc.allocator,
        res,
        core.errors.ApiError.notFound(core.errors.codes.not_found, "接口不存在"),
    );
}

/// 健康检查兼 seed 自检：fresh clone 起来后打这条路由，能直接看出幂等 seed
/// 到底插了多少东西（全 0 说明 data/ 目录或 seed 有问题）。
pub fn health(svc: *AppServices, _: *framework.Context, res: *framework.Response) !void {
    try core.respond.ok(res, .{
        .status = "ok",
        .service = "admin-api",
        .version = "v1",
        .counts = .{
            .users = try svc.users.countAll(),
            .orgs = try svc.orgs.countAll(),
            .roles = try svc.rbac.countRoles(),
            .permissions = try svc.rbac.countPermissions(),
            .audit_logs = try svc.audit.countAll(),
            .pending_approvals = try svc.approvals.countPending(),
        },
    });
}

pub fn dashboard(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const users = try svc.users.countAll();
    const perms = try svc.rbac.countPermissions();
    const pending = try svc.approvals.countPending();
    const logs = try svc.audit.countAll();

    const org_rows = try svc.orgs.all(ctx.arena);
    const roles = try svc.rbac.allRoles(ctx.arena);

    // 各状态用户数
    var active: usize = 0;
    var disabled: usize = 0;
    var locked: usize = 0;
    const user_rows = try svc.users.all(ctx.arena);
    for (user_rows) |u| {
        switch (u.statusEnum()) {
            .active => active += 1,
            .disabled => disabled += 1,
            .locked => locked += 1,
        }
    }

    try core.respond.ok(res, .{
        .users = .{ .total = users, .active = active, .disabled = disabled, .locked = locked },
        .orgs = org_rows.len,
        .roles = roles.len,
        .permissions = perms,
        .pending_approvals = pending,
        .audit_logs = logs,
        .online_connections = svc.notifier.onlineCount(),
    });
}

/// WebSocket 实时通知：连接即注册进广播器，断开自动注销。
pub fn ws(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const upgraded = try framework.wsUpgrade(ctx, res, @ptrCast(svc), onWs);
    if (!upgraded) {
        if (!res.sent) try res.statusCode(.bad_request).text("expected a WebSocket upgrade request");
        return;
    }
}

fn onWs(conn: *framework.WebSocket, hijack_ctx: *anyopaque) anyerror!void {
    const svc: *AppServices = @ptrCast(@alignCast(hijack_ctx));
    svc.notifier.register(conn) catch return;
    defer svc.notifier.unregister(conn);

    const welcome = core.respond.toJson(svc.allocator, .{
        .type = "connected",
        .data = .{ .online = svc.notifier.onlineCount() },
        .ts = svc.nowMs(),
    }) catch return;
    defer svc.allocator.free(welcome);
    conn.sendText(welcome) catch return;

    svc.notifier.broadcastEvent("presence", .{ .online = svc.notifier.onlineCount() }, svc.nowMs()) catch {};

    while (true) {
        var msg = conn.receive() catch |err| {
            if (err == error.ConnectionClosed or err == error.EndOfStream) return;
            return err;
        };
        defer msg.deinit();
        switch (msg.opcode) {
            .text, .binary => {}, // 通知通道是单向的，客户端消息只用于保活
            else => {},
        }
    }
}
