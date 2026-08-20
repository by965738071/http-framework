//! examples — http_framework 使用示例
//!
//! 一个完整、可直接运行的服务端示例，覆盖 http_framework 的绝大部分功能：
//!
//!   ├─ 基础路由        GET /                 GET /health
//!   │                  GET /greet            GET /users/:id（路径参数）
//!   │                  GET /echo（query 参数）  GET /redirect
//!   ├─ JSON           POST /login           POST /api/items
//!   ├─ 错误响应        GET /errors/:kind
//!   ├─ 文件上传        POST /upload（multipart）
//!   ├─ 静态文件        GET /static/*（./public 目录）
//!   ├─ 压缩响应        GET /compress（Accept-Encoding: gzip）
//!   ├─ 会话            POST /session/login   GET /session/me   POST /session/logout
//!   ├─ 鉴权            GET /admin/secret（Bearer Token，仅 /admin 前缀受保护）
//!   ├─ 限流            GET /rate-limit（60 秒窗口，全局 30 次）
//!   ├─ ORM            GET/POST /orm/users   GET/PUT/DELETE /orm/users/:id
//!   └─ 中间件管道       ErrorRenderer → RequestId → Compress → Timing
//!                      → SecurityHeaders → CORS → RateLimit → ScopedAuth
//!
//! 运行：
//!   cd examples && zig build run
//!
//! 常用 curl 测试（终端里一条条试）：
//!
//!   # 基础
//!   curl http://127.0.0.1:9000/
//!   curl http://127.0.0.1:9000/users/42
//!   curl "http://127.0.0.1:9000/greet?name=Alice&lang=zh"
//!
//!   # JSON POST
//!   curl -X POST -H "Content-Type: application/json" \
//!        -d '{"name":"widget","price":9.9}' http://127.0.0.1:9000/api/items
//!
//!   # 文件上传（需要一个本地文件，这里用示例自带的 public/hello.txt）
//!   curl -X POST -F "username=bob" -F "avatar=@public/hello.txt" \
//!        http://127.0.0.1:9000/upload
//!
//!   # 静态文件 + 压缩
//!   curl http://127.0.0.1:9000/static/index.html
//!   curl --compressed http://127.0.0.1:9000/compress
//!
//!   # 会话（用 cookie jar 保持 cookie）
//!   curl -c /tmp/cj -X POST -H "Content-Type: application/json" \
//!        -d '{"username":"alice","password":"secret"}' http://127.0.0.1:9000/session/login
//!   curl -b /tmp/cj http://127.0.0.1:9000/session/me
//!
//!   # 鉴权（Bearer Token）
//!   curl -H "Authorization: Bearer demo-secret-token" http://127.0.0.1:9000/admin/secret
//!   curl http://127.0.0.1:9000/admin/secret          # → 401
//!
//!   # 限流（快速刷 30 次以上会看到 429 + Retry-After）
//!   for i in $(seq 1 35); do curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9000/rate-limit; done
//!
//!   # ORM CRUD（数据持久化在 ./data/users.json）
//!   curl -X POST -H "Content-Type: application/json" \
//!        -d '{"name":"alice","email":"alice@example.com"}' http://127.0.0.1:9000/orm/users
//!   curl http://127.0.0.1:9000/orm/users
//!   curl http://127.0.0.1:9000/orm/users/1
//!   curl -X PUT -H "Content-Type: application/json" \
//!        -d '{"name":"alice2","email":"alice2@example.com"}' http://127.0.0.1:9000/orm/users/1
//!   curl -X DELETE http://127.0.0.1:9000/orm/users/1
//!
//! 日志输出到 ./log/examples.log（超过 2 MiB 自动轮转 + gzip 归档）。

const std = @import("std");
const builtin = @import("builtin");
const framework = @import("http_framework");

// ────────────────────────────────────────────────────────────────────────────
// 全局状态
// 说明：handler 是纯函数，框架不会往里面注入对象。需要在 handler 里共享的
// 单例（SessionManager / ORM Store / Logger）用模块级 var 持有。
// ────────────────────────────────────────────────────────────────────────────

var logger: framework.Logger = undefined;
var sessions: framework.SessionManager = undefined;
var user_store: ?*UserStore = null;

// ── ORM 模型 ────────────────────────────────────────────────────────────────
// Model(T, "表名") 会在编译期反射出表结构（id 字段自动成为主键并自增），
// 生成一个 JsonStore 类型。Store 就是一个"表"，对应磁盘上一个 JSON 文件。

const OrmUser = struct {
    id: u64 = 0,
    name: []const u8,
    email: []const u8,
};

const UserModel = framework.orm.Model(OrmUser, "users");
const UserStore = UserModel.Store;

// ────────────────────────────────────────────────────────────────────────────
// 入口
// ────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    // 0. allocator（与框架示例一致）
    //    Debug 模式用 DebugAllocator：退出时泄漏检测。
    //    Release 用全局 Arena：进程生命周期内存，退出一次性释放。
    var release_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var debug_allocator_instance = std.heap.DebugAllocator(.{ .safety = false }){};

    const allocator: std.mem.Allocator = if (builtin.mode == .debug)
        debug_allocator_instance.allocator()
    else
        release_arena.allocator();
    defer {
        if (builtin.mode == .debug) {
            if (debug_allocator_instance.deinit() == .leak) {
                std.debug.panic("memory leak {}", .{@src()});
            }
        } else {
            release_arena.deinit();
        }
    }

    // 1. Io（线程池）。concurrent_limit 限制线程数上限，防止压测时无限扩张。
    var io_state = std.Io.Threaded.init(allocator, .{
        .concurrent_limit = .limited(128),
    });
    const io = io_state.io();

    // 2. 配置（分层：network / http / body / pool）
    const config = framework.Config{
        .network = .{ .port = 9000 },
        .http = .{ .server_name = "examples" },
        .body = .{ .size_limit = 10 * 1024 * 1024 },
        .pool = .{ .request_arena_retain_bytes = 4 * 1024 },
    };

    // 3. 结构化日志器（文件输出，2 MiB 轮转 + gzip 归档 1 个）
    logger = try framework.Logger.init(allocator, io, .{
        .min_level = .info,
        .format = .json,
        .output = .file,
        .file = .{
            .path = "log/examples.log",
            .max_size = 2 * 1024 * 1024,
            .max_backups = 1,
            .compress = true,
        },
    });
    defer logger.deinit();
    logger.info(null, "examples starting", &.{
        framework.fstr("addr", config.network.address),
        framework.fint("port", config.network.port),
    });

    // 4. 会话管理器（内存 Session，cookie 名 "sid"）
    sessions = framework.SessionManager.init(allocator, io, .{
        .cookie_name = "sid",
        .session_timeout_sec = 3600,
    });
    defer sessions.deinit();

    // 5. ORM store（打开/创建表 ./data/users.json）
    const store = try UserStore.open(allocator, io, "./data");
    user_store = store;
    defer store.close() catch {};

    // 6. 路由器
    var router = try framework.Router.init(allocator);
    defer router.deinit();

    // ── 中间件管道（先注册 = 先执行 = 外层）────────────────────

    // 错误渲染（放最外层，兜底所有 handler 抛出的错误）
    var error_renderer = framework.ErrorRenderer{};
    try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));

    // 请求 ID（每个请求生成 X-Request-Id，日志/下游中间件都能拿到）
    var rid_mw = framework.RequestIdMiddleware{};
    try router.use(framework.Middleware.init(framework.RequestIdMiddleware, &rid_mw));

    // 响应压缩（Accept-Encoding: gzip/deflate 时压缩大响应）
    var compress_mw = framework.CompressMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CompressMiddleware, &compress_mw));

    // 自定义中间件：请求计时（示例，见文件底部定义）
    var timing_mw = TimingMiddleware{};
    try router.use(framework.Middleware.init(TimingMiddleware, &timing_mw));

    // 安全响应头（X-Content-Type-Options 等）
    var security_mw = framework.SecurityHeaders{ .config = .{} };
    try router.use(framework.Middleware.init(framework.SecurityHeaders, &security_mw));

    // CORS（通配允许所有源，预检请求自动处理）
    var cors_mw = framework.CorsMiddleware{ .config = .{} };
    try router.use(framework.Middleware.init(framework.CorsMiddleware, &cors_mw));

    // 速率限制：全局 30 次/分钟（per_ip=true 需要 trust_proxy=true，
    // 否则拿不到对端 IP 会直接跳过——见 rate_limiter 注释）。
    var rate_mw = framework.RateLimiter.init(allocator, io, .{
        .window_seconds = 60,
        .max_requests = 30,
        .per_ip = false,
        .identifier_header = null,
    });
    try router.use(framework.Middleware.init(framework.RateLimiter, &rate_mw));

    // 自定义中间件：路径作用域鉴权（只有 /admin 前缀需要 Bearer Token，
    // 内部委托给框架内置的 AuthMiddleware 做实际校验）。
    var scoped_auth = ScopedAuth{
        .auth = .{ .config = .{
            .bearer_token = "demo-secret-token",
            .realm = "Protected",
        } },
        .prefix = "/admin",
    };
    try router.use(framework.Middleware.init(ScopedAuth, &scoped_auth));

    // ── 基础路由 ──────────────────────────────────────────────

    try router.route(.GET, "/", framework.Handler.fromFn(helloHandler));
    try router.route(.GET, "/health", framework.Handler.fromFn(healthHandler));
    try router.route(.GET, "/greet", framework.Handler.fromFn(greetHandler));

    // 路径参数（:id）+ query 参数
    try router.route(.GET, "/users/:id", framework.Handler.fromFn(userHandler));
    try router.route(.GET, "/echo", framework.Handler.fromFn(echoHandler));

    // 重定向
    try router.route(.GET, "/redirect", framework.Handler.fromFn(redirectHandler));

    // 错误响应演示（AppError → 对应 HTTP 状态码 + JSON body）
    try router.route(.GET, "/errors/:kind", framework.Handler.fromFn(errorDemoHandler));

    // 单例 handler（跨请求持有状态，见 ApiHandler 定义）
    var api_handler = ApiHandler{ .request_count = 0 };
    try router.route(.GET, "/api", framework.Handler.initSingleton(ApiHandler, &api_handler));

    // factory handler（每个请求创建/销毁实例）
    const factory_handler = try framework.Handler.initFactory(FactoryHandler, allocator);
    defer factory_handler.deinit();
    try router.route(.GET, "/factory", factory_handler);

    // ── JSON body 解析 ────────────────────────────────────────

    try router.route(.POST, "/login", framework.Handler.fromFn(loginHandler));
    try router.route(.POST, "/api/items", framework.Handler.fromFn(createItemHandler));

    // ── 文件上传（multipart/form-data）────────────────────────

    try router.route(.POST, "/upload", framework.Handler.fromFn(uploadHandler));

    // ── 静态文件服务 ──────────────────────────────────────────

    var static_server = framework.StaticFileServer.init(allocator, io, "./public", "/static");
    try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &static_server));

    // ── 压缩响应演示 ──────────────────────────────────────────

    try router.route(.GET, "/compress", framework.Handler.fromFn(compressDemoHandler));

    // ── 会话示例 ───────────────────────────────────────────────

    try router.route(.POST, "/session/login", framework.Handler.fromFn(sessionLoginHandler));
    try router.route(.GET, "/session/me", framework.Handler.fromFn(sessionMeHandler));
    try router.route(.POST, "/session/logout", framework.Handler.fromFn(sessionLogoutHandler));

    // ── 限流演示 ───────────────────────────────────────────────

    try router.route(.GET, "/rate-limit", framework.Handler.fromFn(rateLimitDemoHandler));

    // ── 鉴权演示（/admin 前缀已被 scoped_auth 保护）────────────

    try router.route(.GET, "/admin/secret", framework.Handler.fromFn(adminSecretHandler));

    // ── ORM CRUD ───────────────────────────────────────────────

    try router.route(.GET, "/orm/users", framework.Handler.fromFn(ormListHandler));
    try router.route(.POST, "/orm/users", framework.Handler.fromFn(ormCreateHandler));
    try router.route(.GET, "/orm/users/:id", framework.Handler.fromFn(ormGetHandler));
    try router.route(.PUT, "/orm/users/:id", framework.Handler.fromFn(ormUpdateHandler));
    try router.route(.DELETE, "/orm/users/:id", framework.Handler.fromFn(ormDeleteHandler));

    // ── 自定义 404 ─────────────────────────────────────────────

    router.notFoundHandler(framework.Handler.fromFn(notFoundHandler));

    // 7. 生命周期钩子（日志 Hook——利用 server 计算好的 duration/status）
    var log_hook = framework.LoggingHook{ .logger = &logger };
    const hooks = [_]framework.Hook{
        framework.Hook.init(framework.LoggingHook, &log_hook),
    };

    // 8. 组装服务器
    var server = try framework.Server.init(allocator, io, config, &router);
    defer server.deinit();
    try server.setup();
    server.setLifecycle(.{ .hooks = &hooks });
    server.installSignalHandlers();

    std.log.info("Server starting on {s}:{d}", .{ config.network.address, config.network.port });

    try server.run();
}

// ────────────────────────────────────────────────────────────────────────────
// 基础路由 handlers
// ────────────────────────────────────────────────────────────────────────────

fn helloHandler(_: *framework.Context, res: *framework.Response) !void {
    try res.statusCode(.ok).text("Hello, World! This is the examples server.");
}

fn healthHandler(_: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .status = "ok", .service = "examples" });
}

/// 路径参数示例：GET /users/42
fn userHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const id = ctx.param("id") orelse {
        try ctx.failWith(res, framework.AppError.badRequest("missing :id"));
        return;
    };
    const id_num = std.fmt.parseInt(u64, id, 10) catch {
        try ctx.failWith(res, framework.AppError.badRequest("id must be an integer"));
        return;
    };
    try res.json(.{ .id = id_num, .name = std.fmt.allocPrint(ctx.arena, "user-{d}", .{id_num}) catch "?" });
}

/// query 参数示例：GET /greet?name=Alice&lang=zh
fn greetHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const name = ctx.query("name") orelse "world";
    const lang = ctx.query("lang") orelse "en";
    const msg = if (std.mem.eql(u8, lang, "zh"))
        try std.fmt.allocPrint(ctx.arena, "你好，{s}！", .{name})
    else
        try std.fmt.allocPrint(ctx.arena, "Hello, {s}!", .{name});
    try res.text(msg);
}

/// query 参数回显：GET /echo?a=1&b=2
fn echoHandler(ctx: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .query = ctx.request.query });
}

/// 重定向：GET /redirect → /users/42
fn redirectHandler(_: *framework.Context, res: *framework.Response) !void {
    try res.redirect("/users/42", false);
}

// ────────────────────────────────────────────────────────────────────────────
// JSON body 解析
// ────────────────────────────────────────────────────────────────────────────

const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
};

fn loginHandler(ctx: *framework.Context, res: *framework.Response) !void {
    // parseJson(T, arena, body)：解析并返回 *T（arena 分配，请求结束自动回收）
    const body = framework.parseJson(LoginRequest, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) catch {
        try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
        return;
    };

    if (std.mem.eql(u8, body.username, "alice") and std.mem.eql(u8, body.password, "secret")) {
        try res.json(.{ .ok = true, .user = body.username });
    } else {
        try ctx.failWith(res, framework.AppError.unauthorized("invalid credentials"));
    }
}

const CreateItemRequest = struct {
    name: []const u8,
    price: f64,
};

fn createItemHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const body = framework.parseJson(CreateItemRequest, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) catch {
        try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
        return;
    };

    logger.info(ctx, "item created", &.{
        framework.fstr("name", body.name),
        framework.ffloat("price", body.price),
    });

    // 201 Created + 回显创建的对象
    try res.statusCode(.created).json(.{
        .id = 1,
        .name = body.name,
        .price = body.price,
    });
}

// ────────────────────────────────────────────────────────────────────────────
// 文件上传（multipart/form-data）
// ────────────────────────────────────────────────────────────────────────────

fn uploadHandler(ctx: *framework.Context, res: *framework.Response) !void {
    var form = framework.multipartFrom(ctx, 10 * 1024 * 1024) catch {
        try ctx.failWith(res, framework.AppError.badRequest("not a multipart request"));
        return;
    };
    defer form.deinit();

    const username = form.getText("username") orelse "anonymous";

    if (form.getFile("avatar")) |file| {
        const file_name = file.file_name orelse "upload.bin";
        var target_file = try std.Io.Dir.createFile(.cwd(), ctx.io, file_name, .{});
        defer target_file.close(ctx.io);
        var writer = target_file.writer(ctx.io, &.{});
        const w = &writer.interface;
        try w.writeAll(file.data);
        const msg = try std.fmt.allocPrint(
            ctx.arena,
            "uploaded \"{s}\" ({d} bytes, {s}) by {s}",
            .{
                file_name,
                file.data.len,
                file.content_type orelse "unknown",
                username,
            },
        );
        try res.text(msg);
        return;
    }

    try ctx.failWith(res, framework.AppError.badRequest("no file field \"avatar\" found"));
}

// ────────────────────────────────────────────────────────────────────────────
// 压缩响应演示
// ────────────────────────────────────────────────────────────────────────────

fn compressDemoHandler(ctx: *framework.Context, res: *framework.Response) !void {
    // 生成一个 ~80KB 的重复 JSON body（超过 min_size 1KB，可被压缩）
    var buf = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        try buf.appendSlice(ctx.arena, "{\"key\":\"value\",\"n\":123,\"ok\":true}\n");
    }
    const body = try buf.toOwnedSlice(ctx.arena);
    _ = try res.header("Content-Type", "application/json");
    try res.text(body);
}

// ────────────────────────────────────────────────────────────────────────────
// 错误响应演示（AppError）
// ────────────────────────────────────────────────────────────────────────────

fn errorDemoHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const kind = ctx.param("kind") orelse "bad_request";

    // AppError 是 (status, message) 对，toResponse 写状态码 + JSON body
    const app_err: framework.AppError = if (std.mem.eql(u8, kind, "not_found"))
        framework.AppError.notFound("demo: resource not found")
    else if (std.mem.eql(u8, kind, "bad_request"))
        framework.AppError.badRequest("demo: bad request")
    else if (std.mem.eql(u8, kind, "unauthorized"))
        framework.AppError.unauthorized("demo: unauthorized")
    else if (std.mem.eql(u8, kind, "forbidden"))
        framework.AppError.forbidden("demo: forbidden")
    else if (std.mem.eql(u8, kind, "conflict"))
        framework.AppError.conflict("demo: conflict")
    else if (std.mem.eql(u8, kind, "too_many_requests"))
        framework.AppError.tooManyRequests("demo: too many requests")
    else if (std.mem.eql(u8, kind, "internal"))
        framework.AppError.internal("demo: internal error")
    else
        framework.AppError.notImplemented("demo: unknown kind");

    try app_err.toResponse(res);
}

// ────────────────────────────────────────────────────────────────────────────
// 会话示例（SessionManager）
// ────────────────────────────────────────────────────────────────────────────

/// POST /session/login  {"username":"alice","password":"secret"}
fn sessionLoginHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const body = framework.parseJson(LoginRequest, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) catch {
        try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
        return;
    };

    if (!std.mem.eql(u8, body.username, "alice") or !std.mem.eql(u8, body.password, "secret")) {
        try ctx.failWith(res, framework.AppError.unauthorized("invalid credentials"));
        return;
    }

    // getOrCreate：没有 cookie 就新建 session 并写 Set-Cookie
    const session_id = try sessions.getOrCreate(ctx, res);
    try sessions.setData(session_id, "username", body.username);

    logger.info(ctx, "user logged in", &.{framework.fstr("user", body.username)});

    try res.json(.{ .ok = true, .session = session_id });
}

/// GET /session/me （带 cookie）→ 返回当前登录用户
fn sessionMeHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const session_id = ctx.request.getCookie("sid") orelse {
        try ctx.failWith(res, framework.AppError.unauthorized("no session cookie"));
        return;
    };

    const username = sessions.getValue(session_id, "username", ctx.arena) catch {
        try ctx.failWith(res, framework.AppError.unauthorized("session expired or invalid"));
        return;
    } orelse {
        try ctx.failWith(res, framework.AppError.unauthorized("session expired or invalid"));
        return;
    };
    try res.json(.{ .ok = true, .username = username });
}

/// POST /session/logout → 让 cookie 过期
fn sessionLogoutHandler(_: *framework.Context, res: *framework.Response) !void {
    _ = try res.setCookieFull(.{
        .name = "sid",
        .value = "deleted",
        .max_age = 0,
    });
    try res.json(.{ .ok = true });
}

// ────────────────────────────────────────────────────────────────────────────
// 限流演示
// ────────────────────────────────────────────────────────────────────────────

fn rateLimitDemoHandler(_: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .ok = true, .message = "you are within the rate limit" });
}

// ────────────────────────────────────────────────────────────────────────────
// 鉴权演示（/admin 前缀由 ScopedAuth 中间件保护）
// ────────────────────────────────────────────────────────────────────────────

fn adminSecretHandler(ctx: *framework.Context, res: *framework.Response) !void {
    // AuthMiddleware 校验通过后会把 AuthInfo 存进 ctx，用 getUserData 取出来
    if (ctx.getUserData(framework.AuthInfo)) |info| {
        try res.json(.{
            .ok = true,
            .path = "/admin/secret",
            .auth_strategy = @tagName(info.strategy),
            .token = info.token orelse "",
            .api_key = info.api_key orelse "",
        });
    } else {
        try res.json(.{ .ok = true, .path = "/admin/secret" });
    }
}

// ────────────────────────────────────────────────────────────────────────────
// ORM CRUD handlers
// ────────────────────────────────────────────────────────────────────────────

const NewUserBody = struct {
    name: []const u8,
    email: []const u8,
};

fn ormListHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const store = user_store orelse {
        try ctx.failWith(res, framework.AppError.internal("store not initialized"));
        return;
    };

    // 方法一：拿全部行（返回的切片由 store 的 allocator 分配，用完要 free）
    const rows = try store.all();
    defer store.allocator.free(rows);

    try res.json(.{ .total = rows.len, .users = rows });
}

fn ormCreateHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const store = user_store orelse {
        try ctx.failWith(res, framework.AppError.internal("store not initialized"));
        return;
    };

    const body = framework.parseJson(NewUserBody, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) catch {
        try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
        return;
    };

    // insert 返回自增主键 id
    const id = store.insert(.{ .id = 0, .name = body.name, .email = body.email }) catch |err| {
        // UniqueViolation 只在字段标记了 unique 约束时才会产生。
        // 本示例的 OrmUser 没有标注唯一字段（框架 Model() 目前自动把
        // id 标为主键，其余字段无约束），所以这里实际不会触发——
        // 保留该分支以演示 error.UniqueViolation 的处理方式。
        if (err == error.UniqueViolation) {
            try ctx.failWith(res, framework.AppError.conflict("email already exists"));
            return;
        }
        return err;
    };
    // 改动只存在内存里——要持久化必须显式 flush()（把 rows 写回 JSON 文件）。
    // 失败会向上传播，由调用方决定如何处理（这里直接 500）。
    try store.flush();

    logger.info(ctx, "user created", &.{framework.fint("id", @intCast(id))});

    try res.statusCode(.created).json(.{ .id = id, .name = body.name, .email = body.email });
}

fn ormGetHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const store = user_store orelse {
        try ctx.failWith(res, framework.AppError.internal("store not initialized"));
        return;
    };
    const id = parseId(ctx, res) orelse return;

    const user = try store.findById(id) orelse {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    };
    try res.json(user);
}

fn ormUpdateHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const store = user_store orelse {
        try ctx.failWith(res, framework.AppError.internal("store not initialized"));
        return;
    };
    const id = parseId(ctx, res) orelse return;

    const body = framework.parseJson(NewUserBody, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) catch {
        try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
        return;
    };

    const updated = try store.updateById(id, .{ .id = id, .name = body.name, .email = body.email });
    if (!updated) {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    }
    try store.flush();
    try res.json(.{ .ok = true, .id = id });
}

fn ormDeleteHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const store = user_store orelse {
        try ctx.failWith(res, framework.AppError.internal("store not initialized"));
        return;
    };
    const id = parseId(ctx, res) orelse return;

    const deleted = try store.deleteById(id);
    if (!deleted) {
        try ctx.failWith(res, framework.AppError.notFound("user not found"));
        return;
    }
    try store.flush();
    try res.json(.{ .ok = true, .deleted = id });
}

/// 从路径参数解析 id；失败时已写好 400 响应，返回 null。
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
// 自定义 404
// ────────────────────────────────────────────────────────────────────────────

fn notFoundHandler(_: *framework.Context, res: *framework.Response) !void {
    _ = res.statusCode(.not_found);
    // 注意：不能用 `.error = ...` 作为匿名结构体字段名——该 dev 版 Zig 的
    // tokenizer 对 `.{` 后紧跟关键字 `error` 的解析有 bug（"expected
    // expression, found '.'"）。框架代码也刻意避开了这种写法。
    try res.json(.{
        .error_code = "not_found",
        .message = "no route matched",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// 单例 handler（跨请求持有状态）
// ────────────────────────────────────────────────────────────────────────────

const ApiHandler = struct {
    request_count: u32,

    pub fn handle(self: *ApiHandler, _: *framework.Context, res: *framework.Response) !void {
        self.request_count += 1;
        try res.json(.{ .endpoint = "api", .requests = self.request_count });
    }
};

// ────────────────────────────────────────────────────────────────────────────
// factory handler（每个请求新建实例，框架负责 create/destroy 配对）
// 注意框架的契约：init 用 allocator 创建实例；deinit 只释放实例**内部**
// 持有的资源，实例本身的内存由框架在 deinit 之后销毁（handler.zig destroy）。
// 所以这里 deinit 必须留空——否则会 double free。
// ────────────────────────────────────────────────────────────────────────────

const FactoryHandler = struct {
    pub fn init(allocator: std.mem.Allocator) !*FactoryHandler {
        const self = try allocator.create(FactoryHandler);
        self.* = .{};
        return self;
    }

    pub fn handle(self: *FactoryHandler, _: *framework.Context, res: *framework.Response) !void {
        _ = self;
        try res.json(.{ .kind = "factory handler", .note = "a new instance per request" });
    }

    pub fn deinit(self: *FactoryHandler) void {
        _ = self;
        // 实例内存由框架销毁，这里只释放内部资源（本例无内部资源）。
    }
};

// ────────────────────────────────────────────────────────────────────────────
// 自定义中间件
// ────────────────────────────────────────────────────────────────────────────

/// 计时中间件：给每个响应加 X-Response-Time-ns 头。
const TimingMiddleware = struct {
    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        _ = self;
        // 启用缓冲模式——保证 next() 返回后还能修改响应头。
        // 不调 flush()：让外层（Compress / ErrorRenderer / ConnectionRunner）负责最终发送。
        res.setBuffered();
        const start = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;

        // 错误时也要加计时头——计时应该包含错误处理时间。
        next.call(ctx, res) catch |err| {
            const elapsed_err = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
            _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed_err}) catch "?");
            return err;
        };

        const elapsed = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
        _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
    }
};

/// 路径作用域鉴权中间件：只有 prefix 前缀的请求才校验身份。
/// 这是"如何用框架组件拼自定义逻辑"的示例——校验部分直接委托
/// 给内置 AuthMiddleware（支持 bearer / basic / api_key 多种策略）。
const ScopedAuth = struct {
    auth: framework.AuthMiddleware,
    prefix: []const u8,

    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        // 不在受保护前缀内 → 直接放行
        if (!std.mem.startsWith(u8, ctx.request.path, self.prefix)) {
            return next.call(ctx, res);
        }
        // 前缀内 → 走 AuthMiddleware 的校验逻辑（失败会 short-circuit 401）
        return self.auth.process(ctx, res, next);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// WebSocket 示例
//
// 注意：http_server 层目前还没有实现连接劫持（ConnectionRunner 不处理
// 101 升级后的裸帧读写），所以这里不做可运行的服务端 /ws 路由。
//
// 现在可用的 API（本项目测试已覆盖，直接 `zig build test` 即可验证）：
//   - wsHandshake(ctx, res)  校验升级请求，设置 101 + Sec-WebSocket-Accept 头
//   - wsComputeAcceptKey(...) 计算 Sec-WebSocket-Accept 值
//   - wsEncodeFrame / wsDecodeFrame  单帧编解码（RFC 6455 §5）
//   - WebSocket.initServer/initClient  连接级读写（分片拼合、自动回 pong、关闭）
//
// 将来 ConnectionRunner 支持劫持后，一个 /ws 路由大致长这样：
//   const upgraded = try framework.wsHandshake(ctx, res);
//   if (!upgraded) return;          // 不是合法升级请求，已写好响应
//   // 这里接管底层 TCP 连接，构造 WebSocket.initServer(reader, writer, allocator)
//   // 然后 while (true) { const msg = try ws.receive(); ... }
// ────────────────────────────────────────────────────────────────────────────

test "websocket: client → server text roundtrip (in-memory)" {
    const allocator = std.testing.allocator;

    // 客户端发送（mask=true）
    var client_w: std.Io.Writer.Allocating = .init(allocator);
    defer client_w.deinit();
    var dummy_r: std.Io.Reader = .fixed("");
    var client_ws = framework.WebSocket.initClient(&dummy_r, &client_w.writer, allocator);
    try client_ws.sendText("hello over websocket");

    // 服务端接收（服务端必须 unmask 客户端帧）
    var server_r: std.Io.Reader = .fixed(client_w.written());
    var server_w: std.Io.Writer.Allocating = .init(allocator);
    defer server_w.deinit();
    var server_ws = framework.WebSocket.initServer(&server_r, &server_w.writer, allocator);

    var msg = try server_ws.receive();
    defer msg.deinit();
    try std.testing.expectEqual(framework.OpCode.text, msg.opcode);
    try std.testing.expectEqualStrings("hello over websocket", msg.payload);
}

test "websocket: server → client binary roundtrip (in-memory)" {
    const allocator = std.testing.allocator;

    // 服务端发送（mask=false）
    var send_w: std.Io.Writer.Allocating = .init(allocator);
    defer send_w.deinit();
    var dummy_r: std.Io.Reader = .fixed("");
    var server_ws = framework.WebSocket.initServer(&dummy_r, &send_w.writer, allocator);
    try server_ws.sendBinary("\x00\x01\x02\xff");

    // 客户端接收（客户端不做 mask 校验，直接读）
    var client_r: std.Io.Reader = .fixed(send_w.written());
    var client_w: std.Io.Writer.Allocating = .init(allocator);
    defer client_w.deinit();
    var client_ws = framework.WebSocket.initClient(&client_r, &client_w.writer, allocator);

    var msg = try client_ws.receive();
    defer msg.deinit();
    try std.testing.expectEqual(framework.OpCode.binary, msg.opcode);
    try std.testing.expectEqualSlices(u8, "\x00\x01\x02\xff", msg.payload);
}

test "websocket: handshake accept key (RFC 6455 §4.2.2 官方例子)" {
    // Sec-WebSocket-Accept = base64(SHA1(key + GUID)) → 20 字节 SHA1 = 28 字符
    var out: [28]u8 = undefined;
    const accept = try framework.wsComputeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocket: wsEncodeFrame / wsDecodeFrame roundtrip" {
    const allocator = std.testing.allocator;

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    // 客户端帧必须 masked
    try framework.wsEncodeFrame(&w.writer, .text, "hi", true, .{ 0xAA, 0xBB, 0xCC, 0xDD });

    var r: std.Io.Reader = .fixed(w.written());
    const frame = try framework.wsDecodeFrame(&r, allocator, 16 * 1024 * 1024);
    defer allocator.free(frame.payload);

    try std.testing.expect(frame.fin);
    try std.testing.expect(frame.mask);
    try std.testing.expectEqual(framework.OpCode.text, frame.opcode);
    try std.testing.expectEqualStrings("hi", frame.payload);
}
