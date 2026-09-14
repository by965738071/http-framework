//! handler —— 只做三件事：解析参数、调 service、写响应。
//!
//! 禁止直接碰 ORM / Store；响应一律经 `core.respond` 输出，保证字段稳定。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const service = @import("../service/mod.zig");

const AppServices = service.AppServices;
const Actor = service.Actor;
const errors = core.errors;

pub const auth_handler = @import("auth_handler.zig");
pub const user_handler = @import("user_handler.zig");
pub const org_handler = @import("org_handler.zig");
pub const rbac_handler = @import("rbac_handler.zig");
pub const audit_handler = @import("audit_handler.zig");
pub const approval_handler = @import("approval_handler.zig");
pub const misc_handler = @import("misc_handler.zig");

/// 把「纯函数 handler」包成单例 handler 结构体，供
/// `framework.Handler.initSingleton(ptr)` 使用（类型从 ptr 自动推导）。
///
/// 框架要求每个路由一个实现了 `handle(ctx, res)` 的类型实例，用 comptime
/// 生成可以省掉几十个手写的 wrapper struct。
pub fn wrap(comptime f: *const fn (*AppServices, *framework.Context, *framework.Response) anyerror!void) type {
    return struct {
        services: *AppServices,
        pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
            return f(self.services, ctx, res);
        }
    };
}

/// 取当前登录主体；未登录直接抛 401（调用方需要 `try`）。
pub fn requireActor(ctx: *framework.Context) !*Actor {
    return ctx.getUserData(Actor) orelse {
        try errors.fail(ctx, errors.ApiError.unauthorized(errors.codes.unauthorized, "未登录"));
        return error.Unreachable;
    };
}

/// 分页参数：`page` 从 1 开始，返回 0 基索引与每页条数。
pub fn paging(ctx: *const framework.Context) struct { page: usize, page_size: usize } {
    const page = core.util.queryInt(ctx, "page", 1);
    const size = core.util.queryInt(ctx, "page_size", 20);
    return .{
        .page = if (page == 0) 0 else page - 1,
        .page_size = @min(@max(size, 1), 200),
    };
}
