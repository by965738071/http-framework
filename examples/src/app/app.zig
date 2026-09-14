//! app —— 分层后台管理后端（挂载在 /api/v1）。
//!
//! 分层约定（单向依赖，禁止反向）：
//!
//!   handler  →  service  →  repo  →  ORM store
//!      │           │
//!      └─── middleware（错误渲染 / 鉴权 / 权限守卫）
//!
//! - handler：只做参数解析 + 调 service + 写响应，**不碰 ORM / Store**
//! - service：业务规则、校验、状态机、写审计日志、发实时通知
//! - repo：只做 ORM 查询封装
//! - model：ORM 行结构 + 领域枚举 / 状态机 / 视图结构 / 请求 DTO
//! - core：与业务无关的纯逻辑（错误、响应封装、diff、校验、口令哈希、广播器）

const std = @import("std");
const framework = @import("http_framework");

pub const core = @import("core/mod.zig");
pub const model = @import("model/mod.zig");
pub const repo = @import("repo/mod.zig");
pub const service = @import("service/mod.zig");
pub const handler = @import("handler/mod.zig");
pub const middleware = @import("middleware/mod.zig");

pub const AppServices = service.AppServices;

/// 应用运行时：持有服务容器、中间件实例、handler 实例。
///
/// 框架的两个所有权约束决定了它必须存在：
/// 1. `Handler.initSingleton` / `Middleware.init` 存的都是**裸指针**，框架不接管
///    生命周期，实例必须活到 `router.deinit()` 之后；
/// 2. 没有 `deinit` 的中间件类型不会被 Router 释放，得自己收。
/// 所以实例统一由 App 分配并登记，在 `deinit` 里释放。
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    services: *AppServices,

    error_json: middleware.ErrorJson,
    session_auth: middleware.SessionAuth,
    optional_auth: middleware.OptionalAuth,

    owned: std.ArrayList(Owned),
    guards: std.ArrayList(*middleware.PermissionGuard),

    const Owned = struct {
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*App {
        const services = try AppServices.init(allocator, io, data_dir);
        errdefer services.deinit();

        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .services = services,
            .error_json = .{},
            .session_auth = .{ .services = services },
            .optional_auth = .{ .services = services },
            .owned = .empty,
            .guards = .empty,
        };
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.owned.items) |o| o.destroy(o.ptr, self.allocator);
        self.owned.deinit(self.allocator);
        for (self.guards.items) |g| self.allocator.destroy(g);
        self.guards.deinit(self.allocator);
        self.services.deinit();
        self.allocator.destroy(self);
    }

    /// 生成一个持有 `*AppServices` 的单例 handler。
    fn makeHandler(self: *App, comptime f: anytype) !framework.Handler {
        const T = handler.wrap(f);
        const ptr = try self.allocator.create(T);
        ptr.* = .{ .services = self.services };
        try self.owned.append(self.allocator, .{
            .ptr = ptr,
            .destroy = struct {
                fn destroy(any: *anyopaque, allocator: std.mem.Allocator) void {
                    const typed: *T = @ptrCast(@alignCast(any));
                    allocator.destroy(typed);
                }
            }.destroy,
        });
        return framework.Handler.initSingleton(ptr);
    }

    /// 生成一个权限点守卫中间件实例。
    fn makeGuard(self: *App, permission: []const u8) !framework.Middleware {
        const ptr = try self.allocator.create(middleware.PermissionGuard);
        ptr.* = .{ .permission = permission };
        try self.guards.append(self.allocator, ptr);
        return framework.Middleware.init(middleware.PermissionGuard, ptr);
    }

    /// 注册路由；`permission` 非 null 时自动套一层权限守卫。
    ///
    /// 框架没有「按路由声明元数据」的机制，权限只能靠**每路由建一个子组**
    /// 挂中间件来实现（组级 `use` 只对其后注册的路由生效，且先 use 才生效）。
    fn route(
        self: *App,
        g: *framework.RouteGroup,
        method: std.http.Method,
        path: []const u8,
        permission: ?[]const u8,
        comptime f: anytype,
    ) !void {
        if (permission) |perm| {
            var sub = try g.group("");
            try sub.use(try self.makeGuard(perm));
            try sub.route(method, path, try self.makeHandler(f));
        } else {
            try g.route(method, path, try self.makeHandler(f));
        }
    }

    /// 挂载全部业务路由到 /api/v1。
    pub fn mount(self: *App, router: *framework.Router) !void {
        var g = try router.group("/api/v1");

        // 业务错误渲染必须挂在组内最外层：core.errors.fail 抛出的
        // error.ApiFailure 要是漏出去，会被全局 ErrorRenderer 兜底成 500 纯文本。
        try g.use(framework.Middleware.init(middleware.ErrorJson, &self.error_json));

        // ── 公开路由 ────────────────────────────────────────────
        try self.route(&g, .GET, "/health", null, handler.misc_handler.health);
        try self.route(&g, .POST, "/auth/login", null, handler.auth_handler.login);

        // ── 需要登录 ────────────────────────────────────────────
        var auth = try g.group("");
        try auth.use(framework.Middleware.init(middleware.SessionAuth, &self.session_auth));

        try self.route(&auth, .POST, "/auth/logout", null, handler.auth_handler.logout);
        try self.route(&auth, .GET, "/auth/me", null, handler.auth_handler.me);
        try self.route(&auth, .GET, "/auth/permissions", null, handler.auth_handler.permissions);
        try self.route(&auth, .GET, "/dashboard/stats", null, handler.misc_handler.dashboard);
        try self.route(&auth, .GET, "/ws", null, handler.misc_handler.ws);

        // ── 用户 ────────────────────────────────────────────────
        try self.route(&auth, .GET, "/users", "user:view", handler.user_handler.list);
        try self.route(&auth, .POST, "/users", "user:create", handler.user_handler.create);
        try self.route(&auth, .GET, "/users/:id", "user:view", handler.user_handler.get);
        try self.route(&auth, .PUT, "/users/:id", "user:update", handler.user_handler.update);
        try self.route(&auth, .DELETE, "/users/:id", "user:delete", handler.user_handler.remove);
        try self.route(&auth, .PUT, "/users/:id/status", "user:update", handler.user_handler.changeStatus);
        try self.route(&auth, .POST, "/users/:id/unlock", "user:unlock", handler.user_handler.unlock);
        try self.route(&auth, .POST, "/users/:id/reset-password", "user:reset-password", handler.user_handler.resetPassword);
        try self.route(&auth, .PUT, "/users/:id/roles", "user:assign-role", handler.user_handler.assignRoles);

        // ── 组织 ────────────────────────────────────────────────
        try self.route(&auth, .GET, "/orgs/tree", "org:view", handler.org_handler.tree);
        try self.route(&auth, .GET, "/orgs", "org:view", handler.org_handler.list);
        try self.route(&auth, .POST, "/orgs", "org:create", handler.org_handler.create);
        try self.route(&auth, .GET, "/orgs/:id", "org:view", handler.org_handler.get);
        try self.route(&auth, .PUT, "/orgs/:id", "org:update", handler.org_handler.update);
        try self.route(&auth, .DELETE, "/orgs/:id", "org:delete", handler.org_handler.remove);
        try self.route(&auth, .POST, "/orgs/:id/move", "org:move", handler.org_handler.move);
        try self.route(&auth, .GET, "/orgs/:id/members", "org:view", handler.org_handler.members);

        // ── 角色与权限点 ────────────────────────────────────────
        try self.route(&auth, .GET, "/roles", "role:view", handler.rbac_handler.listRoles);
        try self.route(&auth, .POST, "/roles", "role:create", handler.rbac_handler.createRole);
        try self.route(&auth, .PUT, "/roles/:id", "role:update", handler.rbac_handler.updateRole);
        try self.route(&auth, .DELETE, "/roles/:id", "role:delete", handler.rbac_handler.deleteRole);
        try self.route(&auth, .PUT, "/roles/:id/permissions", "role:assign", handler.rbac_handler.assignPermissions);
        try self.route(&auth, .GET, "/permissions", "role:view", handler.rbac_handler.listPermissions);
        try self.route(&auth, .GET, "/permissions/groups", "role:view", handler.rbac_handler.permissionGroups);

        // ── 审计日志 ────────────────────────────────────────────
        try self.route(&auth, .GET, "/logs", "log:view", handler.audit_handler.list);
        try self.route(&auth, .GET, "/logs/export", "log:export", handler.audit_handler.exportCsv);
        try self.route(&auth, .POST, "/logs/purge", "log:purge", handler.audit_handler.purge);

        // ── 审批流 ──────────────────────────────────────────────
        try self.route(&auth, .GET, "/approvals", "approval:view", handler.approval_handler.list);
        try self.route(&auth, .POST, "/approvals", "approval:create", handler.approval_handler.create);
        try self.route(&auth, .GET, "/approvals/:id", "approval:view", handler.approval_handler.get);
        try self.route(&auth, .POST, "/approvals/:id/review", "approval:review", handler.approval_handler.review);

        // catch-all 兜底：让 /api/v1 下拼错的 URL 也拿到业务契约的 JSON 错误体。
        // 必须是组内最后一个注册（catch-all 只能位于最后一段）。
        //
        // 框架修了 F-12 的一半：404/405 现在会走最长前缀组的中间件链，但**响应体
        // 格式没变**——`methodNotAllowedHandler` 直接写纯文本，组里的 ErrorJson
        // 只在有 error 抛出时才介入，拦不住它。实测（2026-09-11）：
        //   - 保留本条：GET /api/v1/nope → 404 {"code":"NOT_FOUND","message":"接口不存在"}
        //   - 删掉本条：GET /api/v1/nope → 404 {"error_code":"not_found",...}（全局
        //     notFoundHandler 的格式，字段名是 error_code，不是契约里的 code）
        //     DELETE /api/v1/health → 405 纯文本 "Method Not Allowed"（两种情况都一样）
        // 所以删掉它既没修好 405，又把 404 的字段名从 code 换成了 error_code，
        // 前端读 data.code 会拿到 undefined。等框架补上「按组定制 404/405 响应体」
        // 再删（见 examples/FRICTION.md F-12）。
        try self.route(&g, .GET, "/*", null, handler.misc_handler.notFound);
    }
};

comptime {
    _ = @import("core/diff.zig");
    _ = @import("model/org.zig");
    _ = @import("service/seed.zig");
    _ = @import("service/integration_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}
