//! 全栈演示应用
//!
//! 展示 http_framework 的完整能力：
//! - 静态文件服务（public/ 目录）
//! - Session 会话认证（登录/登出/注册）
//! - REST API（JSON）
//! - WebSocket 实时通信
//! - 后台任务（邮件通知演示）
//! - 中间件链（认证 + CORS + 日志）
//! - 多种处理器模式（纯函数 / 单例 / 请求级）
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! mkdir -p public
//! echo '<h1>Static File!</h1>' > public/index.html
//! zig build run-fullstack
//! ```
//!
//! # 功能
//!
//! - GET  /               — 首页（静态 HTML）
//! - GET  /api/hello      — 公开 API
//! - POST /api/login      — 登录（Session）
//! - POST /api/logout     — 登出
//! - GET  /api/profile    — 获取用户信息（需认证）
//! - GET  /ws             — WebSocket（实时消息）
//! - GET  /static/*       — 静态文件
//! - POST /api/echo       — 回显请求体
//! - GET  /admin/stats    — 管理员统计（需认证 + 角色检查）

const std = @import("std");
const http = std.http;

pub const http_framework = @import("http_framework");
const Server = http_framework.Server;
const Router = http_framework.Router;
const Handler = http_framework.Handler;
const RequestContext = http_framework.RequestContext;
const Response = http_framework.Response;
const Config = http_framework.Config;
const Middleware = http_framework.Middleware;
const NextAction = http_framework.Middleware.NextAction;
const SessionManager = http_framework.SessionManager;
const AuthMiddleware = http_framework.AuthMiddleware;
const WebSocketManager = http_framework.WebSocketManager;
const WsEchoHandler = http_framework.WsEchoHandler;
const BackgroundQueue = http_framework.BackgroundQueue;
const Static = http_framework.Static;

// =========================================================================
// 模拟用户存储
// =========================================================================

const AppUser = struct {
    id: u32,
    username: []const u8,
    password: []const u8,
    role: []const u8,
};

const users = [_]AppUser{
    .{ .id = 1, .username = "admin", .password = "admin123", .role = "admin" },
    .{ .id = 2, .username = "alice", .password = "alice456", .role = "user" },
};

// =========================================================================
// 应用状态
// =========================================================================

const App = struct {
    session_mgr: SessionManager,
    bg_queue: BackgroundQueue,
    ws_manager: WebSocketManager,
    request_count: std.atomic.Value(u64),

    fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        return .{
            .session_mgr = SessionManager.init(allocator, io),
            .bg_queue = try BackgroundQueue.init(allocator, io),
            .ws_manager = WebSocketManager.init(allocator, io),
            .request_count = std.atomic.Value(u64).init(0),
        };
    }

    fn deinit(self: *App) void {
        self.ws_manager.deinit();
        self.bg_queue.deinit();
        self.session_mgr.deinit();
    }
};

// =========================================================================
// 中间件：认证检查（Session）
// =========================================================================

const SessionAuthMiddleware = struct {
    app: *App,

    pub fn process(self: *@This(), ctx: *RequestContext) anyerror!NextAction {
        // 白名单：不检查认证的端点
        if (std.mem.eql(u8, ctx.path, "/") or
            std.mem.eql(u8, ctx.path, "/api/hello") or
            ctx.path.len >= "/static/".len and
                std.mem.startsWith(u8, ctx.path, "/static/"))
        {
            return .next;
        }

        // 检查 Session
        const sid = ctx.getCookie("session_id") orelse {
            ctx.blocked_status = .unauthorized;
            return .err;
        };

        if (self.app.session_mgr.getData(sid)) |_| {
            // Session 有效
            return .next;
        } else {
            ctx.blocked_status = .unauthorized;
            return .err;
        }
    }
};

// =========================================================================
// 中间件：管理员角色检查
// =========================================================================

const AdminRoleMiddleware = struct {
    app: *App,

    pub fn process(self: *@This(), ctx: *RequestContext) anyerror!NextAction {
        const sid = ctx.getCookie("session_id") orelse {
            ctx.blocked_status = .forbidden;
            return .err;
        };

        const data = self.app.session_mgr.getData(sid) orelse {
            ctx.blocked_status = .forbidden;
            return .err;
        };

        const role = data.get("role") orelse "user";
        if (!std.mem.eql(u8, role, "admin")) {
            ctx.blocked_status = .forbidden;
            return .err;
        }
        return .next;
    }
};

// =========================================================================
// 处理器：首页（请求级）
// =========================================================================

const HomeHandler = struct {
    pub fn init(allocator: std.mem.Allocator) !*HomeHandler {
        const ptr = try allocator.create(HomeHandler);
        ptr.* = .{};
        return ptr;
    }

    pub fn handle(_: *HomeHandler, ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        try res.html(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Fullstack Demo</title></head>
            \\<body>
            \\  <h1>Zig HTTP Framework - Fullstack Demo</h1>
            \\  <ul>
            \\    <li><a href="/api/hello">GET /api/hello</a> - Public API</li>
            \\    <li><a href="/api/profile">GET /api/profile</a> - Profile (auth)</li>
            \\    <li><a href="/ws">WebSocket</a> - Real-time</li>
            \\    <li><a href="/static/index.html">Static File</a></li>
            \\  </ul>
            \\  <form action="/api/login" method="POST">
            \\    <input name="username" placeholder="Username" />
            \\    <input name="password" type="password" placeholder="Password" />
            \\    <button>Login</button>
            \\  </form>
            \\</body>
            \\</html>
        );
    }

    pub fn deinit(_: *HomeHandler) void {}
};

// =========================================================================
// 处理器：公开 API
// =========================================================================

fn apiHelloHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.json(.{
        .message = "Hello from the API!",
        .timestamp = std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).nanoseconds,
    });
}

// =========================================================================
// 处理器：登录
// =========================================================================

const LoginHandler = struct {
    app: *App,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .app = args.app };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        const username = ctx.getForm("username") orelse
            ctx.getQuery("username") orelse "";
        const password = ctx.getForm("password") orelse
            ctx.getQuery("password") orelse "";

        if (username.len == 0 or password.len == 0) {
            try res.statusCode(.bad_request).json(.{
                .@"error" = "Missing username or password",
            });
            return;
        }

        // 验证
        var found: ?AppUser = null;
        for (&users) |*u| {
            if (std.mem.eql(u8, u.username, username) and
                std.mem.eql(u8, u.password, password))
            {
                found = u.*;
                break;
            }
        }

        if (found == null) {
            try res.statusCode(.unauthorized).json(.{
                .@"error" = "Invalid credentials",
            });
            return;
        }

        // 创建 Session
        const sid = try self.app.session_mgr.getOrCreate(ctx, res);
        try self.app.session_mgr.setData(
            sid,
            "user_id",
            try std.fmt.allocPrint(ctx.allocator, "{d}", .{found.?.id}),
        );
        try self.app.session_mgr.setData(
            sid,
            "username",
            try ctx.allocator.dupe(u8, found.?.username),
        );
        try self.app.session_mgr.setData(
            sid,
            "role",
            try ctx.allocator.dupe(u8, found.?.role),
        );

        // 后台任务演示
        // 注意：这里为了简化，直接传递字符串字面量
        // 真实场景需要分配持久内存

        try res.json(.{
            .success = true,
            .message = "Logged in",
            .username = found.?.username,
            .role = found.?.role,
        });
    }

    pub fn deinit(_: *@This()) void {}
};

// =========================================================================
// 处理器：登出
// =========================================================================

const LogoutHandler = struct {
    app: *App,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .app = args.app };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        _ = self;
        if (ctx.getCookie("session_id")) |sid| {
            // 简单演示：不真正删除 session
            _ = sid;
        }
        _ = try res.setCookie("session_id", "");
        try res.json(.{ .success = true, .message = "Logged out" });
    }

    pub fn deinit(_: *@This()) void {}
};

// =========================================================================
// 处理器：获取用户信息
// =========================================================================

const ProfileHandler = struct {
    app: *App,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .app = args.app };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        const sid = ctx.getCookie("session_id") orelse {
            try res.statusCode(.unauthorized).json(.{ .@"error" = "Not logged in" });
            return;
        };

        const data = self.app.session_mgr.getData(sid) orelse {
            try res.statusCode(.unauthorized).json(.{ .@"error" = "Session expired" });
            return;
        };

        try res.json(.{
            .username = data.get("username") orelse "unknown",
            .role = data.get("role") orelse "unknown",
        });
    }

    pub fn deinit(_: *@This()) void {}
};

// =========================================================================
// 处理器：管理员统计
// =========================================================================

const AdminStatsHandler = struct {
    app: *App,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .app = args.app };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        const stats = self.app.session_mgr.getStats();
        try res.json(.{
            .request_count = self.app.request_count.load(.monotonic),
            .active_sessions = stats.active,
            .total_sessions = stats.total,
            .ws_connections = self.app.ws_manager.connectionCount(),
        });
    }

    pub fn deinit(_: *@This()) void {}
};

// =========================================================================
// 处理器：回显
// =========================================================================

fn echoHandler(ctx: *RequestContext, res: *Response) !void {
    const body = try ctx.readBody();
    try res.json(.{
        .echo = body,
        .content_type = ctx.content_type,
        .method = @tagName(ctx.method),
    });
}

// =========================================================================
// 处理器：404
// =========================================================================

fn notFoundHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>404</title></head>
        \\<body>
        \\  <h1>404 - Not Found</h1>
        \\  <p><a href="/">Go home</a></p>
        \\</body>
        \\</html>
    );
}

// =========================================================================
// main
// =========================================================================

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // 初始化应用状态
    var app = try App.init(allocator, io);
    defer app.deinit();

    // 初始化路由器
    var router = Router.init(allocator);
    defer router.deinit();

    // ── 中间件 ──────────────────────────────────────────
    var session_auth_mw = SessionAuthMiddleware{ .app = &app };
    const auth_middleware = Middleware.init(SessionAuthMiddleware, &session_auth_mw);

    var admin_role_mw = AdminRoleMiddleware{ .app = &app };
    const admin_middleware = Middleware.init(AdminRoleMiddleware, &admin_role_mw);

    // ── 公开路由 ────────────────────────────────────────
    try router.route(.GET, "/", try Handler.initPerRequest(HomeHandler, allocator));
    try router.route(.GET, "/api/hello", Handler.fromFn(apiHelloHandler));
    try router.route(.POST, "/api/echo", Handler.fromFn(echoHandler));

    // ── 认证路由（不需要 Session 检查）────────────────────
    // 登出不需要提前有 session，所以不走 auth_middleware
    try router.route(.POST, "/api/login", try Handler.initPerRequestWith(
        LoginHandler,
        allocator,
        .{ .app = &app },
    ));
    try router.route(.POST, "/api/logout", try Handler.initPerRequestWith(
        LogoutHandler,
        allocator,
        .{ .app = &app },
    ));

    // ── 受保护路由 ────────────────────────────────────────
    var protected = router.group("", &.{auth_middleware});

    try protected.route(.GET, "/api/profile", try Handler.initPerRequestWith(
        ProfileHandler,
        allocator,
        .{ .app = &app },
    ));

    // ── 管理员路由 ────────────────────────────────────────
    var admin = router.group("/admin", &.{ auth_middleware, admin_middleware });
    try admin.route(.GET, "/stats", try Handler.initPerRequestWith(
        AdminStatsHandler,
        allocator,
        .{ .app = &app },
    ));

    // ── WebSocket ─────────────────────────────────────────
    var ws_handler = try WsEchoHandler.init(allocator, &app.ws_manager);
    defer ws_handler.deinit();
    try router.route(.GET, "/ws", Handler.init(WsEchoHandler, ws_handler));

    // ── 静态文件 ─────────────────────────────────────────
    var static_server = Static.init(allocator, io, "public", "/static");
    try router.route(.GET, "/static/*", Handler.init(Static, &static_server));

    // ── 404 ─────────────────────────────────────────────
    router.notFound(Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ──────────────────────────────────────
    const config = Config.Config{ .port = 9000 };
    var server = try Server.init(allocator, io, config, router);
    defer server.deinit();

    server.setBackgroundQueue(&app.bg_queue);

    std.log.info("Fullstack Demo starting on http://127.0.0.1:9000", .{});
    std.log.info("Endpoints:", .{});
    std.log.info("  GET  /              - Home page", .{});
    std.log.info("  GET  /api/hello     - Public API", .{});
    std.log.info("  POST /api/login     - Login", .{});
    std.log.info("  POST /api/logout    - Logout", .{});
    std.log.info("  GET  /api/profile   - Profile (auth)", .{});
    std.log.info("  GET  /admin/stats   - Admin stats (auth+admin)", .{});
    std.log.info("  GET  /ws            - WebSocket", .{});
    std.log.info("  GET  /static/*      - Static files", .{});
    std.log.info("  POST /api/echo      - Echo", .{});

    try server.run();
}
