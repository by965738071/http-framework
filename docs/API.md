# http_framework API 文档

> 面向使用者的公开 API 手册。所有 `路径:行号` 引用均相对仓库根目录（`/Users/by/project/zig/wlw/http-framework`），行号基于当前工作树。
>
> 三个前提，先记住：
> - **没有 `App` 类型**，`framework.Server` 就是应用本体。
> - `io: std.Io` 必须来自 zio 运行时（由 `framework.runZio` 提供），用户代码里只是透传值，不需要自己 import zio。
> - 框架**没有模板引擎、没有 sqlite/pg 封装、没有配置文件加载器**（见「[缺少的能力](#15-缺少的能力)」）。

## 目录

- [1. 快速上手](#1-快速上手)
  - [1.1 依赖接线](#11-依赖接线)
  - [1.2 最小可运行 server](#12-最小可运行-server)
  - [1.3 装配顺序](#13-装配顺序)
- [2. 应用装配与配置](#2-应用装配与配置)
  - [2.1 Server 生命周期](#21-server-生命周期)
  - [2.2 优雅关机](#22-优雅关机)
  - [2.3 配置结构](#23-配置结构)
  - [2.4 三个无效果的配置项](#24-三个无效果的配置项)
  - [2.5 服务容器（依赖注入）](#25-服务容器依赖注入)
- [3. 路由](#3-路由)
  - [3.1 Router API](#31-router-api)
  - [3.2 HTTP 方法](#32-http-方法)
  - [3.3 路径语法](#33-路径语法)
  - [3.4 路由分组](#34-路由分组)
  - [3.5 404 / 405](#35-404--405)
  - [3.6 静态文件服务](#36-静态文件服务)
- [4. Handler](#4-handler)
- [5. Context 与请求](#5-context-与请求)
- [6. 响应](#6-响应)
- [7. 中间件](#7-中间件)
- [8. 会话与鉴权](#8-会话与鉴权)
- [9. WebSocket](#9-websocket)
- [10. ORM](#10-orm)
- [11. 错误处理](#11-错误处理)
- [12. 其他能力](#12-其他能力)
- [13. 生命周期钩子](#13-生命周期钩子)
- [14. 硬约束与陷阱](#14-硬约束与陷阱)
- [15. 缺少的能力](#15-缺少的能力)
- [16. 文档与实现不一致](#16-文档与实现不一致)
- [17. API 速查表](#17-api-速查表)
- [附录：推荐分层惯例](#附录推荐分层惯例)

---

## 1. 快速上手

### 1.1 依赖接线

框架把每个 addon 注册成独立模块（`build.zig:32-219`：`http_protocol` / `http_app` / `http_router` / `http_server` / `http_security` / `http_session` / `http_rate_limit` / `http_static` / `http_codec` / `http_multipart` / `http_compress` / `http_logging` / `http_orm` / `http_websocket`），消费者只接伞形模块 `http_framework` 即可（`build.zig:222`）。

```zig
// build.zig.zon（抄 examples/build.zig.zon）
.dependencies = .{
    .http_framework = .{ .path = "../" },
},
.minimum_zig_version = "0.17.0-dev.889+e6be5cfe3",
```

```zig
// build.zig（examples/build.zig:27-31）
const http_framework_dep = b.dependency("http_framework", .{ .target = target, .optimize = optimize });
const http_framework_mod = http_framework_dep.module("http_framework");
```

### 1.2 最小可运行 server

入口模板来自 `src/main.zig:10-85` 与 `examples/src/main.zig:103-420`，可直接照抄：

```zig
const std = @import("std");
const framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    // runZio = 启动 zio 运行时，并在其协程上下文里跑 appMain
    try framework.runZio(init.gpa, appMain);
}

fn appMain(io: std.Io, allocator: std.mem.Allocator) !void {
    const config = framework.Config{
        .network = .{ .port = 9000 },
        .http = .{ .server_name = "my-app" },
        .body = .{ .size_limit = 10 * 1024 * 1024 },
        .pool = .{ .request_arena_retain_bytes = 4 * 1024 },
    };

    var router = try framework.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/", framework.Handler.fromFn(helloHandler));
    router.notFoundHandler(framework.Handler.fromFn(notFoundHandler));

    var server = try framework.Server.init(allocator, io, config, &router);
    defer server.deinit();
    try server.setup(); // 建 listener（端口占用在这里失败）
    server.setLifecycle(.{ .hooks = &hooks }); // 可选
    server.setServices(&services); // 可选（ctx.service(T) 依赖它）
    try server.run(); // 阻塞：accept + 等 SIGINT/SIGTERM
}

fn helloHandler(ctx: *framework.Context, res: *framework.Response) !void {
    _ = ctx;
    try res.json(.{ .message = "hello" });
}

fn notFoundHandler(ctx: *framework.Context, res: *framework.Response) !void {
    _ = ctx;
    try res.statusCode(.not_found).text("Not Found");
}
```

### 1.3 装配顺序

`examples/src/main.zig:116-420` 的固定顺序，照抄不易踩坑：

```
config → logger/sessions/stores（main 栈上，defer 管理） → services 注册 + seal
→ Router.init → 全局中间件（ErrorRenderer 必须第一个） → 路由 → 路由组（use 先于 route）
→ notFoundHandler → Hook 数组 → Server.init → setup → setLifecycle → setServices → run
```

---

## 2. 应用装配与配置

### 2.1 Server 生命周期

关键符号（`src/http_server/root.zig:15-19` 导出）：

| API | 位置 | 说明 |
|---|---|---|
| `framework.runZio` | `src/http_server/zio_server.zig:21` | `fn(allocator, comptime appFn: fn(std.Io, std.mem.Allocator) anyerror!void) !void`；内部 1MB 提交栈（`:31-36`） |
| `framework.Server` | `src/http_server/zio_server.zig:66` | = `zio_server.Server` |
| `Server.init(allocator, io, config, router) !Server` | `zio_server.zig:82` | `io` 必须来自 zio 协程上下文 |
| `Server.setup() !void` | `zio_server.zig:99` | 建 listener；**必须在 `run` 前调用**；失败时 `deinit` 安全 |
| `Server.run() !void` | `zio_server.zig:147` | 阻塞主循环 |
| `Server.setLifecycle(Lifecycle) void` | `zio_server.zig:119` | 请求日志/埋点，见「[生命周期钩子](#13-生命周期钩子)」 |
| `Server.setServices(*const Services) void` | `zio_server.zig:123` | `ctx.service(T)` 依赖它 |
| `Server.stats() ServerStats` | `zio_server.zig:127` | `active_connections / total_connections / active_requests / accept_errors / shutting_down` |
| `Server.deinit() void` | `zio_server.zig:114` | |

### 2.2 优雅关机

**信号驱动，无程序化 stop API。** `run()` 内部：

1. spawn accept 协程；
2. 当前协程 `select` 等 **SIGINT 或 SIGTERM**（`zio_server.zig:185-216`，两者都注册，`docker stop` 走 SIGTERM 同样生效）；
3. 置 `shutting_down` → cancel accept → **先 drain（在途请求自然完成，上限 30s，硬编码 `:220`）→ 再强制 cancel**。

因此 `Ctrl-C` / `docker stop` 即优雅关机，无需写代码。没有 `server.stop()` 这类从 handler 内触发关机的接口。

### 2.3 配置结构

`src/http_app/config.zig`：

```zig
pub const Config = struct {            // config.zig:11
    network: NetworkConfig = .{},
    http:    HttpConfig    = .{},
    body:    BodyConfig    = .{},
    pool:    PoolConfig    = .{},
};

pub const NetworkConfig = struct {     // config.zig:18
    address: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    tcp_backlog: u31 = 4096,
    reuse_address: bool = false,
    max_connections: u32 = 1024,             // 背压信号量；=0 时 setup 直接报 error.MaxConnectionsZero
    idle_timeout_ns: u64 = 60_000_000_000,   // ⚠️ 未实现，见 2.4
    read_timeout_ns: u64 = 30_000_000_000,   // 单次读超时（zio per-operation）
    write_timeout_ns: u64 = 30_000_000_000,
};

pub const HttpConfig = struct {        // config.zig:34
    server_name: []const u8 = "ZigHTTP",     // 会写 Server: 头（connection.zig:158）
    keep_alive_enabled: bool = true,
    read_buffer_size: usize = 16384,
    write_buffer_size: usize = 8192,
    access_log_enabled: bool = false,        // ⚠️ 未实现，见 2.4
};

pub const BodyConfig = struct {        // config.zig:42
    size_limit: u64 = 10 * 1024 * 1024,
    lazy_read_size: u64 = 0,                // ⚠️ 未实现，见 2.4
    trust_proxy_headers: bool = false,      // 影响 RequestConfig.trust_proxy
};

pub const PoolConfig = struct {        // config.zig:48
    request_arena_retain_bytes: usize = 16 * 1024,
};
```

**不存在的配置项**：TLS/HTTPS、header 数量上限、header 单行长度上限、Handler 级路由超时。请求头过大时 std 报 `HeadTooLarge`，框架回 431（`conn_loop.zig:56`）；阈值由 `http.read_buffer_size` 间接决定（`connection.zig:48` 用默认 `http.Server.init`，缓冲区来自 `zio_server.zig:278`）。

**没有配置文件加载器**：无 `.env` / `toml` / `json` 读取，配置就是 Zig 编译期字面量。

### 2.4 三个无效果的配置项

`setup()` 时会打 warn（`src/http_server/zio_server.zig:102-110`）：

```zig
if (self.config.body.lazy_read_size != 0)
    std.log.warn("config: body.lazy_read_size is set but not implemented (no effect)", .{});
if (self.config.network.idle_timeout_ns != 60_000_000_000)
    std.log.warn("config: network.idle_timeout_ns is not implemented; keep-alive idle is bounded by read_timeout_ns", .{});
if (self.config.http.access_log_enabled)
    std.log.warn("config: http.access_log_enabled has no effect; register a LoggingHook/LoggingMiddleware for access logs", .{});
```

即：`body.lazy_read_size`、`network.idle_timeout_ns`、`http.access_log_enabled` 三项设了不生效。访问日志请挂 `LoggingHook` 或 `LoggingMiddleware`（见「[其他能力](#12-其他能力)」）。

### 2.5 服务容器（依赖注入）

`framework.Services`（`src/http_app/services.zig:20`）——按类型索引的进程级指针容器：

```zig
var services = framework.Services.init(allocator);
defer services.deinit();
try services.register(framework.Logger, &logger);
try services.register(framework.SessionManager, &sessions);
try services.register(UserStore, store);
try services.register(admin.AdminServices, &admin_services);
services.seal();               // 封箱，之后 register 返回 error.ServicesSealed
server.setServices(&services); // 注入
```

handler / 中间件里取回：

```zig
const sm = ctx.service(framework.SessionManager) orelse {
    try ctx.failWith(framework.AppError.internal("session service unavailable"));
    return;
};
```

> `Services` 只存指针、不接管所有权，实例生命周期由 `main` 的 `defer` 管理。
> `seal()`（`services.zig:55`）不是线程同步原语，只是把「启动后误注册」变成显式失败。

---

## 3. 路由

### 3.1 Router API

`src/http_router/router.zig:96`：

```zig
pub fn init(allocator: std.mem.Allocator) !Router                                                  // :106
pub fn deinit(self: *Router) void                                                                  // :114
pub fn route(self: *Router, method: std.http.Method, pattern: []const u8, handler: Handler) !void  // :140
pub fn use(self: *Router, mw: Middleware) !void                                                    // :145 全局中间件
pub fn group(self: *Router, prefix: []const u8) !RouteGroup                                        // :156
pub fn notFoundHandler(self: *Router, handler: Handler) void                                       // :165 注意：无 try
pub fn dispatch(self: *const Router, ctx: *Context, res: *Response) !bool                          // :182（框架内部用）
```

### 3.2 HTTP 方法

用 `std.http.Method` 枚举（`trie.zig:33` 是 `EnumMap(http.Method, Route)`），`GET / HEAD / POST / PUT / DELETE / CONNECT / OPTIONS / TRACE / PATCH` 全部可注册。

- **HEAD 自动回退 GET**：`router.zig:198-204`。
- **405 自动带 `Allow` 头**：`router.zig:211-238`（`methodNotAllowedHandler`）。
- **冲突注册**返回 `error.RouteConflict`（`trie.zig:93`）。

### 3.3 路径语法

`trie.zig:73-151`：

| 语法 | 含义 | 取值 |
|---|---|---|
| `/users/:id` | 命名参数 | `ctx.param("id")` / `ctx.paramDecoded("id")` |
| `/static/*` | catch-all | `ctx.param("*")`（**参数名就是字面量 `"*"`**，见 `static.zig:55`） |
| 路径段上限 | 64（`router.zig:73`） | 超限按 404 处理 |
| pattern 参数上限 | 16 个绑定（`context.zig:50` CAP） | |

注册时校验（`trie.zig:130`）：catch-all 必须是最后一段（否则 `error.InvalidRoute`）；`:` 后必须有名字。

### 3.4 路由分组

`RouteGroup`（`router.zig:36`）：

```zig
var admin = try router.group("/admin");                       // :156，prefix 拷进 router.arena
try admin.use(framework.Middleware.init(Auth, &auth));        // :42 组级中间件
try admin.route(.GET, "/users", h);                           // → /admin/users
try admin.route(.GET, "/users/:id", h);                       // → /admin/users/:id
var v1 = try admin.group("/v1");                              // :63 嵌套，继承父组中间件
```

**执行顺序**（`router.zig:243-257`）：`全局中间件（按 use 顺序）→ 组级中间件（外层组先于内层组）→ handler`。

> ⚠️ **关键陷阱**：全局 `use` 在 dispatch 时才读列表，对所有路由生效、与注册先后无关；而**组级 `use` 只对它之后注册的路由生效**（`RouteGroup.use` 重建切片，`route()` 注册时快照当时的切片）。必须 `use` 在前、`route` 在后。

示例里的绕法（`examples/src/main.zig:318-362`）：用 `admin.group("")` 建同前缀子组，把不同中间件集挂到不同路由子集上。

```zig
var admin_routes = try router.group("/admin");
try admin_routes.route(.GET, "/", framework.Handler.initSingleton(admin.LoginPageHandler, &login_page_handler));
{
    var admin_session_routes = try admin_routes.group("");
    try admin_session_routes.use(admin.requireAuth(&admin_services));   // 先 use
    try admin_session_routes.route(.GET, "/users", framework.Handler.initSingleton(admin.UserListHandler, &user_list_handler));
    try admin_session_routes.route(.GET, "/users/:id", framework.Handler.initSingleton(admin.UserGetHandler, &user_get_handler));
}
try admin_routes.route(.GET, "/*", framework.Handler.initSingleton(framework.StaticFileServer, &admin_static)); // SPA 兜底
```

### 3.5 404 / 405

`router.notFoundHandler(handler)` 返回 `void`（不是 `!void`）。**404/405 会走全局中间件管道，但不走组级中间件**（`router.zig:207-239`）。默认 404 是纯文本 `Not Found`（`router.zig:281`）。

### 3.6 静态文件服务

```zig
// src/http_static/static.zig:19
pub const StaticFileServer = struct {
    pub fn init(allocator, io, root_dir: []const u8, url_prefix: []const u8) StaticFileServer  // :25
    pub fn handle(self: *const StaticFileServer, ctx: *Context, res: *Response) !void          // :54
};
```

挂载（`examples/src/main.zig:274-275`）：

```zig
var static_server = framework.StaticFileServer.init(allocator, io, "./public", "/static");
try router.route(.GET, "/static/*", framework.Handler.initSingleton(framework.StaticFileServer, &static_server));
```

特性：路径遍历防护（先 decode 再校验 `..` 段，`static.zig:63-90`）、ETag / `If-None-Match`、Last-Modified、304、HEAD、目录自动 `index.html`、>1MB 流式 + gzip。

---

## 4. Handler

**统一签名**：`fn (*Context, *Response) anyerror!void`（`handler.zig:22`）。

```zig
// src/http_app/handler.zig:20
pub const Handler = union(enum) {
    func:      *const fn (*Context, *Response) anyerror!void,
    singleton: Singleton,   // { ptr, call }
    factory:   Factory,     // { ctx, create, handle, destroy, deinit_ctx }
    pub fn fromFn(comptime func: *const fn (*Context, *Response) anyerror!void) Handler   // :46
    pub fn initSingleton(comptime T: type, ptr: *T) Handler                                // :51  T 需 handle(ctx,res)
    pub fn initFactory(comptime T: type, allocator: std.mem.Allocator) !Handler            // :75  T 需 init/handle/deinit
    pub fn dispatch(self: Handler, ctx: *Context, res: *Response) !void                    // :121
    pub fn deinit(self: Handler) void                                                      // :136
};
```

| 模式 | 构造 | 生命周期 | 适用 |
|---|---|---|---|
| `fromFn` | `Handler.fromFn(f)` | 零分配 | 无状态 handler、404 |
| `initSingleton` | `Handler.initSingleton(T, &instance)` | 实例由你持有；`Handler.deinit` 对 singleton 是 **no-op**（`handler.zig:138`），**框架不销毁它** | 有状态服务（store / logger 注入） |
| `initFactory` | `try Handler.initFactory(T, allocator)` | 每请求 create / deinit / destroy | 请求隔离状态 |

> ⚠️ **factory 所有权铁律**（`handler.zig:66-74`）：一旦注册进 Router，释放责任归 `router.deinit()`。再写 `defer handler.deinit()` = double-free（`examples/src/main.zig:254-261` 有注释与回归测试 `:1044`）。
>
> ⚠️ **`initFactory` 的 `T.deinit()` 里不要 `allocator.destroy(self)`** —— 框架在 `deinit()` 之后统一 destroy（`handler.zig:92-99`）。

单例 handler 典型写法（后台管理 demo 推荐，抄 `examples/src/admin.zig:587-696`）：

```zig
pub const UserListHandler = struct {
    services: *AdminServices,
    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return userListHandler(ctx, res, self.services);
    }
};
// 注册：main 里声明 var，保持稳定地址
var user_list_handler = admin.UserListHandler{ .services = &admin_services };
try g.route(.GET, "/users", framework.Handler.initSingleton(admin.UserListHandler, &user_list_handler));
```

---

## 5. Context 与请求

`src/http_app/context.zig:189`

### 5.1 字段

```zig
pub const Context = struct {          // context.zig:189
    request: *const Request,          // :192 不可变
    state:   *RequestState,           // :193 可变（路由输出 + 通讯槽 + hijack）
    config:  *const RequestConfig,    // :194 { trust_proxy, body_size_limit, lazy_read_size }
    arena:   std.mem.Allocator,       // :195 请求级 arena，请求结束统一回收，无需 free
    io:      std.Io,                  // :196
    services: ?*const Services = null,// :200
    peer_ip:  ?std.Io.net.IpAddress = null, // :204
```

### 5.2 Context 方法表

| 方法 | 行号 | 签名 |
|---|---|---|
| `peerIpString` | 210 | `fn(self: *const Context, buf: []u8) ?[]const u8`（buf ≥64 字节；IPv4 点分十进制，IPv6 32 位 hex） |
| `service` | 224 | `fn(self: *const Context, comptime T: type) ?*T` |
| `readBody` | 232 | `fn(self: *Context, allocator, limit: u64) ![]const u8`（首次读并缓存到 `state.body_buffer`，重复调用返回同一份） |
| `param` | 240 | `fn(self: *const Context, name: []const u8) ?[]const u8`（原始，未解码） |
| `paramDecoded` | 257 | `fn(self: *const Context, name: []const u8) !?[]const u8`（RFC 3986：`%XX`→字节，`+` 保持字面量，用 `ctx.arena`） |
| `header` | 263 | `fn(self: *const Context, name: []const u8) ?[]const u8` |
| `query` | 268 | `fn(self: *const Context, key: []const u8) ?[]const u8`（原始） |
| `queryDecoded` | 273 | `fn(self: *const Context, key: []const u8) !?[]const u8`（`+`→空格） |
| `form` | 279 | `fn(self: *Context, key: []const u8, limit: u64) !?[]const u8`（读 body 后取 urlencoded 字段，原始） |
| `formDecoded` | 285 | `fn(self: *Context, key: []const u8, limit: u64) !?[]const u8`（解码版；后台管理 CRUD 都用它） |
| `getUserData` | 291 | `fn(self: *const Context, comptime T: type) ?*T` |
| `setUserData` | 295 | `fn(self: *Context, comptime T: type, ptr: *T) !void` |
| `hijack` | 303 | `fn(self: *Context, hijack_ctx: *anyopaque, run: *const fn(*anyopaque, std.Io, *std.Io.Reader, *std.Io.Writer, std.mem.Allocator) anyerror!void) void` |
| `fail` | 317 | `fn(self: *Context, res: *Response, status: std.http.Status, message: []const u8) !void`（直写响应，**绕开 ErrorRenderer**，仅应急） |
| `failWith` | 330 | `fn(self: *Context, app_err: AppError) !void` —— **返回 `error.AppError`，推荐路径** |

### 5.3 Request 上可直接用的

经 `ctx.request`（`src/http_protocol/request.zig`）。字段（`:25-41`）：`method / target / path / query / version / head_bytes / content_type / content_length / transfer_encoding / body / trust_proxy`。

| 方法 | 行号 | 签名 |
|---|---|---|
| `getHeader` | 127 | `fn(*const Request, key) ?[]const u8`（大小写不敏感，零分配） |
| `getQuery` | 137 | `fn(*const Request, key) ?[]const u8` |
| `getQueryDecoded` | 155 | `fn(*const Request, allocator, key) !?[]const u8` |
| `getCookie` | 177 | `fn(*const Request, key) ?[]const u8` |
| `getForm` / `getFormFrom` | 195 / 206 | 原始表单字段 |
| `getFormDecoded` / `getFormDecodedFrom` | 223 / 233 | 解码表单字段 |
| `readBodyInto` | 270 | `fn(*const Request, allocator, limit) ![]const u8`（**通常用 `ctx.readBody` 而不是它**） |
| `bodyReader` | 339 | `fn(*const Request, transfer_buf) !?BodyReader`（流式读） |

### 5.4 其他可用状态

- `ctx.state.route_pattern: ?[]const u8`（`context.zig:109`）——命中的 pattern（`/users/:id`）而非原始路径，适合日志/指标。
- `ctx.state.allow_header`（405 时的 `Allow` 值）。

---

## 6. 响应

`src/http_protocol/response.zig:145`：

```zig
pub fn init(allocator, sink: Sink) Self                                                    // :168（框架内部用）
pub fn setBuffered(self: *Self) void                                                       // :186 缓冲模式：text/json 只存不发送
pub fn pendingBody(self: *const Self) ?[]const u8                                          // :192
pub fn replacePendingBody(self: *Self, body: []const u8) ?[]const u8                       // :202（压缩/签名中间件用）
pub fn flush(self: *Self) !void                                                            // :211 缓冲模式下真正写出（幂等）
pub fn statusCode(self: *Self, code: std.http.Status) *Self                                // :244 链式
pub fn header(self: *Self, name, value) !*Self                                             // :249 追加（同名可重复）
pub fn setHeader(self: *Self, name, value) !*Self                                          // :267 去重替换（大小写不敏感）
pub fn setCookie(self: *Self, name, value) !*Self                                          // :289
pub fn setCookieFull(self: *Self, cookie: Cookie) !*Self                                   // :299
pub fn text(self: *Self, content: []const u8) !void                                        // :326
pub fn html(self: *Self, content: []const u8) !void                                        // :330
pub fn raw(self: *Self, content: []const u8, content_type: []const u8) !void               // :335
pub fn json(self: *Self, value: anytype) !void                                             // :339
pub fn redirectStatus(self: *Self, location: []const u8, status: std.http.Status) !void    // :352
pub fn redirect(self: *Self, location: []const u8, permanent: bool) !void                  // :370 (301/302)
pub fn stream(self: *Self, buffer: []u8, options: StreamOptions) !Stream                   // :376
```

配套类型：

```zig
pub const Cookie = struct {   // response.zig:134
    name: []const u8, value: []const u8,
    max_age: ?i64 = null, path: ?[]const u8 = null, domain: ?[]const u8 = null,
    secure: bool = false, http_only: bool = false, same_site: ?[]const u8 = null,
};
pub const StreamOptions = struct { content_length: ?u64 = null, content_type: []const u8 = "application/octet-stream" }; // :410
pub const Stream = struct { writer, writeAll, print, flush, isEliding, end }; // :415
```

用法片段（摘自真实代码）：

```zig
try res.statusCode(.created).json(.{ .id = id, .name = body.name });   // examples/src/main.zig:776
try res.redirectStatus("/users/42", .see_other);                        // examples/src/main.zig:467
_ = try res.setCookieFull(.{ .name = "sid", .value = "deleted", .max_age = 0 }); // examples/src/main.zig:686
res.keep_alive = false;                                                 // examples/src/main.zig:551（413 后框架已自动关连接，此行可选/兼容旧代码）
```

> 坑：
> 1. **匿名结构体字段名不能用 `.error`**（该 Zig dev 版 tokenizer bug，`examples/src/main.zig:854-860`），用 `.error_code`。
> 2. `res.header()` 的 name 必须是 RFC 9110 token，否则 `error.InvalidHeaderName`（`response.zig:581`）。
> 3. 已发送后再写 → `error.AlreadyResponded`（`response.zig:453`）。
> 4. 只设了 status 没写 body 时，ConnectionRunner 会兜底 `res.text("")`（`connection.zig:226-229`），204 场景可用。

---

## 7. 中间件

### 7.1 契约

`src/http_app/middleware.zig`：

```zig
pub const Middleware = struct {                                     // :67
    ptr: *anyopaque,
    process: *const fn (*anyopaque, *Context, *Response, next: Next) anyerror!void,
    destroy: ?*const fn (*anyopaque) void = null,
    pub fn init(comptime T: type, ptr: *T) Middleware               // :73
};
pub const Next = struct {                                           // :40
    items: []const Middleware, handler: Handler, idx: usize,
    pub fn call(self: Next, ctx: *Context, res: *Response) anyerror!void  // :46
    pub fn root(items: []const Middleware, handler: Handler) Next        // :61
};
```

你的类型只要实现：

```zig
pub fn process(self: *T, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void
```

注册：`try router.use(framework.Middleware.init(T, &instance));` 或 `try group.use(...)`。

### 7.2 执行顺序与前后置

- **先 `use` = 外层 = 先执行**（`router.zig:243-257`）。
- `next.call(ctx, res)` 之前是前置逻辑，之后是后置逻辑。真实示例（计时中间件，`examples/src/main.zig:906-924`）：

```zig
const TimingMiddleware = struct {
    pub fn process(self: *@This(), ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        _ = self;
        res.setBuffered();   // 缓冲模式：next() 之后还能改头
        const start = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;
        next.call(ctx, res) catch |err| {
            const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
            _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
            return err;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
        _ = try res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?");
    }
};
```

### 7.3 中断请求（不调 next）

```zig
// A) 推荐：结构化错误，由 ErrorRenderer 统一渲染
try ctx.failWith(framework.AppError.unauthorized("not logged in"));
return;

// B) 直接写响应（不调 next 即可短路）
try res.statusCode(.forbidden).json(.{ .error_code = "forbidden" });
```

`ctx.failWith` 内部（`context.zig:330-337`）：在请求 arena 上分配 `AppError`，`setUserData(AppError, slot)`，然后 `return error.AppError`。

### 7.4 往下游传值（"bag"）

按类型索引（`context.zig:139-170`）：

```zig
try ctx.setUserData(SomeType, ptr);          // 中间件里
const v = ctx.getUserData(SomeType);         // handler 里取，?*SomeType
```

已被框架占用的槽：`AppError`（`failWith`）、`RequestId`（`request_id.zig:62`）、`AuthInfo`（AuthMiddleware）、以及 `JsonBody(T)` 中间件按 DTO 类型占位。

> 槽只存指针、不接管所有权；指向对象的生命周期由你负责（通常用 `ctx.arena.create`，如 `request_id.zig:45`）。

### 7.5 内置中间件一览

| 中间件 | 构造 | 位置 |
|---|---|---|
| `ErrorRenderer` | `framework.ErrorRenderer{}` | `error.zig:73` |
| `RequestIdMiddleware` | `framework.RequestIdMiddleware{}` | `request_id.zig:38`（写 `X-Request-Id` 头 + 存 `RequestId` 槽） |
| `CompressMiddleware` | `framework.CompressMiddleware{ .config = .{} }` | `http_compress/root.zig:77`；`CompressConfig{min_size:usize=1024, max_size, level, encodings}` `:46` |
| `SecurityHeaders` | `framework.SecurityHeaders{ .config = .{} }` | `http_security/security_headers.zig:24`；config `:11`（`content_security_policy` 默认 `default-src 'self'`） |
| `CorsMiddleware` | `framework.CorsMiddleware{ .config = .{} }` | `http_security/cors.zig:33`；`CorsConfig{allowed_origins: ?[]const []const u8 = null（=通配）, allowed_methods, allowed_headers, allow_credentials, max_age=86400, block_unauthorized}` `:17` |
| `AuthMiddleware` | `framework.AuthMiddleware{ .config = .{ .bearer_token = "...", .realm = "Protected" } }` | `http_security/auth.zig:50`；`AuthConfig{bearer_token, basic_username, basic_password, api_key, api_key_header="X-API-Key", api_key_query, custom_auth: ?*const fn(*Context) bool, realm}` `:35` |
| `CsrfMiddleware` | `framework.CsrfMiddleware{ .config = .{} }` | `http_security/csrf.zig:36`；`CsrfConfig{cookie_name="csrf_token", header_name="X-CSRF-Token", form_field_name, token_length=32, cookie_path="/", secure=true, ignored_methods}` `:24` |
| `RateLimiter` | `framework.RateLimiter.init(allocator, io, .{ .window_seconds=60, .max_requests=100, .per_ip=false })` | `http_rate_limit/rate_limiter.zig:38/57`；config `:19`（`per_ip=true` 需 `Config.body.trust_proxy_headers=true`） |
| `LoggingMiddleware` | `framework.LoggingMiddleware{ .logger = &logger }` | `http_logging/root.zig:659` |

AuthMiddleware 通过后（`auth.zig:27`）：

```zig
if (ctx.getUserData(framework.AuthInfo)) |info| {
    _ = info.strategy;  // AuthStrategy
    _ = info.token; _ = info.username; _ = info.api_key; _ = info.roles;
}
```

> ⚠️ **所有权陷阱**：`Middleware.init` 会检查 `T` 是否有 `deinit`（`middleware.zig:80-85`），有则 `Router.deinit()` 会调用它（去重后一次，`router.zig:128-129`）。**带 `deinit` 的中间件实例由 Router 销毁**，你不能自己再销毁。

---

## 8. 会话与鉴权

### 8.1 Session

`src/http_session/session.zig:48`（Cookie + 内存 HashMap + `std.Io.Mutex`）：

```zig
pub const SessionConfig = struct {      // :31
    cookie_name: []const u8 = "session_id",
    session_timeout_sec: u32 = 3600,
    cleanup_interval_sec: u32 = 300,
    secure: bool = true,          // 本机明文 HTTP 必须显式设为 false
    max_sessions: usize = 100_000,
};

var sessions = framework.SessionManager.init(allocator, io, .{
    .cookie_name = "sid", .session_timeout_sec = 3600, .secure = false,
});
defer sessions.deinit();
```

| 方法 | 行号 | 签名 |
|---|---|---|
| `getOrCreate` | 82 | `fn(*Self, ctx: *Context, res: *Response) ![]const u8` |
| `getValue` | 176 | `fn(*Self, session_id, key, allocator) !?[]const u8` |
| `setData` | 201 | `fn(*Self, session_id, key, value) !void`（session 不存在 → `error.SessionNotFound`） |
| `invalidate` | 307 | `fn(*Self, session_id) void` |
| `destroyFromRequest` | 314 | `fn(*Self, ctx: *Context) void` |
| `rotate` | 329 | `fn(*Self, ctx: *Context, res: *Response) ![]const u8` |
| `getStats` | 342 | `fn(*Self) Stats` |

登录 / 登出（抄 `examples/src/admin.zig:345-352, 369-376`）：

```zig
const sid = try sessions.getOrCreate(ctx, res);      // 无 cookie 则新建并写 Set-Cookie(Path=/, HttpOnly, SameSite=Lax)
try sessions.setData(sid, "username", username);
try sessions.setData(sid, "role", @tagName(role));

// 登出
_ = try res.setCookieFull(.{ .name = "sid", .value = "deleted", .max_age = 0 });
```

### 8.2 Session 鉴权中间件

抄 `examples/src/admin.zig:196-236`：

```zig
pub const RequireAuthMiddleware = struct {
    services: *AdminServices,
    pub fn process(self: *RequireAuthMiddleware, ctx: *framework.Context, res: *framework.Response, next: framework.Next) !void {
        const sessions = ctx.service(framework.SessionManager) orelse {
            try ctx.failWith(framework.AppError.internal("session service unavailable")); return;
        };
        const session_id = ctx.request.getCookie("sid") orelse {
            try ctx.failWith(framework.AppError.unauthorized("not logged in")); return;
        };
        const username = sessions.getValue(session_id, "username", ctx.arena) catch null;
        if (username == null) { try ctx.failWith(framework.AppError.unauthorized("session expired")); return; }
        // ... 校验用户/角色 ...
        try next.call(ctx, res);
    }
};
```

> `examples/src/admin.zig` 的 `requireRole` 历史上用 `Middleware.init(RequireRoleMiddleware, .{...})`（结构体字面量当指针传），是错误写法且从未被调用。现已修复为模块级实例写法（仿 `requireAuth`）。注意：多个不同角色的 `requireRole(...)` 会共享同一实例、后者覆盖前者，需要多个角色门槛时应为每个角色声明独立实例或改用 `initFactory`。

### 8.3 其它鉴权/防护

- Bearer / Basic / API Key：`AuthMiddleware`（见「[内置中间件](#75-内置中间件一览)」，`http_security/auth.zig:50`）。
- 双提交 CSRF：`CsrfMiddleware`（`http_security/csrf.zig:36`）。
- 安全响应头：`SecurityHeaders`（`http_security/security_headers.zig:24`）。
- 限流：`RateLimiter`（`http_rate_limit/rate_limiter.zig:38`）。

---

## 9. WebSocket

### 9.1 一步升级（推荐）：`framework.wsUpgrade`

`src/http_websocket/handshake.zig:209`

```zig
pub fn upgrade(
    ctx: *Context,
    res: *Response,
    hijack_ctx: *anyopaque,
    comptime handlerFn: fn (ws: *connection.WebSocket, hijack_ctx: *anyopaque) anyerror!void,
) !bool
```

- 返回 `true`：握手合法，已注册劫持回调，**handler 直接 return**（不要再写响应）。ConnectionRunner 在 dispatch 后写 101、构造 `WebSocket`、调你的回调。
- 返回 `false`：非升级请求 / 版本不支持，已写好 426 等错误响应，handler 直接 return。

真实示例（`examples/src/main.zig`）：

```zig
// hijack_ctx 必须是进程级稳定地址：回调在 handler 返回后才执行，
// 此时 handler 栈帧已失效，不能传 @ptrCast(res)（use-after-free）。
var ws_echo_conns: usize = 0;

fn wsEchoHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const upgraded = framework.wsUpgrade(ctx, res, @ptrCast(&ws_echo_conns), wsEcho) catch {
        try ctx.failWith(.{ .status = .bad_request, .message = "websocket upgrade failed" });
        return;
    };
    if (!upgraded) {
        if (!res.sent) try res.statusCode(.bad_request).text("expected a WebSocket upgrade request");
        return;
    }
}

fn wsEcho(ws: *framework.WebSocket, hijack_ctx: *anyopaque) anyerror!void {
    const conns: *usize = @ptrCast(@alignCast(hijack_ctx));
    conns.* += 1;
    defer conns.* -= 1;
    while (true) {
        var msg = ws.receive() catch |err| {
            if (err == error.ConnectionClosed or err == error.EndOfStream) return;
            return err;
        };
        defer msg.deinit();
        switch (msg.opcode) {
            .text   => try ws.sendText(msg.payload),
            .binary => try ws.sendBinary(msg.payload),
            else => {},
        }
    }
}
try router.route(.GET, "/ws", framework.Handler.fromFn(wsEchoHandler));
```

> ⚠️ **`hijack_ctx` 必须是长期稳定的指针**。历史上 `examples/src/main.zig` 曾传 `@ptrCast(res)`，这是**反例**（`res` 在栈上，回调执行时已失效 → use-after-free）；现已改为传模块级 `&ws_echo_conns`。`examples/src/admin.zig:698-708` 是另一正例，传 `services`（appMain 栈上的长期对象）。任何进程生命周期内稳定的地址都可以。

### 9.2 WebSocket 连接对象

`src/http_websocket/connection.zig:68`：

```zig
pub fn initServer(reader: *std.Io.Reader, writer: *std.Io.Writer, allocator) Self // :103
pub fn initClient(reader, writer, allocator) Self                                 // :112（仅测试）
pub fn initClientSecure(reader, writer, allocator, io) Self                       // :117
pub fn sendText(self: *Self, message: []const u8) !void                           // :133（内部 flush）
pub fn sendBinary(self: *Self, message: []const u8) !void                         // :138
pub fn ping(self: *Self, payload: []const u8) !void                               // :185（≤125 字节）
pub fn pong(self: *Self, payload: []const u8) !void                               // :191
pub fn close(self: *Self, code: CloseCode, reason: []const u8) !void              // :198（reason ≤123，须 UTF-8）
pub fn receive(self: *Self) !Message                                              // :231
```

`receive()` 语义（`:222-330`）：自动拼合分片、收到 ping 自动回 pong、收到 close 自动回 close 并返回 `error.ConnectionClosed`；返回的 `Message{payload, allocator}` 需 `msg.deinit()`。**回调 return 即关连接**。

```zig
pub const Message = struct { opcode: OpCode, payload: []u8, allocator, pub fn deinit };  // :38
pub const CloseCode = enum(u16) {                                                        // :49
    normal_closure = 1000, going_away = 1001, protocol_error = 1002, unsupported_data = 1003,
    no_status_received = 1005, abnormal_closure = 1006, invalid_frame_payload_data = 1007,
    policy_violation = 1008, message_too_big = 1009, mandatory_extension = 1010,
    internal_server_error = 1011, _,
};
```

### 9.3 底层 API

- `framework.wsHandshake(ctx, res) !bool`（`handshake.zig:89`）：只校验并设 101 响应头，**不发送、不劫持**。
- `framework.wsComputeAcceptKey(key, &out) ![]const u8`（`handshake.zig:150`，out 需 28 字节）。
- `framework.wsEncodeFrame(writer, opcode, payload, fin, mask_key)` / `framework.wsDecodeFrame(reader, allocator, max_payload)`（`src/root.zig:164-165`）。
- Origin 白名单（防 CSWSH）：`framework.http_websocket.setAllowedOrigins(&.{"https://example.com"})`（`handshake.zig:63`），启动期调用一次。

### 9.4 广播示例

`examples/src/admin.zig:100-182`：进程级 `Notifications` 持有 `[]*framework.WebSocket`，`broadcast()` 在锁内拷快照、锁外逐个 `sendText`（因为 `sendText` 可能 yield）。`Mutex` 用 `std.Io.Mutex` + `lockUncancelable(self.io)`。后台管理「实时通知」可直接抄。

---

## 10. ORM

`src/http_orm/`：编译期反射推导表结构，`id` 字段自动成为主键 + 自增；每张表 = 一个 JSON 文件。**没有 sqlite / pg。**

```zig
// 模型（examples/src/admin.zig:73-94）
const OrmAdminUser = struct {
    id: u64 = 0, username: []const u8, email: []const u8,
    password_hash: []const u8, role: []const u8, created_at: u64 = 0, last_login: u64 = 0,
};
pub const UserModel = framework.orm.Model(OrmAdminUser, "users");   // model.zig:65
pub const UserStore = UserModel.Store;                              // = JsonStore(T, Schema)

const store = try UserStore.open(allocator, io, "./data/admin");    // engine.zig:53
defer store.close() catch {};                                        // :99（close 会自动 flush 一次）
```

`JsonStore` 全部公开方法（`engine.zig`）：

| 方法 | 行号 | 签名 |
|---|---|---|
| `open` | 53 | `!*Self`（allocator, io, data_dir） |
| `close` | 99 | `!void` |
| `flush` | 189 | `!void`（**改动只在内存，必须显式 flush 才落盘**） |
| `insert` | 252 | `fn(*Self, row: T) !u64`（返回自增 id） |
| `findAll` | 286 | `fn(*Self, gpa, query: *QueryBuilder(T)) ![]T` |
| `findOne` | 316 | `fn(*Self, gpa, query) !?T` |
| `findById` | 332 | `fn(*Self, gpa, id: u64) !?T` |
| `findBy` | 573 | `fn(*Self, gpa, comptime field: []const u8, value: anytype) !?T` |
| `update` | 342 | `fn(*Self, query) !usize` |
| `updateById` | 581 | `fn(*Self, id: u64, data: T) !bool` |
| `delete` | 462 | `fn(*Self, query) !usize` |
| `deleteById` | 591 | `fn(*Self, id: u64) !bool` |
| `count` | 511 | `fn(*Self, query) !usize` |
| `all` | 525 | `fn(*Self, gpa) ![]T` |
| `freeRows` / `freeRow` | 543 / 550 | `fn(*Self, gpa, rows)`（**必须配 `defer`**） |
| `truncate` | 555 | `!void` |
| `paginate` | 602 | `fn(*Self, gpa, page, per_page) ![]T` |

查询构建器（`query.zig`）：

```zig
var qb = framework.orm.Query(User).init(allocator);   // QueryBuilder(T)，query.zig:84/114
defer qb.deinit();
_ = qb.where(.Eq, "username", .{ .string = "alice" })   // :175
     .andWhere(.Ne, "role", .{ .string = "admin" })     // :206
     .orWhere(.Like, "email", .{ .string = "%@x.com" }) // :211
     .orderBy("id", .Asc)                               // :217
     .limit(10).offset(0);                              // :229/235
const rows = try store.findAll(allocator, &qb);
defer store.freeRows(allocator, rows);
```

`Operator`（`query.zig:19`）：`Eq Neq Gt Gte Lt Lte Like In NotIn IsNull IsNotNull`；`SortDirection`（`query.zig:50`）：`Asc Desc`；`FieldValue` 是联合（`{.string, .integer, .float, .boolean, .null}`）。

> ⚠️ `insert` 唯一约束冲突返回 `error.UniqueViolation`——但**只有 schema 里标了 `unique` 的字段才会触发**；`Model()` 自动生成的 schema 只把 `id` 标为主键，其它字段无约束（`examples/src/main.zig:757-767` 注释）。要「用户名唯一」得在业务层自己查。
>
> ⚠️ 领域模型与 ORM 模型建议是两套 struct：ORM 只支持 int/float/bool/string/optional（`model.zig:13-25`），所以 role 用 `[]const u8` 存而不是 enum。

---

## 11. 错误处理

### 11.1 统一映射（挂了 `ErrorRenderer` 才生效）

`AppError = { status: std.http.Status, message: []const u8, cause: ?anyerror }`（`error.zig:13`）。

工厂（`error.zig:18-52`）：`notFound / badRequest / unauthorized / forbidden / conflict / payloadTooLarge / tooManyRequests / internal / notImplemented`。
手动构造也行：`framework.AppError{ .status = .bad_request, .message = "..." }`。
直接渲染：`try app_err.toResponse(res)`（`error.zig:54`，写状态码 + `text/plain` 消息）。

`ErrorRenderer.process`（`error.zig:74-107`）的 catch 逻辑：

1. `error.OutOfMemory` → 冒泡；
2. `res.sent == true`（handler 已自己写过响应）→ 不重复发；
3. `error.AppError` → 从 `ctx.state.getUserData(AppError)` 取出并 `toResponse`；
4. 其它任何 error → **500 + `AppError.internal("Internal Server Error")`**，并 `std.log.err` 原始错误名。

框架还有一层兜底（`connection.zig:179-192`）：即使没挂 ErrorRenderer，handler 抛错且没写响应时回 500，不至于挂死连接。

### 11.2 推荐写法

```zig
fn userGetHandler(ctx: *framework.Context, res: *framework.Response) !void {
    const id_str = ctx.param("id") orelse {
        try ctx.failWith(framework.AppError.badRequest("missing :id"));
        return;
    };
    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        try ctx.failWith(framework.AppError.badRequest("id must be an integer"));
        return;
    };
    const user = try store.findById(ctx.arena, id) orelse {
        try ctx.failWith(framework.AppError.notFound("user not found"));
        return;
    };
    try res.json(user);
}
```

> ⚠️ `ErrorRenderer` **建议挂在最外层**（第一个 `router.use`）。即使不挂或吞掉 `failWith` 返回的 error（`ctx.failWith(...) catch {}; return;`），框架连接层兜底也会从 `ctx.state` 取出 AppError 并用其状态码渲染，不会静默 200。但 `try ctx.failWith(...)` 仍为推荐写法——意图清晰，且配合 `ErrorRenderer` 能产生错误日志。

---

## 12. 其他能力

| 能力 | 有/无 | 位置 |
|---|---|---|
| 会话 | ✅ 见「[会话与鉴权](#8-会话与鉴权)」 | `http_session` |
| CORS | ✅ `CorsMiddleware`（预检 / Vary） | `http_security/cors.zig:33` |
| 静态资源 | ✅ `StaticFileServer` | `http_static/static.zig:19`（见 [3.6](#36-静态文件服务)） |
| **模板渲染** | ❌ **不存在**（`src/` 内 grep `template/mustache/render` 零命中） | 只能 `res.html(自己读文件/自己拼串)`，见 `examples/src/admin.zig:300-305` |
| **数据库（sqlite/pg）** | ❌ **不存在**。只有 JSON 文件 ORM | `http_orm` |
| **配置文件加载** | ❌ 不存在。配置 = Zig 字面量 | `http_app/config.zig` |
| 日志 | ✅ 结构化 Logger + 中间件 + Hook | `http_logging/root.zig` |
| 依赖注入 | ✅ `Services` + `ctx.service(T)` | `http_app/services.zig:20` |
| JSON 解析 | ✅ `framework.parseJson(T, arena, body) !*T`；`framework.JsonBody(T)` 中间件 | `http_codec/root.zig:35 / 71` |
| multipart | ✅ `framework.multipartFrom(ctx, limit)` → `FormData{getText, getFile, deinit}`；`FileField{safeBaseName}` | `http_multipart/root.zig:150/92/29` |
| 响应压缩 | ✅ q 值协商 | `http_compress` |
| 限流 | ✅ `Retry-After` / `X-RateLimit-*` | `http_rate_limit` |
| 请求 ID | ✅ | `http_app/request_id.zig` |
| 客户端真实 IP | ✅ `ctx.peerIpString(&buf)`（内核 accept，不可伪造） | `context.zig:210` |

### 12.1 日志

`examples/src/main.zig:126-135, 521-526`：

```zig
var logger = try framework.Logger.init(allocator, io, .{
    .min_level = .info, .format = .text, .output = .stderr,
    // .output = .file, .file = .{ .path = "log/app.log", .max_size = 2*1024*1024, .max_backups = 1, .compress = true },
});
defer logger.deinit();
logger.info(ctx, "user created", &.{ framework.fstr("name", "alice"), framework.fint("id", 42), framework.ffloat("price", 9.9) });
```

`Level{debug,info,warn,err,fatal}`（`http_logging/root.zig:55`）；方法 `log/debug/info/warn/err/fatal(self, ctx: ?*const Context, msg, fields)`（`root.zig:284, 515-527`）；field 构造 `fstr/fint/fuint/ffloat/fbool/fnull`（`root.zig:124-140`）。

### 12.2 multipart

`examples/src/main.zig:543-582`：

```zig
var form = framework.multipartFrom(ctx, 10 * 1024 * 1024) catch |err| switch (err) {
    error.NotMultipart, error.MissingBoundary, error.TooManyParts, error.MalformedPart, error.DuplicateField => { /* 400 */ },
    error.BodyTooLarge => { /* 413 — keep_alive=false 由框架自动处理 */ },
    else => return err,
};
defer form.deinit();
const username = form.getText("username") orelse "anonymous";
if (form.getFile("avatar")) |file| { const name = file.safeBaseName() orelse "upload.bin"; _ = file.data; }
```

### 12.3 JSON 解析

```zig
const body = try ctx.readBody(ctx.arena, 1024 * 1024);        // 必须传 ctx.arena
const dto = try framework.parseJson(CreateUserDto, ctx.arena, body);
```

`parseJson` 要求 arena 分配器（`http_codec/root.zig:24-27`）；`framework.JsonBody(T)` 中间件（`root.zig:71`）会自动解析并存进 `ctx.getUserData(T)` 槽。

---

## 13. 生命周期钩子

`src/http_app/lifecycle.zig`：

```zig
pub const Event = enum { connection_open, connection_close, request_start, request_end, request_error, tick }; // :14
pub const EventData = struct { ctx, res, err, duration_ns, method, path, status, route_pattern };  // :23
pub const Hook = struct { pub fn init(comptime T: type, ptr: *T) Hook };  // :34  T 需 onEvent(self, event, data) void
pub const Lifecycle = struct { hooks: []const Hook = &.{} };              // :49
```

挂载（`examples/src/main.zig:403-412`）：

```zig
var log_hook = framework.LoggingHook{ .logger = &logger };
const hooks = [_]framework.Hook{ framework.Hook.init(framework.LoggingHook, &log_hook) };
server.setLifecycle(.{ .hooks = &hooks });
```

`EventData` 里 `duration_ns` / `status` / `route_pattern` 由 ConnectionRunner 填好（`connection.zig:196-213`），这是拿到准确响应状态的唯一途径（中间件里读 `res.status` 在错误路径上不准）。

---

## 14. 硬约束与陷阱

每条给出：约束 → 违反后果 → 正确写法。

1. **`ErrorRenderer` 应挂在第一个 `router.use`（推荐，非强制）**
   `ctx.failWith` 只抛 `error.AppError`，`ErrorRenderer` 负责从 `ctx.state` 取出 AppError 并用其状态码渲染。**即使不挂 `ErrorRenderer`，框架也会在连接层兜底渲染**（`connection.zig` 查 `ctx.state.getUserData(AppError)`，有则用其状态码，无则 500）。但不挂 `ErrorRenderer` 会丢失错误日志与结构化渲染能力，仍建议挂。
   正确：`try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));` 放在所有 `use` / `route` 之前。

2. **`ctx.failWith(...)` 建议 `try`，`catch {}` 也安全**
   即使 `ctx.failWith(...) catch {}; return;` 吞掉错误，框架连接层兜底仍会从 `ctx.state` 取出 AppError 并用其状态码渲染（`connection.zig` 查 `getUserData(AppError)`），不再静默 200 空 body。但 `try` 写法更清晰、意图明确，仍为推荐写法。
   正确：`try ctx.failWith(framework.AppError.badRequest("...")); return;`（参考 `examples/src/main.zig:833-835`、`admin.zig:744-747` 注释）。

3. **组级 `use` 必须写在 `route` 之前**
   全局 `use` 与注册顺序无关；组级 `use` 只对其后注册的路由生效（`RouteGroup.use` 重建切片，`route()` 快照当时切片）。违反后果：**鉴权中间件静默不生效**（未登录也能访问）。
   正确：先 `use` 再 `route`；需要不同中间件集时用 `group("")` 建同前缀子组（见 [3.4](#34-路由分组)）。

4. **`initFactory` 的 Handler 注册后不要 `defer handler.deinit()`**
   所有权归 `router.deinit()`。违反后果：double-free（`examples/src/main.zig:254-261` 有回归测试 `:1044`）。
   正确：注册后不再手动释放。

5. **`initFactory` 的 `T.deinit()` 里不要 `allocator.destroy(self)`**
   框架在 `deinit()` 之后统一 destroy（`handler.zig:92-99`）。违反后果：double-free。
   正确：`deinit()` 只释放自己持有的资源。

6. **`initSingleton` 的框架不销毁你的实例**
   `Handler.deinit` 对 singleton 是 no-op（`handler.zig:138`）。违反后果：若误以为框架会释放，则内存泄漏或悬垂指针。
   正确：实例声明在 `main` 栈上或自己 `defer` 管理，且**地址必须稳定**（`Handler` 存的是指针）。

7. **带 `deinit` 的中间件实例由 Router 销毁**
   `Middleware.init` 会检测 `T.deinit` 并在 `Router.deinit()` 调用一次（去重，`router.zig:128-129`）。违反后果：自己再 `deinit` = double-free。
   正确：注册后交给 Router，不要自己销毁。

8. **`ctx.arena` 是请求级内存，请求结束即回收**
   违反后果：跨请求保存指针 = use-after-free。另外 `parseJson` **必须**传 arena（`http_codec/root.zig:24-27`）。
   正确：请求内临时对象用 `ctx.arena`；长期对象放进程级 allocator。

9. **JSON 匿名结构体字段名不能用 `.error`**
   该 Zig dev 版 tokenizer bug（`examples/src/main.zig:854-860`）。违反后果：编译错误。
   正确：用 `.error_code`。

10. **`SessionConfig.secure` 默认 `true`**
    违反后果：本机明文 HTTP 下 Set-Cookie 带 Secure，浏览器不回传 → 登录永远失败（**静默错误**）。
    正确：开发环境显式 `.{ .secure = false }`。

11. **ORM 改动后必须显式 `store.flush()`**
    改动只在内存（`engine.zig:189`，`close()` 会补 flush 一次）。违反后果：进程崩溃/未 close 时数据丢失（**静默错误**）。
    正确：写操作后 `try store.flush();`。

12. **`all()` / `findAll()` 返回的切片必须 `store.freeRows(gpa, rows)`**
    行内字符串由 `gpa` 拥有（`engine.zig:525` 锁内深拷贝）。违反后果：内存泄漏。
    正确：`defer store.freeRows(allocator, rows);`。

13. **静态路由的参数名是字面量 `"*"`**
    违反后果：取不到路径（**静默错误**，`static.zig:55`）。
    正确：`ctx.param("*")`；注册 `"/static/*"`；SPA 兜底路由放在组内**最后**注册。

14. **WebSocket 的 `hijack_ctx` 必须是长期稳定指针**
    违反后果：use-after-free（`examples/src/main.zig` 历史上曾传 `@ptrCast(res)`，是反例，现已改为传 `&ws_echo_conns`）。
    正确：传 `services` 这类 appMain 栈上的长期对象（`examples/src/admin.zig:698-708`），或任何进程生命周期内稳定的地址。

15. **响应头 name 必须是 RFC 9110 token；已发送后不可再写**
    违反后果：前者 `error.InvalidHeaderName`（`response.zig:581`），后者 `error.AlreadyResponded`（`response.zig:453`）。
    正确：写头用 `setHeader`（去重）/ `header`（追加）；想在下层写完之后再改头，用 `res.setBuffered()` + 后置逻辑 + `flush()`。

16. **413（body 过大 / multipart 过大）后框架自动关连接**
    `ctx.readBody`（含 `multipartFrom`）遇到 `error.BodyTooLarge` 时自动在 `ctx.state.body_too_large` 置位，`ConnectionRunner` 在 flush 前据此置 `res.keep_alive = false`（`context.zig` / `connection.zig`）。使用者无需手动 `res.keep_alive = false`。
    背景原因：chunked body 超限的残留字节 std 不会排空，复用连接会请求走私。手动设 `res.keep_alive = false` 仍然兼容（无副作用）。

17. **注册期硬约束**：catch-all 必须位于最后一段（否则 `error.InvalidRoute`，`trie.zig:130`）；pattern 参数 ≤16 个（`context.zig:50`）；路径段 ≤64（超出按 404，`router.zig:73`）；重复 pattern 返回 `error.RouteConflict`（`trie.zig:93`）；`max_connections = 0` 时 `setup()` 报 `error.MaxConnectionsZero`。

18. **404/405 走全局中间件，但不走组级中间件**（`router.zig:207-239`）。自定义 404 handler 里不要依赖组级中间件写入的状态。

19. **`RateLimiter` 的 `per_ip = true` 依赖 `Config.body.trust_proxy_headers = true`**（`rate_limiter.zig:19`）。否则取不到代理后的真实 IP，限流维度错误。

20. **没有程序化关机接口**：无 `server.stop()`，只能靠 SIGINT/SIGTERM（见 [2.2](#22-优雅关机)）。

---

## 15. 缺少的能力

框架目前没有、但后台管理系统通常需要的能力，如实列出：

| 能力 | 现状 | 影响 / 变通 |
|---|---|---|
| **模板引擎** | ❌ 不存在（`src/` 内 grep `template/mustache/render` 零命中） | 服务端渲染页面只能手工拼串后 `res.html(...)`（`examples/src/admin.zig:300-305`）；示例项目因此改用单文件 SPA（`public/admin/index.html`） |
| **sqlite / postgres 封装** | ❌ 不存在 | 只有 JSON 文件 ORM（`http_orm`），全表在内存 + 定期 flush，不适合大批量数据或多进程部署；需要真正数据库得自己接 C API |
| **配置文件加载器** | ❌ 不存在 | 无 `.env` / `toml` / `json` 读取，配置是 Zig 编译期字面量，改端口要重新编译 |
| **密码哈希工具** | ❌ 不存在 | 无 bcrypt/argon2/PBKDF2；示例里 `password_hash` 字段只是普通字符串，登录校验需自行实现（当前示例未做真实哈希） |
| **TLS / HTTPS** | ❌ 配置里没有 | 生产需前置反代（nginx / Caddy） |
| **迁移 / seed 工具** | ❌ 不存在 | 表结构变更靠改 struct + 手工处理旧 JSON 文件 |
| **数据库事务** | ❌ 不存在 | 无跨表原子性，只有进程内 `std.Io.Mutex` 级别保护 |
| **CSRF / 表单校验 / 输入校验器** | 部分：有双提交 CSRF 中间件，无表单校验 DSL | 校验逻辑写在 handler 里 |
| **国际化 / 错误消息本地化** | ❌ 不存在 | — |
| **OpenAPI / 文档生成** | ❌ 不存在 | 本文档为手工维护 |
| **测试辅助（mock client / test server）** | ❌ 无官方 harness | 示例用真实端口 + 手工 curl/测试 |
| **后台任务 / 定时任务 / 队列** | ❌ 不存在 | 只有 `Lifecycle` 的 `tick` 事件可用（`lifecycle.zig:14`） |

---

## 16. 文档与实现不一致

README 中的写法与真实代码不符的条目。**照 README 写会编译失败或运行时出错**，逐条列出待修：

| # | README 位置 | README 写法 | 真实代码 |
|---|---|---|---|
| 1 | README:125, 226, 237, 239, 329-334, 364, 442, 455 | `ctx.failWith(res, framework.AppError.notFound(...))`（**2 参**） | `ctx.failWith(app_err)` **1 参**（`src/http_app/context.zig:330`）。2 参写法**编译失败** |
| 2 | README:351 | `sessions.getData(session_id)` | 无 `getData`；用 `getValue(session_id, key, allocator)`（`src/http_session/session.zig:176`） |
| 3 | README:442 | `const rows = try store.all();` | `all(gpa)`（`src/http_orm/engine.zig:525`）。0 参写法**编译失败** |
| 4 | README:444 | `store.findById(id)` | `findById(gpa, id)`（`engine.zig:332`） |
| 5 | README:455 | `store.findAll(&qb)` / `findOne` / `count` / `paginate` | 都要先传 gpa：`findAll(gpa, &qb)`（`engine.zig:286`）、`findOne(gpa, &qb)`（`engine.zig:316`） |
| 6 | README:363（旧版） | `framework.wsUpgrade(ctx, res, @ptrCast(res), onWs)` | 能编译但**是 use-after-free 反例**；当前 README 已改为 `&ws_conns`（稳定指针）。`examples/src/main.zig` 的 echo 路由历史上曾照抄此反例，**现已修复**为传 `&ws_echo_conns`；正例另见 `examples/src/admin.zig:705` 传 `services` |
| 7 | README:56 | 「zio.Signal 处理 SIGINT」 | 实际同时处理 **SIGINT + SIGTERM**（`src/http_server/zio_server.zig:185`） |
| 8 | README（未提及） | 未标注死开关 | `body.lazy_read_size` / `network.idle_timeout_ns` / `http.access_log_enabled` **三项无效果**（`zio_server.zig:102-110`） |
| 9 | README:44 / 147 | `initSingleton`「程序退出销毁」 | 框架**不销毁** singleton（`src/http_app/handler.zig:138` no-op），生命周期由调用方负责 |
| 10 | README（未提及） | 未提 `services.seal()` | 实际存在且建议调用（`src/http_app/services.zig:55`） |
| 11 | README:223 | `ctx.readBody(allocator, limit)` | 签名正确，但**必须传 `ctx.arena`**（`parseJson` 要求 arena，`src/http_codec/root.zig:24-27`） |

补充（非 README，属示例自身问题，现已修复）：

- `examples/src/admin.zig` 的 `requireRole` 历史上用 `Middleware.init(RequireRoleMiddleware, .{...})` 把结构体字面量当指针传（`ptr: *T` 收 rvalue → 悬垂指针），且在示例里从未被调用、未被编译验证。**现已修复**为仿 `requireAuth` 的写法：模块级 `var role_mw_instance` 持有实例，传 `&role_mw_instance`，并注释多次调用会覆盖实例的限制。

> 说明：README 中提到的**能力本身全部真实存在**（中间件、WebSocket、静态文件、ORM、Session、CORS、Auth、CSRF、限流、压缩、日志），未发现「README 提了、代码里完全没有」的 API；上表问题是**签名/参数/生命周期描述不一致**。

---

## 17. API 速查表

### 装配

```zig
try framework.runZio(init.gpa, appMain);
var router = try framework.Router.init(allocator);
var server = try framework.Server.init(allocator, io, config, &router);
try server.setup();
server.setLifecycle(.{ .hooks = &hooks });
server.setServices(&services);
try server.run();          // 阻塞，等 SIGINT/SIGTERM
_ = server.stats();
server.deinit();
```

### 路由与 handler

```zig
try router.route(.GET, "/users/:id", framework.Handler.fromFn(h));
try router.route(.GET, "/x", framework.Handler.initSingleton(T, &inst));
try router.route(.GET, "/y", try framework.Handler.initFactory(T, allocator));
try router.use(framework.Middleware.init(M, &m));   // 全局
var g = try router.group("/admin"); try g.use(...); try g.route(.GET, "/users", h);
router.notFoundHandler(framework.Handler.fromFn(nf));  // 无 try
```

### 请求

```zig
ctx.param("id") / try ctx.paramDecoded("id") / ctx.param("*")
ctx.query("k") / try ctx.queryDecoded("k")
ctx.header("X-Token") / ctx.request.getHeader("x-token")
ctx.request.getCookie("sid")
try ctx.formDecoded("name", 1 << 20)
try ctx.readBody(ctx.arena, limit)      // 缓存，重复调用同结果
try framework.parseJson(T, ctx.arena, body)
ctx.service(T) / ctx.getUserData(T) / try ctx.setUserData(T, ptr)
```

### 响应

```zig
try res.statusCode(.created).json(value);
try res.text("ok"); try res.html(s); try res.raw(b, "application/pdf");
_ = try res.setHeader("X-A", "1");  _ = try res.header("Set-Cookie", "..");
_ = try res.setCookieFull(.{ .name = "sid", .value = v, .http_only = true, .path = "/" });
try res.redirectStatus("/login", .see_other); try res.redirect("/x", false);
res.setBuffered(); /* ... */ try res.flush();
res.keep_alive = false;   // 413 后框架已自动关连接，此行可选
```

### 错误

```zig
try ctx.failWith(framework.AppError.badRequest("..."));  // 必须 try
try ctx.fail(ctx, res, .forbidden, "no access");          // 应急，绕开 ErrorRenderer
try app_err.toResponse(res);
```

### 会话

```zig
var sessions = framework.SessionManager.init(allocator, io, .{ .cookie_name = "sid", .secure = false });
const sid = try sessions.getOrCreate(ctx, res);
try sessions.setData(sid, "username", name);
const name = try sessions.getValue(sid, "username", ctx.arena);
sessions.invalidate(sid); try sessions.rotate(ctx, res);
```

### ORM

```zig
pub const UserStore = framework.orm.Model(OrmUser, "users").Store;
var store = try UserStore.open(allocator, io, "./data");
defer store.close() catch {};
const id = try store.insert(row);
const one = try store.findById(allocator, id);       // 或 findBy / findOne(gpa, &qb)
const rows = try store.findAll(allocator, &qb); defer store.freeRows(allocator, rows);
_ = try store.updateById(id, row); _ = try store.deleteById(id);
try store.flush();                                    // 必须
```

### WebSocket

```zig
if (try framework.wsUpgrade(ctx, res, @ptrCast(&services), onWs)) return;
fn onWs(ws: *framework.WebSocket, c: *anyopaque) !void {
    var msg = try ws.receive(); defer msg.deinit();
    try ws.sendText(msg.payload);
    try ws.ping("");
    try ws.close(.normal_closure, "bye");
}
```

---

## 附录：推荐分层惯例

README §「项目结构」（README:486-547）只描述**框架自身**的 4 层（protocol / app / router / server）+ addon，**没有规定业务项目结构**。真实的业务分层惯例要从 `examples/` 反推：

```
examples/
├── build.zig              # 依赖接线：b.dependency("http_framework").module("http_framework")
├── build.zig.zon          # .http_framework = .{ .path = "../" }
├── src/
│   ├── main.zig           # 入口：runZio + appMain，唯一做「装配」的地方
│   ├── root.zig           # 库模块根，re-export 各业务模块的 pub 声明（供测试）
│   ├── admin.zig          # 业务模块：模型 + 服务容器 + 中间件 + handler 实现 + handler wrapper
│   ├── devices.zig        # 业务模块：同构（模型 → handler 实现 → handler wrapper）
│   └── register.zig       # 业务模块
└── public/admin/index.html  # SPA 前端（单文件，内联 style/script）
```

**`admin.zig` 内部的稳定分层**（按文件注释分段）：

1. **模型层**（`examples/src/admin.zig:18-94`）：`Role` 枚举、`AdminUser` 领域结构、`OrmAdminUser` ORM 结构（领域模型与 ORM 模型是两套 struct，role 用 `[]const u8` 存而非 enum——`src/http_orm/model.zig:13-25`）。
2. **服务容器层**（`admin.zig:42-67, 100-182`）：`AdminServices{ allocator, io, users, logs, notifications }` —— 进程级单例，注册进 `framework.Services`，handler 通过 `ctx.service(admin.AdminServices)` 取回。
3. **中间件层**（`admin.zig:191-287`）：`RequireAuthMiddleware` / `RequireRoleMiddleware`。
4. **handler 实现函数**（`admin.zig:300-738`）：纯函数 `fn(ctx, res, services) !void`，不捕获状态。
5. **handler wrapper struct**（`admin.zig:587-696`）：`struct { services: *AdminServices; pub fn handle(self, ctx, res) !void }`，用于 `initSingleton` 注入。

**建议**：`examples/src/admin.zig` 已经是一套完整的用户/角色/日志管理实现（`:20-36` 模型、`:410-533` 用户 CRUD + 日志列表/清除、`:379-408` 仪表盘统计、`:698-738` WebSocket 实时通知），做后台管理 demo 时照它的分层复刻，只需把 `AdminServices` 里的 store 换成自己的 `users / roles / orgs / logs` 四张表。
