//! 认证服务：登录 / 登出 / 会话解析 / 锁定策略。
//!
//! 登录失败连续 5 次锁定 15 分钟，错误提示里带上剩余锁定时间与剩余尝试次数。

const std = @import("std");
const framework = @import("http_framework");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");
const audit_service = @import("audit_service.zig");
const actor_mod = @import("actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const errors = core.errors;
const codes = core.errors.codes;

/// 会话 cookie 名（与 examples 现有 session 示例一致）。
pub const SESSION_COOKIE: []const u8 = "sid";

pub const MAX_FAILED_ATTEMPTS: u64 = 5;
pub const LOCK_DURATION_MS: u64 = 15 * 60 * 1000;

/// 距离解锁还有多少毫秒；已过期返回 0。
pub fn remainingLockMs(now: u64, locked_until: u64) u64 {
    if (locked_until <= now) return 0;
    return locked_until - now;
}

/// 把毫秒格式化成 "14 分 30 秒" / "45 秒" 这样的人话。纯函数。
pub fn formatRemaining(allocator: std.mem.Allocator, ms: u64) ![]const u8 {
    if (ms == 0) return allocator.dupe(u8, "0 秒");
    const total_sec = @divFloor(ms + 999, 1000);
    const minutes = @divFloor(total_sec, 60);
    const seconds = @mod(total_sec, 60);
    if (minutes == 0) return std.fmt.allocPrint(allocator, "{d} 秒", .{seconds});
    if (seconds == 0) return std.fmt.allocPrint(allocator, "{d} 分钟", .{minutes});
    return std.fmt.allocPrint(allocator, "{d} 分 {d} 秒", .{ minutes, seconds });
}

/// 剩余尝试次数提示文案。
pub fn attemptMessage(allocator: std.mem.Allocator, remaining: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "用户名或密码错误，还可尝试 {d} 次", .{remaining});
}

pub fn remainingAttempts(failed: u64) u64 {
    if (failed >= MAX_FAILED_ATTEMPTS) return 0;
    return MAX_FAILED_ATTEMPTS - failed;
}

/// 登录。成功返回当前主体（并已建立会话），失败直接 `errors.fail`（调用方 `try`）。
pub fn login(svc: *AppServices, ctx: *framework.Context, res: *framework.Response, username: []const u8, password: []const u8) !Actor {
    const now = svc.nowMs();
    const user = (try svc.users.findByUsername(ctx.arena, username)) orelse {
        try audit_service.record(svc, ctx, 0, username, .{
            .module = "auth",
            .action = model.audit.actions.login_failure,
            .target_type = "user",
            .target_label = username,
            .result = "failure",
            .message = "用户不存在",
        });
        try errors.fail(ctx, errors.ApiError.unauthorized(codes.invalid_credentials, "用户名或密码错误"));
        return error.Unreachable;
    };

    // 1) 账户被禁用
    if (user.statusEnum() == .disabled) {
        try errors.fail(ctx, errors.ApiError.forbidden(codes.account_disabled, "账号已被禁用，请联系管理员"));
        return error.Unreachable;
    }

    // 2) 锁定中（未到期）→ 直接拒绝，并告知剩余时间
    if (user.statusEnum() == .locked) {
        const remain = remainingLockMs(now, user.locked_until);
        if (remain > 0) {
            const human = try formatRemaining(ctx.arena, remain);
            const msg = try std.fmt.allocPrint(ctx.arena, "账号已锁定，请在{s}后重试", .{human});
            try audit_service.record(svc, ctx, user.id, user.username, .{
                .module = "auth",
                .action = model.audit.actions.login_locked,
                .target_type = "user",
                .target_id = user.id,
                .target_label = user.username,
                .result = "failure",
                .message = msg,
            });
            try errors.fail(ctx, errors.ApiError.locked(codes.account_locked, msg).withDetails(try core.respond.toJson(ctx.arena, .{ .locked_until = user.locked_until, .remaining_ms = remain })));
            return error.Unreachable;
        }
        // 锁定期已过 → 自动解锁后继续校验口令
    }

    // 3) 校验口令
    const ok = (core.password.verify(password, user.password_hash)) catch false;
    if (!ok) {
        var updated = user;
        updated.failed_attempts += 1;
        updated.updated_at = now;

        if (updated.failed_attempts >= MAX_FAILED_ATTEMPTS) {
            updated.status = @tagName(model.user.Status.locked);
            updated.locked_until = now + LOCK_DURATION_MS;
            const human = try formatRemaining(ctx.arena, LOCK_DURATION_MS);
            const msg = try std.fmt.allocPrint(
                ctx.arena,
                "连续{d}次密码错误，账号已锁定，请在{s}后重试",
                .{ MAX_FAILED_ATTEMPTS, human },
            );
            _ = try svc.users.update(updated);
            try audit_service.record(svc, ctx, user.id, user.username, .{
                .module = "auth",
                .action = model.audit.actions.login_locked,
                .target_type = "user",
                .target_id = user.id,
                .target_label = user.username,
                .result = "failure",
                .message = msg,
            });
            try errors.fail(ctx, errors.ApiError.locked(codes.account_locked, msg).withDetails(try core.respond.toJson(ctx.arena, .{
                .locked_until = updated.locked_until,
                .remaining_ms = LOCK_DURATION_MS,
                .failed_attempts = updated.failed_attempts,
            })));
            return error.Unreachable;
        }

        _ = try svc.users.update(updated);
        const left = remainingAttempts(updated.failed_attempts);
        const msg = try attemptMessage(ctx.arena, left);
        try audit_service.record(svc, ctx, user.id, user.username, .{
            .module = "auth",
            .action = model.audit.actions.login_failure,
            .target_type = "user",
            .target_id = user.id,
            .target_label = user.username,
            .result = "failure",
            .message = msg,
        });
        try errors.fail(ctx, errors.ApiError.unauthorized(codes.invalid_credentials, msg).withDetails(try core.respond.toJson(ctx.arena, .{
            .remaining_attempts = left,
        })));
        return error.Unreachable;
    }

    // 4) 登录成功：清零失败计数、必要时自动解锁、记录最后登录时间
    var updated = user;
    updated.failed_attempts = 0;
    updated.locked_until = 0;
    updated.last_login_at = now;
    updated.updated_at = now;
    if (updated.statusEnum() != .active) updated.status = @tagName(model.user.Status.active);
    _ = try svc.users.update(updated);

    // 会话固定攻击防护：登录前先作废旧会话，再建新会话。
    const sessions = ctx.service(framework.SessionManager) orelse {
        try errors.fail(ctx, errors.ApiError.internal(codes.internal_error, "会话服务不可用"));
        return error.Unreachable;
    };
    if (ctx.request.getCookie(SESSION_COOKIE)) |old| sessions.invalidate(old);
    const sid = try sessions.getOrCreate(ctx, res);
    try sessions.setData(sid, "uid", try std.fmt.allocPrint(ctx.arena, "{d}", .{user.id}));
    try sessions.setData(sid, "username", user.username);

    const permissions = try svc.rbac.permissionsOfUser(ctx.arena, user.id);
    try audit_service.record(svc, ctx, user.id, user.username, .{
        .module = "auth",
        .action = model.audit.actions.login_success,
        .target_type = "user",
        .target_id = user.id,
        .target_label = user.username,
        .result = "success",
        .message = "登录成功",
    });

    return .{
        .id = user.id,
        .username = user.username,
        .display_name = user.display_name,
        .org_id = user.org_id,
        .status = updated.status,
        .permissions = permissions,
    };
}

pub fn logout(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = ctx.getUserData(Actor);
    if (ctx.service(framework.SessionManager)) |sessions| {
        sessions.destroyFromRequest(ctx);
    }
    _ = try res.setCookieFull(.{ .name = SESSION_COOKIE, .value = "deleted", .max_age = 0, .path = "/" });
    if (actor) |a| {
        try audit_service.record(svc, ctx, a.id, a.username, .{
            .module = "auth",
            .action = model.audit.actions.logout,
            .target_type = "user",
            .target_id = a.id,
            .target_label = a.username,
            .message = "退出登录",
        });
    }
}

/// 从会话解析当前登录主体（每次请求都重新查库，保证角色/权限变更立即生效）。
/// 返回 null 表示未登录或会话已失效。
pub fn resolve(svc: *AppServices, ctx: *framework.Context) !?*Actor {
    const sessions = ctx.service(framework.SessionManager) orelse return null;
    const sid = ctx.request.getCookie(SESSION_COOKIE) orelse return null;
    const uid_str = (try sessions.getValue(sid, "uid", ctx.arena)) orelse return null;
    const uid = std.fmt.parseInt(u64, uid_str, 10) catch return null;

    const user = (try svc.users.findById(ctx.arena, uid)) orelse return null;
    if (user.statusEnum() != .active) return null;

    const permissions = try svc.rbac.permissionsOfUser(ctx.arena, uid);
    const slot = try ctx.arena.create(Actor);
    slot.* = .{
        .id = user.id,
        .username = user.username,
        .display_name = user.display_name,
        .org_id = user.org_id,
        .status = user.status,
        .permissions = permissions,
    };
    return slot;
}

// ── 测试：锁定策略是纯逻辑 ─────────────────────────────────────────

test "remainingLockMs 已过期返回 0" {
    try std.testing.expectEqual(@as(u64, 0), remainingLockMs(200, 100));
    try std.testing.expectEqual(@as(u64, 0), remainingLockMs(100, 100));
    try std.testing.expectEqual(@as(u64, 50), remainingLockMs(100, 150));
}

test "formatRemaining 输出人话" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("0 秒", try formatRemaining(a, 0));
    try std.testing.expectEqualStrings("45 秒", try formatRemaining(a, 45_000));
    try std.testing.expectEqualStrings("1 分钟", try formatRemaining(a, 60_000));
    try std.testing.expectEqualStrings("15 分钟", try formatRemaining(a, 15 * 60 * 1000));
    try std.testing.expectEqualStrings("14 分 30 秒", try formatRemaining(a, 14 * 60 * 1000 + 30_000));
    // 向上取整：999ms 也算 1 秒
    try std.testing.expectEqualStrings("1 秒", try formatRemaining(a, 999));
}

test "remainingAttempts 递减到 0" {
    try std.testing.expectEqual(@as(u64, 5), remainingAttempts(0));
    try std.testing.expectEqual(@as(u64, 2), remainingAttempts(3));
    try std.testing.expectEqual(@as(u64, 0), remainingAttempts(5));
    try std.testing.expectEqual(@as(u64, 0), remainingAttempts(99));
}

test "attemptMessage 带剩余次数" {
    const msg = try attemptMessage(std.testing.allocator, 3);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "3") != null);
}

test {
    std.testing.refAllDecls(@This());
}
