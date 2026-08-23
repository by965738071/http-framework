# Zig HTTP Framework

基于 Zig `std.Io` 接口、跑在 [zio](https://github.com/lalinsky/zio) 异步运行时（io_uring / epoll / kqueue / IOCP + 协程）上的高性能、轻量级 HTTP 服务器框架。4 层核心（协议 / 应用 / 路由 / 服务器）+ 一批单向依赖核心的 addon，支持请求级生命周期、radix-trie 路由、中间件管道、WebSocket、静态文件服务及内置 ORM。

> **架构要点**：框架主体写在标准 `std.Io` 接口上（路由/中间件/handler/会话等后端无关）；与具体
> 异步运行时绑定的代码（监听/accept/信号/连接读写）集中在 `http_server/zio_server.zig` 一个文件。
> 目前默认后端是 zio；将来接其他运行时只需新增一个 `xxx_server.zig`，公共逻辑不改。

## 性能

`zig build run -Doptimize=ReleaseFast`（`src/main.zig` 示例，完整中间件管道：ErrorRenderer → RequestId → Compress → Timing → SecurityHeaders → CORS）

```
oha -z 10s -c 200 http://127.0.0.1:9000/

Success rate:      100.00%
Requests/sec:      38206
P50:               0.64 ms
P90:               10.3 ms
P99:               30.6 ms
```

> 上表在本机（macOS，ReleaseFast）实测。三种 handler 模式的派发差异只差一次间接调用
> （`.factory` 额外一次 create/destroy），在 `-c 200` 下 `GET /`（fromFn）≈ `GET /api`（initSingleton）≈ 3.8 万 req/s，可忽略不计。

### 框架内部微基准

`zig build bench -Doptimize=ReleaseFast`——内存内驱动 `Router.dispatch` 热路径（trie 匹配 + 3 层
中间件管道 + handler + 响应构建），排除网络/内核，度量**纯框架开销**（keep-alive 复用 arena）：

```
static route (fromFn)         ~8.1M ops/s    ~123 ns/op
param route (/users/:id)      ~7.5M ops/s    ~133 ns/op
json response                 ~5.3M ops/s    ~189 ns/op
404 (unmatched)               ~8.0M ops/s    ~125 ns/op
```

> 这是框架内部吞吐上限参考，不等于端到端 HTTP QPS（后者受 zio/内核/网络支配，见上表）。

| 模式 | 工厂函数 | 生命周期 | 每次请求分配 |
|------|---------|---------|------------|
| `fromFn` (纯函数) | — | 无状态，全局共享 | 零 |
| `initSingleton` (单例) | — | main 创建，程序退出销毁 | 零 |
| `initFactory` (请求级) | `init(allocator) !*T` | 每请求 create/destroy 配对 | 1 次 create + 1 次 destroy |

## 核心功能

- **跨平台统一异步 I/O** — 跑在 zio 运行时上，Linux io_uring（自动 epoll 回退）/ macOS·BSD kqueue / Windows IOCP，一套 API 无平台分支
- **三种处理器模式** — 纯函数（零分配）、单例（零分配）、请求级（每请求创建/销毁）
- **radix-trie 动态路由** — `/users/:id` 路径参数、通配符 `/static/*`、路由分组（组级中间件）、HEAD 自动回退到 GET、405 带 `Allow`、自定义 404
- **中间件管道** — 经典 `process(ctx, res, next)` 模型（非 threadlocal），`next.call` 后置逻辑、缓冲模式响应修改
- **应用级服务容器** — `ctx.service(T)` 取回进程级单例（SessionManager/Logger/ORM 等），脱离全局变量
- **统一错误处理** — `AppError`（状态码 + 消息）经 `ErrorRenderer` 渲染；无 ErrorRenderer 时框架自动兜底 500
- **WebSocket** — RFC 6455 握手 + 帧编解码 + 连接劫持（`wsUpgrade` 一步升级，可运行的服务端路由）、分片拼合、ping/pong（帧长上限防 DoS）
- **静态文件服务** — 路径遍历防护、ETag/Last-Modified 条件请求、304、HEAD、目录 index.html、大文件流式 + gzip
- **HTTP keep-alive** — 连接循环 + 优雅关闭（zio.Signal 处理 SIGINT）；Connection 头按 token 列表解析
- **内置 ORM** — JSON 文件持久化，编译期反射表结构，CRUD、查询、排序、分页
- **安全与扩展** — Auth（Bearer/Basic/API Key）、CORS（预检/Vary）、CSRF（双提交）、Security Headers、Session（Path=/、Secure 可配）、Multipart、响应压缩（q 值协商）、结构化日志、限流（Retry-After/X-RateLimit-*）
- **可替换后端** — 框架核心只依赖 `std.Io`；运行时绑定代码隔离在 `zio_server.zig`，换库不动核心

## 环境要求

- **Zig**: `0.17.0-dev` 或更新版本（使用 `std.Io` API）
- **zio**: 异步运行时依赖（在 `build.zig.zon` 里声明，默认指向本地路径）

```bash
# 开发模式（框架自带示例）
zig build run

# 发布模式
zig build run -Doptimize=ReleaseFast

# 运行测试
zig build test

# 运行性能微基准（框架内部热路径）
zig build bench -Doptimize=ReleaseFast

# 运行综合示例
cd examples && zig build run
```

## 快速开始

把 `http_framework` 加入 `build.zig.zon` 依赖后，入口只做两件事：用 `framework.runZio`
启动 zio 运行时（入口不直接依赖 zio），在 `appMain(io, allocator)` 里做 http_framework 初始化：

```zig
const std = @import("std");
const framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    // 启动 zio 运行时，在其协程上下文里跑 appMain。io = zio.Runtime.io()（一个 std.Io 值）。
    try framework.runZio(init.gpa, appMain);
}

fn appMain(io: std.Io, allocator: std.mem.Allocator) !void {
    // 1. 分层配置（network / http / body / pool）
    const config = framework.Config{
        .network = .{ .port = 9000 },
        .http = .{ .server_name = "my-app" },
        .body = .{ .size_limit = 10 * 1024 * 1024 },
    };

    // 2. 路由 + handler
    var router = try framework.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/", framework.Handler.fromFn(helloHandler));
    try router.route(.GET, "/users/:id", framework.Handler.fromFn(userHandler));
    router.notFoundHandler(framework.Handler.fromFn(notFoundHandler));

    // 3. 组装并运行（内部阻塞 accept + zio.Signal 处理 SIGINT 优雅关闭）
    var server = try framework.Server.init(allocator, io, config, &router);
    defer server.deinit();
    try server.setup();
    try server.run();
}

fn helloHandler(_: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .greeting = "Hello, World!" });
}

fn userHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const id = ctx.param("id") orelse {
        try ctx.failWith(res, framework.AppError.badRequest("missing :id"));
        return;
    };
    try res.json(.{ .user_id = id });
}

fn notFoundHandler(_: *framework.Context, res: *framework.Response) !void {
    _ = res.statusCode(.not_found);
    try res.json(.{ .error_code = "not_found", .message = "no route matched" });
}
```

> 入口不再需要手写 allocator/`std.Io.Threaded`/`installSignalHandlers`——`runZio` 封装了
> 运行时启动，信号关机内置在 `server.run()`（等 SIGINT → 取消 accept → drain 在途连接）。

接线方式参考 `examples/build.zig`：`b.dependency("http_framework", .{...}).module("http_framework")`。

## 三种 Handler 模式

| 模式 | 工厂函数 | 生命周期 | 分配开销 | 适用场景 |
|------|---------|---------|---------|---------|
| **纯函数** | `fromFn` | 无状态，全局共享 | 零 | 简单的请求处理、404 |
| **单例** | `initSingleton(T, ptr)` | main 创建，程序退出销毁 | 仅启动时一次 | 全局配置、计数器、静态文件服务 |
| **请求级** | `initFactory(T, alloc)` | 每次请求 create/destroy | 每次 1 次 create + 1 次 destroy | 请求隔离状态、上下文数据 |

> **`initFactory` 的 deinit 规则**：`deinit()` 只释放实例**内部**字段（如 `allocator.free`），
> **不要**调 `allocator.destroy(self)`——框架在 `deinit()` 之后会统一销毁实例内存。

### 纯函数模式（零开销）

```zig
try router.route(.GET, "/", framework.Handler.fromFn(struct {
    fn handler(_: *framework.Context, res: *framework.Response) !void {
        try res.text("Hello");
    }
}.handler));
```

### 单例模式（零分配）

```zig
const CounterHandler = struct {
    count: u32 = 0,
    pub fn handle(self: *CounterHandler, _: *framework.Context, res: *framework.Response) !void {
        self.count += 1;
        try res.json(.{ .requests = self.count });
    }
};

var counter = CounterHandler{};
try router.route(.GET, "/count", framework.Handler.initSingleton(CounterHandler, &counter));
```

### 请求级模式（每请求创建/销毁）

```zig
const UserHandler = struct {
    pub fn init(allocator: std.mem.Allocator) !*UserHandler {
        const self = try allocator.create(UserHandler);
        self.* = .{};
        return self;
    }
    pub fn handle(self: *UserHandler, ctx: *framework.Context, res: *framework.Response) !void {
        _ = self;
        try res.json(.{ .path = ctx.request.path });
    }
    pub fn deinit(self: *UserHandler) void {
        // 只释放内部资源；实例内存由框架销毁
        _ = self;
    }
};

const handler = try framework.Handler.initFactory(UserHandler, allocator);
defer handler.deinit();
try router.route(.GET, "/users/:id", handler);
```

## API 参考

### 路由 (Router)

```zig
router.route(.GET, "/users/:id", handler);       // 静态 / 动态路由
router.route(.GET, "/static/*", handler);        // 通配符
router.use(middleware);                          // 全局中间件（先注册 = 外层 = 先执行）
router.notFoundHandler(handler);                 // 自定义 404（仍走全局中间件管道）
```

### 请求上下文 (Context)

```zig
ctx.param("id");                 // 路径参数 /users/:id → "42"
ctx.query("page");               // Query 参数 ?page=1 → "1"（原始，未解码）
try ctx.queryDecoded("q");        // Query 参数（`+`→空格、`%XX`→字节，用 ctx.arena）
try ctx.formDecoded("name", 1<<20); // 读 body 后取表单字段并解码（urlencoded）
ctx.header("Content-Type");      // 请求头
ctx.request.getCookie("sid");    // Cookie
ctx.request.getHeader("X-Id");   // 请求头（Request 不可变）
ctx.readBody(allocator, limit);  // 请求体（首次读入后缓存；支持 Content-Length 与 chunked）
ctx.service(T);                  // 取应用级服务单例（SessionManager/Logger 等）
ctx.arena;                       // 请求级 arena（请求结束自动回收，无需 free）
ctx.failWith(res, app_err);      // 抛 AppError（ErrorRenderer 负责渲染）
ctx.getUserData(T);              // 取中间件通讯槽（按类型索引）
ctx.setUserData(T, ptr);         // 设中间件通讯槽
```

JSON 反序列化是 addon，用自由函数：

```zig
const LoginRequest = struct { username: []const u8, password: []const u8 };
const body = framework.parseJson(LoginRequest, ctx.arena, ctx.readBody(ctx.arena, 1 << 20) catch {
    try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
    return;
}) catch {
    try ctx.failWith(res, framework.AppError.badRequest("invalid JSON body"));
    return;
};
```

### 响应构建 (Response)

```zig
res.json(.{ .key = "value" });            // JSON
res.text("plain text");                   // 纯文本
res.html("<h1>Hello</h1>");               // HTML
res.raw(bytes, "application/octet-stream"); // 原始字节 + 指定 Content-Type
res.statusCode(.created).json(.{ ... });  // 链式调用
res.header("X-Custom", "value");          // 自定义头
res.setCookie("token", "abc123");         // Cookie
res.setCookieFull(.{ .name = "sid", .value = "x", .max_age = 0 }); // 完整 Cookie 控制
res.redirect("/new-path", false);         // 重定向（false=302, true=301）
res.redirectStatus("/new-path", .see_other); // 指定状态码（301/302/303/307/308）
res.stream(buffer, .{ .content_type = "text/plain" }); // 流式响应
```

### 中间件

中间件实现 `process(ctx, res, next) !void`，用 `Middleware.init` 包装后挂到 `router.use()`。
可以 `next.call` 之前做前置逻辑、之后做后置逻辑：

```zig
const TimingMiddleware = struct {
    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        _ = self;
        res.setBuffered(); // 缓冲模式：next() 之后还能改响应
        const start = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;
        next.call(ctx, res) catch |err| return err;
        const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
        _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
    }
};

var timing = TimingMiddleware{};
try router.use(framework.Middleware.init(TimingMiddleware, &timing));
```

框架内置中间件（都经 `router.use(...)` 全局挂载）：

```zig
// 错误渲染（放最外层，兜底所有 handler 抛出的错误，渲染 AppError）
var error_renderer = framework.ErrorRenderer{};
try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));

// 请求 ID（X-Request-Id 头）
var rid = framework.RequestIdMiddleware{};
try router.use(framework.Middleware.init(framework.RequestIdMiddleware, &rid));

// 响应压缩（Accept-Encoding: gzip/deflate，默认 >=1KB 才压缩）
var compress = framework.CompressMiddleware{ .config = .{} };
try router.use(framework.Middleware.init(framework.CompressMiddleware, &compress));

// 安全响应头
var security = framework.SecurityHeaders{ .config = .{} };
try router.use(framework.Middleware.init(framework.SecurityHeaders, &security));

// CORS（预检 OPTIONS 自动处理）
var cors = framework.CorsMiddleware{ .config = .{} };
try router.use(framework.Middleware.init(framework.CorsMiddleware, &cors));

// 限流（窗口内超过上限返回 429 + Retry-After）
var rate = framework.RateLimiter.init(allocator, io, .{
    .window_seconds = 60,
    .max_requests = 100,
    .per_ip = false, // per_ip=true 需在 Config.body 开 trust_proxy_headers
});
try router.use(framework.Middleware.init(framework.RateLimiter, &rate));

// 鉴权（Bearer / Basic / API Key / 自定义）
var auth = framework.AuthMiddleware{ .config = .{
    .bearer_token = "my-secret-token",
    .basic_username = "admin",
    .basic_password = "secret123",
} };
try router.use(framework.Middleware.init(framework.AuthMiddleware, &auth));
// 校验通过后，handler 用 ctx.getUserData(framework.AuthInfo) 取身份信息
//（strategy / token / username / api_key / roles）
```

### 错误处理 (AppError)

`AppError` = (HTTP 状态码, 消息)，`ErrorRenderer`（管道最外层）把 handler 抛出的错误转成响应：

```zig
// handler 里直接用：
try ctx.failWith(res, framework.AppError.notFound("user not found"));   // 404
try ctx.failWith(res, framework.AppError.unauthorized("bad token"));    // 401
try ctx.failWith(res, framework.AppError.forbidden("no access"));       // 403
try ctx.failWith(res, framework.AppError.badRequest("bad input"));      // 400
try ctx.failWith(res, framework.AppError.conflict("already exists"));   // 409
try ctx.failWith(res, framework.AppError.tooManyRequests("slow down")); // 429
// failWith 返回 error.AppError，会自动 return，无需再写 return
```

### 会话 (Session)

基于 Cookie 的内存 Session 存储（`std.Io.Mutex` 保护）：

```zig
var sessions = framework.SessionManager.init(allocator, io, .{
    .cookie_name = "sid",
    .session_timeout_sec = 3600,
});
defer sessions.deinit();

const session_id = try sessions.getOrCreate(ctx, res);   // 无 cookie 就新建并写 Set-Cookie
try sessions.setData(session_id, "username", body.username);
const data = sessions.getData(session_id) orelse ...;    // data.get("username")
// 登出：res.setCookieFull(.{ .name = "sid", .value = "deleted", .max_age = 0 })
```

### WebSocket

RFC 6455 实现（帧编解码 + 握手 + 连接级读写 + **连接劫持**）。`framework.wsUpgrade`
一步完成握手校验 + 注册劫持回调：handler 直接 return，`ConnectionRunner` 在 dispatch
结束后写 101 握手响应、构造 `WebSocket` 并调用你的回调接管连接。

```zig
fn wsRoute(ctx: *framework.Context, res: *framework.Response) !void {
    const upgraded = framework.wsUpgrade(ctx, res, @ptrCast(res), onWs) catch {
        try ctx.failWith(res, .{ .status = .bad_request, .message = "upgrade failed" });
        return;
    };
    if (!upgraded) return; // 非法升级请求（wsUpgrade 已写好 426/错误响应）
    // 升级成功：直接 return，后续由 onWs 回调接管连接。
}

// 连接回调：拿到已建好的 *WebSocket，跑 receive/send 循环，返回即关连接。
fn onWs(ws: *framework.WebSocket, hijack_ctx: *anyopaque) anyerror!void {
    _ = hijack_ctx;
    while (true) {
        var msg = ws.receive() catch |err| {
            if (err == error.ConnectionClosed or err == error.EndOfStream) return;
            return err;
        };
        defer msg.deinit();
        try ws.sendText(msg.payload); // echo（分片拼合、自动回 pong、帧长上限防 DoS）
    }
}
```

注册路由：`try router.route(.GET, "/ws", framework.Handler.fromFn(wsRoute));`
（可运行的完整 echo 示例见 `examples/src/main.zig` 的 `/ws` 路由。）

底层 API 也可单独使用：`framework.wsComputeAcceptKey`（计算 Accept）、
`framework.WebSocket.initServer/initClient`（连接级读写）、`framework.wsEncodeFrame/wsDecodeFrame`（单帧编解码）。

### 静态文件服务

```zig
var static_server = framework.StaticFileServer.init(allocator, io, "./public", "/static");
try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &static_server));
```

支持 ETag / `If-None-Match`（`*`/列表/`W/`）、`Last-Modified` / `If-Modified-Since`、304、
HEAD（只发头）、目录自动 index.html、大文件流式 + gzip、MIME 大小写不敏感。

### 结构化日志

```zig
var logger = try framework.Logger.init(allocator, io, .{
    .min_level = .info,
    .format = .json,
    .output = .file,
    .file = .{ .path = "log/app.log", .max_size = 2 * 1024 * 1024, .max_backups = 1, .compress = true },
});
defer logger.deinit();

logger.info(ctx, "user created", &.{
    framework.fstr("name", "alice"),
    framework.fint("id", 42),
    framework.ffloat("price", 9.9),
});
// 请求级结构化日志：注册 LoggingHook 到 server lifecycle
var log_hook = framework.LoggingHook{ .logger = &logger };
const hooks = [_]framework.Hook{ framework.Hook.init(framework.LoggingHook, &log_hook) };
server.setLifecycle(.{ .hooks = &hooks });
```

### 内置 ORM

基于 JSON 文件持久化，编译期反射自动推导表结构（`id` 字段自动成为主键并自增）：

```zig
const User = struct {
    id: u64 = 0,
    name: []const u8,
    email: []const u8,
};
const UserModel = framework.orm.Model(User, "users");
const UserStore = UserModel.Store;

const store = try UserStore.open(allocator, io, "./data");
defer store.close() catch {};

const id = try store.insert(.{ .id = 0, .name = "alice", .email = "alice@example.com" });
try store.flush(); // 改动只在内存，需显式 flush() 写回 JSON 文件

const rows = try store.all();                       // 全部行（用 store.allocator.free 释放）
defer store.allocator.free(rows);
const user = try store.findById(id);                // 按主键查找
const updated = try store.updateById(id, .{ .id = id, .name = "a2", .email = "a2@x.com" });
const deleted = try store.deleteById(id);
```

条件查询用 `framework.orm.Query(T)`：

```zig
var qb = framework.orm.Query(User).init(allocator);
defer qb.deinit();
_ = qb.where(.Eq, "name", .{ .string = "alice" }).orderBy("id", .Asc).limit(10).offset(0);
const matches = try store.findAll(&qb);  // 或 findOne / count / paginate(page, per_page)
```

## 示例

`examples/` 目录是一个完整、可运行的服务器，覆盖框架绝大部分功能：

| 路由 | 说明 |
|------|------|
| `GET /` `/health` `/greet` `/echo` `/users/:id` | 基础路由、路径参数、query 参数（解码） |
| `POST /form` | 表单解码（urlencoded，`+`/`%XX`） |
| `POST /login` `POST /api/items` | JSON body 解析 |
| `POST /upload` | multipart 文件上传 |
| `GET /static/*` | 静态文件（`./public`，ETag/304/HEAD） |
| `GET /compress` | 响应压缩（~80KB → 464B） |
| `GET /redirect` | 303 See Other 重定向 |
| `GET /errors/:kind` | AppError → 各 HTTP 状态码 |
| `POST /session/*` `GET /session/me` | 会话登录/登出/读取 |
| `GET /admin/secret` | Bearer Token 鉴权（仅 /admin 前缀） |
| `GET /rate-limit` | 限流（60s 窗口全局 30 次，超限 429） |
| `GET/POST /orm/users` `GET/PUT/DELETE /orm/users/:id` | ORM CRUD（持久化 `./data/users.json`） |

```bash
cd examples
zig build          # 构建
zig build run      # 运行（端口 9000）
zig build test     # 运行测试（含 WebSocket 内存往返测试）
```

示例头部注释有完整的 curl 测试清单。

## 项目结构

4 层核心各司其职，addon 单向依赖核心。依赖方向由 build.zig 模块边界在编译期强制。

```
http-framework/
├── build.zig              # 模块图定义（每个 addon 独立注册为模块）
├── build.zig.zon
├── src/
│   ├── root.zig           # 伞形聚合模块 http_framework（@import 一次拿全部能力）
│   ├── main.zig           # 框架自带示例（完整中间件管道）
│   ├── http_protocol/     # ── 第 1 层：字节 ↔ 报文 ──────────────
│   │   ├── request.zig    #    Request 解析（不可变）
│   │   ├── response.zig   #    Response / Sink / Cookie
│   │   └── conn_loop.zig  #    keep-alive 连接状态机
│   ├── http_app/          # ── 第 2 层：生命周期 + 管道 ──────────
│   │   ├── context.zig    #    Context / RequestState / RequestConfig
│   │   ├── handler.zig    #    Handler（union(enum)：func/singleton/factory）
│   │   ├── middleware.zig #    Middleware / Next / DynPipeline
│   │   ├── error.zig      #    AppError / ErrorRenderer
│   │   ├── lifecycle.zig  #    Hook / Lifecycle（请求生命周期事件）
│   │   ├── config.zig     #    分层配置 + RuntimeState + ServerStats
│   │   ├── request_id.zig #    RequestIdMiddleware
│   │   └── arena.zig      #    Arenas（请求级 arena 池）
│   ├── http_router/       # ── 第 3 层：radix-trie 路由 ──────────
│   │   ├── router.zig     #    Router（route / use / notFound / dispatch）
│   │   └── trie.zig       #    Trie（:param 与 * 通配匹配）
│   ├── http_server/       # ── 第 4 层：组装 ──────────────────
│   │   ├── connection.zig # 后端无关：ConnectionRunner（纯 HTTP 引擎）
│   │   ├── zio_server.zig # zio 专属：监听/accept/背压/信号/连接读写/启动（唯一 import zio）
│   │   └── integration_test.zig
│   ├── http_security/     # ── 依赖第 1、2 层的 addon ─────────────
│   │   ├── auth.zig       #    AuthMiddleware（bearer/basic/api_key/custom）
│   │   ├── cors.zig       #    CorsMiddleware
│   │   ├── csrf.zig       #    CsrfMiddleware
│   │   └── security_headers.zig
│   ├── http_session/      #    会话（Cookie + 内存存储 + Mutex）
│   ├── http_rate_limit/   #    限流（RateLimiter，429 + Retry-After）
│   ├── http_static/       #    静态文件服务（目录遍历防护）
│   ├── http_codec/        #    JSON 解析（parseJson）
│   ├── http_multipart/    #    multipart/form-data 解析
│   ├── http_compress/     #    响应压缩（gzip/deflate 流式）
│   ├── http_logging/      #    结构化日志（JSON/文本、文件轮转）
│   ├── http_orm/          #    ORM（编译期反射 + JSON 持久化）
│   └── http_websocket/    #    WebSocket（RFC 6455）
├── examples/              # 综合示例（见上文"示例"）
└── README.md
```

### 只依赖核心层

不需要 session、模板、WebSocket 等项目，可以只依赖核心 4 层模块：

```zig
// build.zig
const http_framework = b.dependency("http_framework", .{}).module("http_framework");
```

所有 addon 也都有独立模块名（`http_security`、`http_session`、`http_rate_limit`、
`http_static`、`http_codec`、`http_multipart`、`http_compress`、`http_logging`、
`http_orm`、`http_websocket`），按需 `b.dependency(...).module("...")` 导入即可。
核心层的 `http_protocol` 不依赖任何其它模块。

## 许可证

MIT
