//! 鉴权中间件：会话解析 + 权限点守卫。
//!
//! 用法（顺序很重要，先 use 的先执行）：
//!   var g = try router.group("/api/v1");
//!   try g.use(Middleware.init(ErrorJson, &err_json));   // 1. 错误渲染
//!   try g.use(Middleware.init(SessionAuth, &auth_mw));  // 2. 解析登录主体
//!   { var s = try g.group(""); try s.use(Middleware.init(PermissionGuard, &guard)); ... }

const std = @import("std");
const framework = @import("http_framework");
const errors = @import("../core/errors.zig");
const respond = @import("../core/respond.zig");
const container = @import("../service/container.zig");
const auth_service = @import("../service/auth_service.zig");
const actor_mod = @import("../service/actor.zig");

const AppServices = container.AppServices;
const Actor = actor_mod.Actor;
const codes = errors.codes;

/// 解析会话 → 当前登录主体，挂到 ctx user_data 槽；未登录直接 401。
pub const SessionAuth = struct {
    services: *AppServices,

    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const actor = try auth_service.resolve(self.services, ctx) orelse {
            try errors.fail(ctx, errors.ApiError.unauthorized(codes.session_expired, "未登录或登录已失效"));
            return;
        };
        try ctx.setUserData(Actor, actor);
        try next.call(ctx, res);
    }
};

/// 可选登录：解析成功就挂 Actor，失败也放行（用于登录页/仪表盘这类接口）。
pub const OptionalAuth = struct {
    services: *AppServices,

    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        if (try auth_service.resolve(self.services, ctx)) |actor| {
            try ctx.setUserData(Actor, actor);
        }
        try next.call(ctx, res);
    }
};

/// 权限点守卫：要求当前主体持有 `permission`。
pub const PermissionGuard = struct {
    permission: []const u8,

    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const actor = ctx.getUserData(Actor) orelse {
            try errors.fail(ctx, errors.ApiError.unauthorized(codes.unauthorized, "未登录"));
            return;
        };
        if (!actor.can(self.permission)) {
            const msg = try std.fmt.allocPrint(ctx.arena, "缺少权限：{s}", .{self.permission});
            try errors.fail(ctx, errors.ApiError.forbidden(codes.permission_denied, msg).withDetails(try respond.toJson(ctx.arena, .{ .required = self.permission })));
            return;
        }
        try next.call(ctx, res);
    }
};
