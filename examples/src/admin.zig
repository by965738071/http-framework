//! Admin backend management system
//!
//! 功能：
//!   ├─ 登录/登出（Session + Cookie）
//!   ├─ 用户管理（CRUD + 角色：admin/editor/viewer）
//!   ├─ 仪表盘（统计数据 + 实时 WebSocket 通知）
//!   ├─ 系统日志（查看 + 清除）
//!   ├─ 站点设置（只读演示）
//!   └─ 前端管理界面（单页 SPA）

const std = @import("std");
const framework = @import("http_framework");

// ────────────────────────────────────────────────────────────────────────────
// 模型定义
// ────────────────────────────────────────────────────────────────────────────

pub const Role = enum { admin, editor, viewer };

pub const AdminUser = struct {
    id: u64 = 0,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8, // 简单演示：明文哈希（实际应 bcrypt/argon2）
    role: Role,
    created_at: u64 = 0,
    last_login: u64 = 0,
};

pub const SystemLog = struct {
    id: u64 = 0,
    level: []const u8,
    message: []const u8,
    ip: []const u8,
    created_at: u64,
};

// ────────────────────────────────────────────────────────────────────────────
// 服务容器（进程级单例）
// ────────────────────────────────────────────────────────────────────────────

pub const AdminServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    users: *UserModel.Store,
    logs: *LogStore,
    notifications: Notifications,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AdminServices {
        const users = try UserModel.Store.open(allocator, io, "./data/admin");
        const logs = try LogStore.open(allocator, io, "./data/admin");
        const notifications = Notifications.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .users = users,
            .logs = logs,
            .notifications = notifications,
        };
    }

    pub fn deinit(self: *AdminServices) void {
        self.notifications.deinit();
        self.users.close() catch {};
        self.logs.close() catch {};
    }
};

// ────────────────────────────────────────────────────────────────────────────
// ORM 模型
// ────────────────────────────────────────────────────────────────────────────

const OrmAdminUser = struct {
    id: u64 = 0,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    role: []const u8,
    created_at: u64 = 0,
    last_login: u64 = 0,
};

pub const UserModel = framework.orm.Model(OrmAdminUser, "users");

const OrmLog = struct {
    id: u64 = 0,
    level: []const u8,
    message: []const u8,
    ip: []const u8,
    created_at: u64,
};

pub const LogModel = framework.orm.Model(OrmLog, "logs");
pub const LogStore = LogModel.Store;

// ────────────────────────────────────────────────────────────────────────────
// 通知广播器（WebSocket 推送）
// ────────────────────────────────────────────────────────────────────────────

pub const Notifications = struct {
    allocator: std.mem.Allocator,
    connections: []*framework.WebSocket,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator) Notifications {
        const buf = allocator.alloc(*framework.WebSocket, 16) catch unreachable;
        return .{
            .allocator = allocator,
            // connections.len 跟踪活跃连接数（初始 0），capacity 是缓冲容量。
            .connections = buf[0..0],
            .capacity = 16,
        };
    }

    pub fn deinit(self: *Notifications) void {
        // 释放整个底层缓冲（而非当前 shrink 后的 slice）。
        self.allocator.free(self.connections.ptr[0..self.capacity]);
    }

    /// 广播消息到所有 WebSocket 连接
    pub fn broadcast(self: *Notifications, msg: []const u8) !void {
        var i: usize = 0;
        while (i < self.connections.len) {
            const ws = self.connections[i];
            // 写入失败时移除
            ws.sendText(msg) catch |err| {
                if (err == error.ConnectionReset) {
                    // swap with last and shrink
                    const last = self.connections.len - 1;
                    if (i != last) {
                        self.connections[i] = self.connections[last];
                    }
                    self.connections.len = last;
                    continue;
                } else {
                    return err;
                }
            };
            i += 1;
        }
    }

    /// 注册客户端连接
    pub fn register(self: *Notifications, ws: *framework.WebSocket) void {
        if (self.connections.len < self.capacity) {
            self.connections[self.connections.len] = ws;
            self.connections.len += 1;
        }
    }

    /// 注销客户端连接
    pub fn unregister(self: *Notifications, ws: *framework.WebSocket) void {
        var i: usize = 0;
        while (i < self.connections.len) {
            if (self.connections[i] == ws) {
                // swap with last and shrink
                const last = self.connections.len - 1;
                if (i != last) {
                    self.connections[i] = self.connections[last];
                }
                self.connections.len = last;
                continue;
            } else {
                i += 1;
            }
        }
    }
};

// ────────────────────────────────────────────────────────────────────────────
// 鉴权中间件
// ────────────────────────────────────────────────────────────────────────────

// 静态中间件实例（单线程服务器安全）
var auth_mw_instance: RequireAuthMiddleware = undefined;

pub fn requireAuth(services: *AdminServices) framework.Middleware {
    auth_mw_instance.services = services;
    return framework.Middleware.init(RequireAuthMiddleware, &auth_mw_instance);
}

pub const RequireAuthMiddleware = struct {
    services: *AdminServices,

    pub fn process(self: *RequireAuthMiddleware, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const sessions = ctx.service(framework.SessionManager) orelse {
            try ctx.failWith(res, framework.AppError.internal("session service unavailable"));
            return;
        };

        const session_id = ctx.request.getCookie("sid") orelse {
            try ctx.failWith(res, framework.AppError.unauthorized("not logged in"));
            return;
        };

        const username = sessions.getValue(session_id, "username", ctx.arena) catch null;
        if (username == null) {
            try ctx.failWith(res, framework.AppError.unauthorized("session expired"));
            return;
        }

        // 验证用户存在
        const store = self.services.users;
        const all_users = try store.all();
        defer self.services.allocator.free(all_users);

        var found = false;
        for (all_users) |u| {
            if (std.mem.eql(u8, u.username, username.?)) {
                found = true;
                break;
            }
        }

        if (!found) {
            try ctx.failWith(res, framework.AppError.unauthorized("user not found"));
            return;
        }

        try next.call(ctx, res);
    }
};

pub fn requireRole(role: Role, services: *AdminServices) framework.Middleware {
    return framework.Middleware.init(RequireRoleMiddleware, .{ .role = role, .services = services });
}

pub const RequireRoleMiddleware = struct {
    role: Role,
    services: *AdminServices,

    pub fn process(self: *RequireRoleMiddleware, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const sessions = ctx.service(framework.SessionManager) orelse {
            try ctx.failWith(res, framework.AppError.internal("session unavailable"));
            return;
        };

        const session_id = ctx.request.getCookie("sid") orelse {
            try ctx.failWith(res, framework.AppError.unauthorized("not logged in"));
            return;
        };

        const username = sessions.getValue(session_id, "username", ctx.arena) catch null orelse {
            try ctx.failWith(res, framework.AppError.unauthorized("session expired"));
            return;
        };

        // 验证角色
        const store = self.services.users;
        const all_users = try store.all();
        defer self.services.allocator.free(all_users);

        for (all_users) |u| {
            if (std.mem.eql(u8, u.username, username)) {
                const user_role: Role = if (std.mem.eql(u8, u.role, "admin")) .admin else if (std.mem.eql(u8, u.role, "editor")) .editor else .viewer;
                const required = self.role;
                // admin 可以访问所有，editor 可以访问 admin+editor，viewer 只能访问 viewer
                const can_access = switch (required) {
                    .admin => user_role == .admin,
                    .editor => user_role == .admin or user_role == .editor,
                    .viewer => true,
                };
                if (!can_access) {
                    try ctx.failWith(res, framework.AppError.forbidden("insufficient permissions"));
                    return;
                }
                break;
            }
        }

        try next.call(ctx, res);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Handlers
// ────────────────────────────────────────────────────────────────────────────

/// GET /admin/login — 返回登录页面
pub fn loginPageHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    std.log.info("loginPageHandler: starting", .{});

    // 检查是否已登录
    const sessions = ctx.service(framework.SessionManager) orelse {
        std.log.err("loginPageHandler: session service not found", .{});
        try ctx.failWith(res, framework.AppError.internal("session unavailable"));
        return;
    };
    std.log.info("loginPageHandler: got session service", .{});

    const session_id = ctx.request.getCookie("sid");
    if (session_id != null) {
        std.log.info("loginPageHandler: found session cookie", .{});
        const username = sessions.getValue(session_id.?, "username", ctx.arena) catch null;
        if (username != null) {
            std.log.info("loginPageHandler: user is logged in, redirecting", .{});
            try res.redirectStatus("/admin/dashboard", .see_other);
            return;
        }
    }

    std.log.info("loginPageHandler: reading HTML file", .{});
    const html = try std.Io.Dir.cwd().readFileAlloc(services.io, "./public/admin/index.html", services.allocator, .limited(10 * 1024 * 1024));
    defer services.allocator.free(html);
    std.log.info("loginPageHandler: sending HTML response", .{});
    try res.html(html);
    std.log.info("loginPageHandler: done", .{});
}

/// POST /admin/login — 处理登录
pub fn loginApiHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    // 简单解析：支持 JSON 和 form-urlencoded（经 ctx.formDecoded 读取并缓冲 body）
    const username = (try ctx.formDecoded("username", 1 << 16)) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("username required"));
        return;
    };
    const password = (try ctx.formDecoded("password", 1 << 16)) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("password required"));
        return;
    };

    const store = services.users;
    const users = try store.all();
    defer services.allocator.free(users);

    var user_found = false;
    var role: Role = .viewer;
    for (users) |u| {
        if (std.mem.eql(u8, u.username, username) and std.mem.eql(u8, u.password_hash, password)) {
            user_found = true;
            const role_str = u.role;
            if (std.mem.eql(u8, role_str, "admin")) {
                role = .admin;
            } else if (std.mem.eql(u8, role_str, "editor")) {
                role = .editor;
            } else {
                role = .viewer;
            }
            break;
        }
    }

    if (!user_found) {
        try ctx.failWith(res, framework.AppError.unauthorized("invalid credentials"));
        return;
    }

    // 创建 session
    const sessions = ctx.service(framework.SessionManager) orelse {
        try ctx.failWith(res, framework.AppError.internal("session unavailable"));
        return;
    };
    const sid = try sessions.getOrCreate(ctx, res);
    try sessions.setData(sid, "username", username);
    try sessions.setData(sid, "role", @tagName(role));

    // 更新 last_login
    for (users) |u| {
        if (std.mem.eql(u8, u.username, username)) {
            var updated = u;
            updated.last_login = @as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(services.io, .real).nanoseconds, 1_000_000)));
            if (try store.updateById(u.id, updated)) {}
            try store.flush();
            break;
        }
    }

    try res.json(.{ .ok = true, .username = username, .role = @tagName(role) });
}

/// POST /admin/logout — 登出
pub fn logoutHandler(_: *framework.Context, res: *framework.Response, _: *AdminServices) !void {
    _ = try res.setCookieFull(.{
        .name = "sid",
        .value = "deleted",
        .max_age = 0,
    });
    try res.json(.{ .ok = true });
}

/// GET /admin/dashboard — 仪表盘数据
pub fn dashboardHandler(_: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const users = try services.users.all();
    defer services.allocator.free(users);

    var admin_count: u64 = 0;
    var editor_count: u64 = 0;
    var viewer_count: u64 = 0;
    for (users) |u| {
        const role_str = u.role;
        if (std.mem.eql(u8, role_str, "admin")) {
            admin_count += 1;
        } else if (std.mem.eql(u8, role_str, "editor")) {
            editor_count += 1;
        } else {
            viewer_count += 1;
        }
    }

    const logs = try services.logs.all();
    defer services.allocator.free(logs);

    try res.json(.{
        .total_users = users.len,
        .admins = admin_count,
        .editors = editor_count,
        .viewers = viewer_count,
        .total_logs = logs.len,
        .uptime_seconds = 0, // 暂不实现
    });
}

/// GET /admin/users — 用户列表
pub fn userListHandler(_: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const users = try services.users.all();
    defer services.allocator.free(users);
    try res.json(.{ .total = users.len, .users = users });
}

/// POST /admin/users — 创建用户
pub fn userCreateHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const username = (ctx.formDecoded("username", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("username required"));
        return;
    };
    const email = (try ctx.formDecoded("email", 1 << 16)) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("email required"));
        return;
    };
    const password = (try ctx.formDecoded("password", 1 << 16)) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("password required"));
        return;
    };
    const role_str = (try ctx.formDecoded("role", 1 << 16)) orelse "viewer";

    const id = services.users.insert(.{
        .id = 0,
        .username = username,
        .email = email,
        .password_hash = password,
        .role = role_str,
        .created_at = @as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(services.io, .real).nanoseconds, 1_000_000))),
    }) catch |err| {
        if (err == error.UniqueViolation) {
            try ctx.failWith(res, framework.AppError.conflict("username already exists"));
            return;
        }
        return err;
    };
    try services.users.flush();

    try res.statusCode(.created).json(.{ .id = id, .username = username, .email = email, .role = role_str });
}

/// GET /admin/users/:id — 获取单个用户
pub fn userGetHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const id = parseId(ctx, res) orelse return;
    const user = try services.users.findById(id) orelse {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    };
    try res.json(user);
}

/// PUT /admin/users/:id — 更新用户
pub fn userUpdateHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const id = parseId(ctx, res) orelse return;

    const username = (ctx.formDecoded("username", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse "";
    const email = (try ctx.formDecoded("email", 1 << 16)) orelse "";
    const role = (try ctx.formDecoded("role", 1 << 16)) orelse "";

    const existing = try services.users.findById(id) orelse {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    };

    const updated = try services.users.updateById(id, .{
        .id = id,
        .username = if (username.len > 0) username else existing.username,
        .email = if (email.len > 0) email else existing.email,
        .password_hash = existing.password_hash,
        .role = if (role.len > 0) role else existing.role,
        .created_at = existing.created_at,
        .last_login = existing.last_login,
    });

    if (!updated) {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    }
    try services.users.flush();
    try res.json(.{ .ok = true, .id = id });
}

/// DELETE /admin/users/:id — 删除用户
pub fn userDeleteHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const id = parseId(ctx, res) orelse return;
    const deleted = try services.users.deleteById(id);
    if (!deleted) {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    }
    try services.users.flush();
    try res.json(.{ .ok = true, .deleted = id });
}

/// GET /admin/logs — 日志列表
pub fn logListHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const limit_str = ctx.query("limit") orelse "50";
    const limit = std.fmt.parseInt(u64, limit_str, 10) catch 50;
    const offset_str = ctx.query("offset") orelse "0";
    const offset = std.fmt.parseInt(u64, offset_str, 10) catch 0;

    const logs = try services.logs.all();
    defer services.allocator.free(logs);

    const start = if (offset < logs.len) offset else logs.len;
    const end = if (offset + limit < logs.len) offset + limit else logs.len;
    const slice = logs[start..end];

    try res.json(.{ .total = logs.len, .offset = offset, .limit = limit, .logs = slice });
}

/// POST /admin/logs/clear — 清除日志
pub fn logClearHandler(_: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    try services.logs.truncate();
    try services.logs.flush();
    try res.json(.{ .ok = true, .cleared = true });
}

/// GET /admin/settings — 站点设置（只读）
pub fn settingsHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    _ = ctx;
    _ = services;
    try res.json(.{
        .site_name = "Admin Panel",
        .site_url = "http://127.0.0.1:9000",
        .version = "1.0.0",
        .maintenance_mode = false,
    });
}

/// GET /admin/me — 当前登录用户信息
pub fn meHandler(ctx: *framework.Context, res: *framework.Response, services: *AdminServices) !void {
    const sessions = ctx.service(framework.SessionManager) orelse {
        try ctx.failWith(res, framework.AppError.unauthorized("not logged in"));
        return;
    };
    const session_id = ctx.request.getCookie("sid") orelse {
        try ctx.failWith(res, framework.AppError.unauthorized("no session cookie"));
        return;
    };

    const username = sessions.getValue(session_id, "username", ctx.arena) catch null orelse {
        try ctx.failWith(res, framework.AppError.unauthorized("session expired"));
        return;
    };
    const role_str = sessions.getValue(session_id, "role", ctx.arena) catch null orelse "viewer";

    const store = services.users;
    const users = try store.all();
    defer services.allocator.free(users);

    var found_user: ?OrmAdminUser = null;
    for (users) |u| {
        if (std.mem.eql(u8, u.username, username)) {
            found_user = u;
            break;
        }
    }

    try res.json(.{
        .username = username,
        .role = role_str,
        .user = found_user,
    });
}

// ────────────────────────────────────────────────────────────────────────────
// Handler wrappers (capture services pointer for routing)
// ────────────────────────────────────────────────────────────────────────────

// 登录页 handler
pub const LoginPageHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return loginPageHandler(ctx, res, self.services);
    }
};

// 登录 API handler
pub const LoginApiHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return loginApiHandler(ctx, res, self.services);
    }
};

// 登出 handler
pub const LogoutHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return logoutHandler(ctx, res, self.services);
    }
};

// 仪表盘 handler
pub const DashboardHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return dashboardHandler(ctx, res, self.services);
    }
};

// 用户列表 handler
pub const UserListHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userListHandler(ctx, res, self.services);
    }
};

// 创建用户 handler
pub const UserCreateHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userCreateHandler(ctx, res, self.services);
    }
};

// 获取用户 handler
pub const UserGetHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userGetHandler(ctx, res, self.services);
    }
};

// 更新用户 handler
pub const UserUpdateHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userUpdateHandler(ctx, res, self.services);
    }
};

// 删除用户 handler
pub const UserDeleteHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userDeleteHandler(ctx, res, self.services);
    }
};

// 日志列表 handler
pub const LogListHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return logListHandler(ctx, res, self.services);
    }
};

// 清除日志 handler
pub const LogClearHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return logClearHandler(ctx, res, self.services);
    }
};

// 设置 handler
pub const SettingsHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return settingsHandler(ctx, res, self.services);
    }
};

// 当前用户 handler
pub const MeHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return meHandler(ctx, res, self.services);
    }
};

// WebSocket 通知 handler
pub const WsNotificationsHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return wsNotificationsHandler(ctx, res, self.services);
    }
};

pub fn wsNotificationsHandler(ctx: *framework.Context, res: *framework.Response, _: *AdminServices) !void {
    const upgraded = framework.wsUpgrade(ctx, res, @ptrCast(res), wsNotifications) catch |err| {
        try ctx.failWith(res, framework.AppError.badRequest("websocket upgrade failed"));
        return err;
    };
    if (!upgraded) {
        if (!res.sent) try res.statusCode(.bad_request).text("expected a WebSocket upgrade request");
        return;
    }
}

fn wsNotifications(ws: *framework.WebSocket, raw: *anyopaque) anyerror!void {
    const services: *AdminServices = @ptrCast(@alignCast(raw));

    // 注册连接
    services.notifications.register(ws);
    defer services.notifications.unregister(ws);

    while (true) {
        var msg = ws.receive() catch |err| {
            if (err == error.ConnectionClosed or err == error.EndOfStream) return;
            return err;
        };
        defer msg.deinit();
        switch (msg.opcode) {
            .text => {
                // 客户端发 ping → 回复 pong
                if (std.mem.eql(u8, msg.payload, "ping")) {
                    try ws.sendText("pong");
                }
            },
            else => {},
        }
    }
}

// ────────────────────────────────────────────────────────────────────────────
// 辅助函数
// ────────────────────────────────────────────────────────────────────────────

fn parseId(ctx: *framework.Context, res: *framework.Response) ?u64 {
    const id_str = ctx.param("id") orelse {
        ctx.failWith(res, framework.AppError.badRequest("missing :id")) catch {};
        return null;
    };
    return std.fmt.parseInt(u64, id_str, 10) catch {
        ctx.failWith(res, framework.AppError.badRequest("id must be an integer")) catch {};
        return null;
    };
}

// ────────────────────────────────────────────────────────────────────────────
// 测试
// ────────────────────────────────────────────────────────────────────────────

test "admin: Role enum" {
    try std.testing.expectEqual(Role.admin, .admin);
    try std.testing.expectEqual(Role.editor, .editor);
    try std.testing.expectEqual(Role.viewer, .viewer);
}

test "admin: Notifications init/deinit" {
    const alloc = std.testing.allocator;
    var notifications = Notifications.init(alloc);
    defer notifications.deinit();
    try std.testing.expectEqual(@as(usize, 0), notifications.connections.len);
}
