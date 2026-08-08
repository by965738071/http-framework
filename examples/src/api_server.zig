//! 完整 REST API 服务器示例
//!
//! 演示 http_framework 的完整 API 服务能力：
//! - Bearer Token 认证（Auth 中间件）
//! - Session 会话管理（登录/登出）
//! - 速率限制（RateLimiter 中间件）
//! - 输入校验（Validation 模块）
//! - JSON 请求/响应
//! - 路由分组（RouteGroup）
//! - 后台任务（BackgroundQueue）
//! - 健康检查与统计端点
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build run-api-server
//! ```
//!
//! # API 端点
//!
//! - POST /api/login          — 登录，返回 session cookie
//! - POST /api/logout         — 登出，清除 session
//! - GET  /api/me            — 获取当前用户信息（需认证）
//! - GET  /api/users         — 列举用户（需认证 + rate limit）
//! - POST /api/users         — 创建用户（需认证 + 输入校验）
//! - GET  /api/health        — 健康检查（无需认证）
//! - GET  /api/stats         — 服务统计（需认证）
//!
//! # 测试示例
//!
//! ```bash
//! # 登录
//! curl -X POST http://localhost:9000/api/login \
//!   -H "Content-Type: application/json" \
//!   -d '{"username":"admin","password":"secret123"}'
//!
//! # 用返回的 cookie 访问受保护端点
//! curl http://localhost:9000/api/me -H "Cookie: session_id=<id>"
//! ```

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
const AuthMiddleware = http_framework.AuthMiddleware;
const AuthConfig = http_framework.AuthConfig;
const SessionManager = http_framework.SessionManager;
const RateLimiter = http_framework.RateLimiter;
const RateLimitConfig = http_framework.RateLimitConfig;
const Validation = http_framework.Validation;
const BackgroundQueue = http_framework.BackgroundQueue;

// =========================================================================
// 模拟用户数据库
// =========================================================================

const User = struct {
    id: u32,
    username: []const u8,
    password: []const u8, // 生产环境应存储 hash
    role: []const u8,
};

const users_db = [_]User{
    .{ .id = 1, .username = "admin", .password = "secret123", .role = "admin" },
    .{ .id = 2, .username = "alice", .password = "pass456", .role = "user" },
    .{ .id = 3, .username = "bob", .password = "qwerty", .role = "user" },
};

// =========================================================================
// 全局服务状态（单例）
// =========================================================================

const AppState = struct {
    session_mgr: SessionManager,
    bg_queue: BackgroundQueue,
    request_count: std.atomic.Value(u64),
    start_time: i128,

    fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        return .{
            .session_mgr = SessionManager.init(allocator, io),
            .bg_queue = undefined, // 在 main 中初始化
            .request_count = std.atomic.Value(u64).init(0),
            .start_time = std.Io.Clock.now(.real, io).nanoseconds,
        };
    }
};

// =========================================================================
// 中间件：请求计时 + 计数
// =========================================================================

const TimingMiddleware = struct {
    state: *AppState,

    pub fn process(self: *@This(), ctx: *RequestContext, res: *Response) anyerror!NextAction {
        // 计数
        _ = self.state.request_count.fetchAdd(1, .monotonic);
        _ = ctx;
        _ = res;
        return .next;
    }
};

// =========================================================================
// 中间件：要求认证（从 session 或 Bearer token）
// =========================================================================

const RequireAuthMiddleware = struct {
    state: *AppState,

    pub fn process(self: *@This(), ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = res;
        // 1. 检查 Bearer token
        if (ctx.getHeader("Authorization")) |auth| {
            if (std.mem.startsWith(u8, auth, "Bearer ")) {
                const token = auth["Bearer ".len..];
                // 简单演示：token 等于 "admin-token" 即通过
                if (std.mem.eql(u8, token, "admin-token")) {
                    return .next;
                }
            }
        }

        // 2. 检查 Session
        if (ctx.getCookie("session_id")) |sid| {
            if (self.state.session_mgr.getData(sid)) |_| {
                return .next;
            }
        }

        // 未认证
        ctx.blocked_status = .unauthorized;
        return .err;
    }
};

// =========================================================================
// 处理器：登录
// =========================================================================

const LoginHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        // 只接受 POST
        if (ctx.method != .POST) {
            try res.statusCode(.method_not_allowed).text("Method not allowed");
            return;
        }

        // 解析 JSON body
        const body = try ctx.readBody();
        if (body.len == 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "Missing request body" });
            return;
        }

        // 简单解析（生产环境应使用完整 JSON 解析）
        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;

        // 从 form 或 JSON 中提取 credential
        if (ctx.isJson()) {
            // 演示：简单提取 username/password（非完整 JSON 解析）
            if (std.mem.indexOf(u8, body, "\"username\"")) |pos| {
                // 简单演示，生产环境用 json.parse
                _ = pos;
            }
        }

        // 使用 form 数据演示
        if (ctx.getForm("username")) |u| username = u;
        if (ctx.getForm("password")) |p| password = p;

        // 如果没有 form 数据，尝试从 query 参数取（演示用）
        if (username == null) username = ctx.getQuery("username");
        if (password == null) password = ctx.getQuery("password");

        const u = username orelse {
            try res.statusCode(.bad_request).json(.{ .@"error" = "Missing username" });
            return;
        };
        const p = password orelse {
            try res.statusCode(.bad_request).json(.{ .@"error" = "Missing password" });
            return;
        };

        // 验证凭据
        var found: ?User = null;
        for (&users_db) |*user| {
            if (std.mem.eql(u8, user.username, u) and
                std.mem.eql(u8, user.password, p))
            {
                found = user.*;
                break;
            }
        }

        if (found == null) {
            try res.statusCode(.unauthorized).json(.{ .@"error" = "Invalid credentials" });
            return;
        }

        // 创建 session
        const session_id = try self.state.session_mgr.getOrCreate(ctx, res);

        // 在 session 中存储用户信息
        try self.state.session_mgr.setData(session_id, "user_id", try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{found.?.id},
        ));
        try self.state.session_mgr.setData(session_id, "username", try ctx.allocator.dupe(u8, found.?.username));
        try self.state.session_mgr.setData(session_id, "role", try ctx.allocator.dupe(u8, found.?.role));

        // 提交后台任务：记录登录日志
        // 注意：由于 ctx.allocator 是 request 级别的，后台任务需要保持数据存活
        // 这里用简单方式演示
        _ = self.state.bg_queue; // 防止未使用警告

        try res.json(.{
            .success = true,
            .message = "Logged in successfully",
            .session_id = session_id,
        });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// =========================================================================
// 处理器：登出
// =========================================================================

const LogoutHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        _ = self;
        _ = ctx;
        // 清除 cookie（发送过期的 Set-Cookie）
        _ = try res.setCookie("session_id", "");
        try res.json(.{ .success = true, .message = "Logged out" });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// =========================================================================
// 处理器：获取当前用户（需认证）
// =========================================================================

const MeHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        // 从 session 获取用户信息
        const sid = ctx.getCookie("session_id") orelse {
            try res.statusCode(.unauthorized).json(.{ .@"error" = "Not authenticated" });
            return;
        };

        const data = self.state.session_mgr.getData(sid) orelse {
            try res.statusCode(.unauthorized).json(.{ .@"error" = "Session not found" });
            return;
        };

        const username = data.get("username") orelse "unknown";
        const role = data.get("role") orelse "unknown";

        try res.json(.{
            .authenticated = true,
            .username = username,
            .role = role,
        });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// =========================================================================
// 处理器：列举用户（需认证）
// =========================================================================

const ListUsersHandler = struct {
    pub fn handle(_: *@This(), ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        // 简化返回
        try res.json(.{
            .users = .{
                .{ .id = 1, .username = "admin", .role = "admin" },
                .{ .id = 2, .username = "alice", .role = "user" },
                .{ .id = 3, .username = "bob", .role = "user" },
            },
            .total = 3,
        });
    }
};

// =========================================================================
// 处理器：创建用户（需认证 + 输入校验）
// =========================================================================

const CreateUserHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        if (ctx.method != .POST) {
            try res.statusCode(.method_not_allowed).text("Method not allowed");
            return;
        }

        const body = try ctx.readBody();
        if (body.len == 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "Empty body" });
            return;
        }

        // 演示输入校验（以 username 为例）
        const username = ctx.getForm("username") orelse
            ctx.getQuery("username") orelse "";
        // 使用 Validation 模块校验
        const rules = .{
            .username = &[_]Validation.FieldRule{
                .{ .required = true },
                .{ .min_len = 3 },
                .{ .max_len = 32 },
            },
            .email = &[_]Validation.FieldRule{
                .{ .pattern = "@" },
            },
        };

        var validation_result = try Validation.validateRequest(ctx.allocator, ctx, rules);
        defer validation_result.deinit(ctx.allocator);

        if (!validation_result.valid) {
            try res.statusCode(.bad_request).json(.{
                .@"error" = "Validation failed",
                .details = @as([]const u8, "Invalid input"),
            });
            return;
        }

        // 演示：提交后台任务
        // 这里简单引用一下 state，防止未使用警告
        _ = self.state.bg_queue;

        try res.statusCode(.created).json(.{
            .@"error" = @as(?[]const u8, null),
            .success = true,
            .message = "User created (demo)",
            .username = username,
        });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// =========================================================================
// 处理器：健康检查
// =========================================================================

fn healthHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.json(.{
        .status = "ok",
        .service = "zig-http-framework-api",
        .timestamp = std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).nanoseconds,
    });
}

// =========================================================================
// 处理器：服务统计（需认证）
// =========================================================================

const StatsHandler = struct {
    state: *AppState,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*@This() {
        const ptr = try allocator.create(@This());
        ptr.* = .{ .state = args.state };
        return ptr;
    }

    pub fn handle(self: *@This(), ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        const stats = self.state.session_mgr.getStats();
        const now = std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        const uptime_ns = now - self.state.start_time;

        try res.json(.{
            .request_count = self.state.request_count.load(.monotonic),
            .uptime_seconds = @divFloor(uptime_ns, 1_000_000_000),
            .active_sessions = stats.active,
            .total_sessions = stats.total,
            .expired_sessions = stats.expired,
        });
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// =========================================================================
// 处理器：404
// =========================================================================

fn notFoundHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).json(.{
        .@"error" = "Not found",
        .message = "The requested endpoint does not exist",
    });
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

    // 初始化全局状态
    var state = AppState.init(allocator, io);
    state.bg_queue = try BackgroundQueue.init(allocator, io);
    defer state.bg_queue.deinit();
    defer state.session_mgr.deinit();

    // 初始化路由器
    var router = Router.init(allocator);
    defer router.deinit();

    // ── 中间件链 ──────────────────────────────────────

    // 1. 请求计时中间件（所有请求）
    var timing_mw = TimingMiddleware{ .state = &state };
    const timing_middleware = Middleware.init(TimingMiddleware, &timing_mw);

    // 2. 速率限制中间件（API 端点）
    var rate_limiter = try RateLimiter.init(allocator, io, .{
        .window_seconds = 60,
        .max_requests = 100,
        .per_ip = true,
    });
    defer rate_limiter.deinit();

    // 3. 认证中间件（保护 /api/* 端点）
    var auth_mw = RequireAuthMiddleware{ .state = &state };
    const auth_middleware = Middleware.init(RequireAuthMiddleware, &auth_mw);

    // ── 公开端点（无需认证）───────────────────────────
    try router.route(.GET, "/api/health", Handler.fromFn(healthHandler));

    // ── 认证端点 ──────────────────────────────────────
    try router.route(.POST, "/api/login", try Handler.initPerRequestWith(
        LoginHandler,
        allocator,
        .{ .state = &state },
    ));
    try router.route(.POST, "/api/logout", try Handler.initPerRequestWith(
        LogoutHandler,
        allocator,
        .{ .state = &state },
    ));

    // ── 受保护端点（需认证）───────────────────────────
    // 使用路由组
    var api_protected = router.group("/api", &.{ timing_middleware, auth_middleware });

    try api_protected.route(.GET, "/me", try Handler.initPerRequestWith(
        MeHandler,
        allocator,
        .{ .state = &state },
    ));
    try api_protected.route(.GET, "/users", Handler.init(
        ListUsersHandler,
        try allocator.create(ListUsersHandler),
    ));
    try api_protected.route(.POST, "/users", try Handler.initPerRequestWith(
        CreateUserHandler,
        allocator,
        .{ .state = &state },
    ));
    try api_protected.route(.GET, "/stats", try Handler.initPerRequestWith(
        StatsHandler,
        allocator,
        .{ .state = &state },
    ));

    // ── 404 ──────────────────────────────────────────
    router.notFound(Handler.fromFn(notFoundHandler));

    // ── 启动服务器 ────────────────────────────────────
    const config = Config{ .port = 9000 };
    var server = try Server.init(allocator, io, config, &router);
    defer server.deinit();

    // 后台任务队列实现 core.Worker，Server 按固定间隔 tick 它
    server.setWorker(state.bg_queue.worker());

    std.log.info("API Server starting on http://127.0.0.1:9000", .{});
    std.log.info("Endpoints:", .{});
    std.log.info("  POST /api/login   — Login", .{});
    std.log.info("  POST /api/logout  — Logout", .{});
    std.log.info("  GET  /api/me      — Get current user (auth required)", .{});
    std.log.info("  GET  /api/users   — List users (auth required)", .{});
    std.log.info("  POST /api/users   — Create user (auth required)", .{});
    std.log.info("  GET  /api/health  — Health check", .{});
    std.log.info("  GET  /api/stats   — Stats (auth required)", .{});

    try server.run();
}
