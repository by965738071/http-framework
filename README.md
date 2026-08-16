# Zig HTTP Framework

基于 Zig `std.Io` 构建的高性能、轻量级 HTTP 服务器框架，支持请求级生命周期、灵活路由、中间件链、WebSocket、静态文件服务及内置 ORM。

## 性能

`oha -n 100000 -c 1000 http://127.0.0.1:9000/` (ReleaseFast)

```
Success rate:      100.00%   (100000/100000)
Requests/sec:      1504
平均响应 (P50):     7 ms
P90:               21 ms
P99:               58 ms
启动内存:            1.4 MB
压测后内存:          1.4 MB (无泄漏)
```

| 模式 | QPS | P50 | P99 | 每次请求分配 |
|------|-----|-----|-----|------------|
| `fromFn` (纯函数) | ~1500 | ~7ms | ~58ms | 零 |
| `initPerRequest` (请求级) | ~1500 | ~7ms | ~58ms | 1 次 create + 1 次 destroy |
| `init` (单例) | ~1500 | ~7ms | ~58ms | 零 |

> `initPerRequest` 的开销可忽略不计——在 1000 并发、10 万请求下，P10 响应时间 0.1ms，与纯函数和单例模式几乎一致。

## 核心功能

- **三种处理器模式** — 请求级（每次请求创建/销毁）、单例（零分配）、纯函数（零开销）
- **动态路由** — 支持 `/users/:id` 路径参数、通配符 `/static/*`、路由分组
- **中间件链** — Auth（Bearer/Basic/API Key）、CORS、RateLimiter、日志等
- **WebSocket** — 握手升级、消息收发、心跳与广播
- **静态文件服务** — 内置目录遍历防护
- **HTTP keep-alive** — 同一连接循环处理多个请求
- **内置 ORM** — JSON 文件持久化，支持 CRUD、查询、排序、分页
- **安全与扩展** — CSRF、Security Headers、Session、Multipart、模板引擎、指标、OpenAPI 等（见 `src/root.zig`）
- **模块化架构** — `core` 只做 HTTP 解析 / 路由 / 请求 / 响应，其余全是单向依赖 core 的 addon，
  依赖方向由构建系统在编译期强制（见[项目结构](#项目结构)）

## 环境要求

- **Zig**: `0.17.0-dev` 或更新版（使用 `std.Io` API）

```bash
# 开发模式
zig build run

# 发布模式
zig build run -Doptimize=ReleaseFast

# 运行测试
zig build test

# 运行示例
cd examples && zig build run
```

## 快速开始

```zig
const std = @import("std");
const http_framework = @import("http_framework");

const Server = http_framework.Server;
const Router = http_framework.Router;
const RequestContext = http_framework.RequestContext;
const Response = http_framework.Response;
const Handler = http_framework.Handler;
const Config = http_framework.Config;

/// 请求级处理器
const GreetingHandler = struct {
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator) !*GreetingHandler {
        const ptr = try allocator.create(GreetingHandler);
        ptr.* = .{ .name = "Zig" };
        return ptr;
    }

    pub fn handle(self: *GreetingHandler, ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        try res.json(.{ .greeting = "Hello, {s}!", .name = self.name });
    }

    pub fn deinit(self: *GreetingHandler) void {
        // 释放内部资源，不需要调 allocator.destroy(self)
        // 框架的 VTable destroy 会统一处理
        _ = self;
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/", Handler.initPerRequest(GreetingHandler, allocator));

    const config = Config.defaults();
    var server = try Server.init(allocator, io, config, router);
    defer server.deinit();
    try server.run();
}
```

## 三种 Handler 模式对比

| 模式 | 工厂函数 | 生命周期 | 分配开销 | 适用场景 |
|------|---------|---------|---------|---------|
| **纯函数** | `fromFn` | 无状态，全局共享 | 零 | 简单的请求处理、404 等 |
| **单例** | `init(T, ptr)` | main 创建，程序退出销毁 | 仅启动时一次 | 全局配置、连接池、计数器 |
| **请求级** | `initPerRequest(T, alloc)` | 每次请求创建/销毁 | 每次 2 次分配 | 请求隔离状态、上下文数据 |

> **`initPerRequest` 的 deinit 规则**: 只释放内部字段（如 `allocator.free`），**不要**调 `allocator.destroy(self)`——框架的 VTable destroy 会自动处理。

### 纯函数模式 (零开销)

```zig
router.notFound(Handler.fromFn(struct {
    fn handler(ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        try res.statusCode(.not_found).text("404 Not Found");
    }
}.handler));
```

### 单例模式 (零分配)

```zig
const MyHandler = struct {
    counter: std.atomic.Value(u64),

    pub fn handle(self: *MyHandler, ctx: *RequestContext, res: *Response) !void {
        const count = self.counter.fetchAdd(1, .monotonic);
        try res.json(.{ .request_count = count });
    }
};

var handler = try allocator.create(MyHandler);
handler.* = .{ .counter = std.atomic.Value(u64).init(0) };
defer allocator.destroy(handler);

try router.route(.GET, "/count", Handler.init(MyHandler, handler));
```

### 带参数的请求级处理器

使用 `initPerRequestWith` 在注册时传入配置参数。

```zig
const UserHandler = struct {
    default_name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, args: anytype) !*UserHandler {
        const ptr = try allocator.create(UserHandler);
        const name_dup = try allocator.dupe(u8, args.default_name);
        ptr.* = .{ .allocator = allocator, .default_name = name_dup };
        return ptr;
    }

    pub fn handle(self: *UserHandler, ctx: *RequestContext, res: *Response) !void {
        const user_id = ctx.getParam("id") orelse "unknown";
        try res.json(.{ .user_id = user_id, .name = self.default_name });
    }

    pub fn deinit(self: *UserHandler) void {
        self.allocator.free(self.default_name);
    }
};

try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
    UserHandler, allocator, .{ .default_name = "John Doe" },
));
```

## API 参考

### 路由

```zig
router.route(.GET, "/users/:id", handler);       // 静态/动态路由
router.route(.GET, "/static/*", handler);        // 通配符
router.routeWithMiddleware(.GET, "/admin", handler, &.{auth_middleware});
router.notFound(handler);                         // 404 处理器
router.onError(errorHandler);                     // 分发错误处理器
router.group("/api/v1", &.{middleware});          // 路由分组
```

### 请求上下文 (RequestContext)

```zig
ctx.getParam("id");          // 路径参数 /users/:id → "42"
ctx.getQuery("page");        // Query 参数 ?page=1 → "1"
ctx.getHeader("Content-Type"); // 请求头
ctx.getCookie("session");    // Cookie
ctx.getForm("username");     // Form 字段
ctx.readBody();              // 请求体原始数据
```

反序列化和 multipart 不在 core 里——它们是 addon，以自由函数形式提供：

```zig
var parsed = try codec.bodyAs(CreateUser, ctx);  // JSON / form-urlencoded
defer parsed.deinit();

var form = try multipart.from(ctx);              // multipart/form-data
defer form.deinit();
```

### 响应构建 (Response)

```zig
res.json(.{ .key = "value" });           // JSON
res.html("<h1>Hello</h1>");              // HTML
res.text("plain text");                  // 纯文本
res.file(content, "image/png");          // 文件
res.redirect("/new-path", false);        // 重定向
res.statusCode(.created).json(.{ ... }); // 链式调用
res.header("X-Custom", "value");         // 自定义头
res.setCookie("token", "abc123");        // Cookie
```

### 中间件

自定义中间件实现 `process` 方法，用 `Middleware.init` 包装，再通过 `routeWithMiddleware` 挂载：

```zig
const Middleware = http_framework.Middleware;
const NextAction = http_framework.Middleware.NextAction;

const LoggingMiddleware = struct {
    pub fn process(_: *@This(), ctx: *RequestContext) anyerror!NextAction {
        std.log.info("[LOG] {s} {s}", .{ @tagName(ctx.method), ctx.path });
        return .next;
    }
};

var logging = LoggingMiddleware{};
const log_mw = Middleware.init(LoggingMiddleware, &logging);

try router.routeWithMiddleware(.GET, "/api/hello", handler, &.{log_mw});
```

框架内置中间件：

```zig
// 认证（Bearer / Basic / API Key）
var auth = try http_framework.AuthMiddleware.create(allocator, .{
    .bearer_token = "my-secret-token",
    .basic_username = "admin",
    .basic_password = "secret123",
});
defer auth.deinit();

// CORS
var cors = try http_framework.CorsMiddleware.init(allocator, .{
    .allowed_origins = &.{"*"},
    .allowed_methods = &.{ .GET, .POST },
});
defer cors.deinit();

// 限流（100 req/min）
var rate_limiter = try http_framework.RateLimiter.RateLimiter.init(allocator, io, .{
    .window_seconds = 60,
    .max_requests = 100,
});
defer rate_limiter.deinit();

try router.routeWithMiddleware(.GET, "/api/limited", handler, &.{rate_limiter.middleware});
```

### WebSocket

```zig
var ws_manager = http_framework.WebSocketManager.init(allocator, io);
defer ws_manager.deinit();

// 注册 WebSocket 处理器（单例模式）
var ws_echo = try http_framework.WsEchoHandler.init(allocator, &ws_manager);
defer ws_echo.deinit();
try router.route(.GET, "/ws", http_framework.Handler.init(http_framework.WsEchoHandler, ws_echo));

// 处理器内部使用
const socket = try ws_manager.handle(ctx, request);
defer ws_manager.close(&socket, .normal_closure);
try ws_manager.sendText(&socket, "Hello");
const msg = try ws_manager.readText(&socket, &buffer);
```

### 静态文件服务

```zig
var static_server = http_framework.Static.init(allocator, io, "./public", "/static");
try router.route(.GET, "/static/*", http_framework.Handler.init(http_framework.Static, &static_server));
```

### 内置 ORM

基于 JSON 文件持久化，使用编译期反射自动推导表结构：

```zig
const orm = @import("http_framework").orm; // 或 @import("http_orm")

const User = struct {
    id: u64 = 0,
    username: []const u8,
    email: []const u8,
};

const UserModel = orm.Model(User, "users");
const UserStore = UserModel.Store;

var store = try UserStore.open(allocator, io, "./data");
defer store.close() catch {};

const id = try store.insert(.{ .id = 0, .username = "alice", .email = "alice@example.com" });

var qb = orm.Query(User).init(allocator);
defer qb.deinit();
const user = try store.findOne(qb.where(.Eq, "username", .{ .string = "alice" }));
```

完整示例见 `examples/src/user_management.zig`（含分页、排序、密码哈希的用户管理系统）。

## 示例

`examples/` 目录包含完整可运行的示例：

| 文件 | 说明 |
|------|------|
| `server.zig` | 综合演示服务器（Auth/CORS/RateLimiter/WebSocket/静态文件） |
| `api_server.zig` | REST API + Session + 文件上传 |
| `basic_server.zig` | 最小服务器 |
| `fullstack_app.zig` | 全栈应用（HTML + API） |
| `middleware_demo.zig` | 中间件链演示 |
| `user_management.zig` | 用户管理系统（ORM） |
| `websocket.zig` | WebSocket 聊天演示 |

```bash
cd examples
zig build          # 构建所有示例
zig build run      # 运行 server
zig build run-user-mgmt  # 运行用户管理系统
zig build test     # 运行集成测试
```

## 项目结构

`core` 是最小 HTTP 服务器，其余目录都是**依赖 core 的 addon**。
依赖方向由 build.zig 的模块边界在编译期强制——core 里写一句
`@import("session")` 会直接编译失败，不是靠约定。

```
http-framework/
├── build.zig              # 模块图定义（core + 各 addon 独立注册）
├── build.zig.zon
├── src/
│   ├── main.zig           # 程序入口和路由注册示例
│   ├── root.zig           # 伞形聚合模块 http_framework
│   ├── api/               # 示例处理器
│   ├── core/              # ── 模块 `core`（零依赖）──────────────
│   │   ├── root.zig       # 模块入口
│   │   ├── server.zig     # HTTP 服务器 (keep-alive)
│   │   ├── router.zig     # 路由引擎 (:id 动态参数)
│   │   ├── request.zig    # 请求上下文
│   │   ├── response.zig   # 响应构建器
│   │   ├── handler.zig    # Handler 接口 (三种模式)
│   │   ├── middleware.zig # 中间件接口
│   │   ├── config.zig     # 服务器配置
│   │   ├── log.zig        # Logger 接口（扩展点）
│   │   ├── observer.zig   # RequestObserver 接口（扩展点）
│   │   └── worker.zig     # Worker 接口（扩展点）
│   ├── codec/             # ── 依赖 core 的 addon ────────────────
│   ├── multipart/         #    multipart/form-data 解析
│   ├── security/          #    Auth、CORS、CSRF、Security Headers
│   ├── observability/     #    FileLogger、Metrics、OpenAPI
│   ├── background/        #    后台任务队列
│   ├── session/           #    Session 管理
│   ├── static/            #    静态文件服务器
│   ├── rate_limit/        #    限流（RateLimiter、TokenBucket）
│   ├── protocol/          #    WebSocket（HTTP/2 在 experimental）
│   ├── policy/            # ── 独立工具模块（不依赖 core）────────
│   ├── template/          #    模板引擎（engine 在 experimental）
│   ├── pool/              #    通用连接池
│   ├── orm/               #    内置 ORM (JSON 持久化)
│   └── test/              # 集成测试
├── examples/              # 可运行示例
├── scripts/scaffold.zig   # 项目脚手架工具
└── README.md
```

### 只依赖 core

不需要 session、模板、WebSocket 的项目，可以只依赖 `core`：

```zig
// build.zig
const core = b.dependency("http_framework", .{}).module("core");
exe.root_module.addImport("core", core);
```

```zig
const core = @import("core");

var router = core.Router.init(allocator);
defer router.deinit();
try router.route(.GET, "/", core.Handler.fromFn(home));

var server = try core.Server.init(allocator, io, .{}, &router);
defer server.deinit();
try server.run();
```

需要什么再加什么：`codec`（JSON 反序列化）、`security`（CORS/鉴权）、
`observability`（文件日志/指标）……每个都是独立模块。

### core 的三个扩展点

core 不认识任何具体实现，只认三个接口：

| 接口 | 用途 | 注入方式 | 典型实现 |
|------|------|----------|----------|
| `Logger` | 写一行日志 | `server.setLogger(x)` | `observability.FileLogger` |
| `RequestObserver` | 请求完成后的观测点 | `server.setObserver(x)` | `observability.MetricsCollector` |
| `Worker` | 周期性后台任务 | `server.setWorker(x)` | `background.BackgroundQueue` |

```zig
var file_logger = try FileLogger.init(allocator, io, "log/app.log", .{ .async_enabled = true });
defer file_logger.deinit();
server.setLogger(file_logger.logger());

var metrics = MetricsCollector.init(allocator, io);
defer metrics.deinit();
server.setObserver(metrics.observer());
```

CORS、鉴权、限流这类横切逻辑一律走 `router.use()` 全局中间件，
Server 不为任何具体 addon 开专用钩子：

```zig
var cors = try CorsMiddleware.init(allocator, .{ .allowed_origins = &.{"*"} });
defer cors.deinit();
try router.use(&.{cors.middleware});   // 路由匹配之前执行，OPTIONS 预检照样绕过路由表
```

## 脚手架

快速生成新项目：

```bash
zig run scripts/scaffold.zig -- new my-app --name "My App"
cd my-app
zig build   # 首次会提示 build.zig.zon 缺失 .fingerprint，按提示值补上
zig build run
```

## 许可证

MIT
