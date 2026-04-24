# Zig HTTP Framework

基于 Zig `std.Io` 构建的高性能、轻量级 HTTP 服务器框架，支持请求级生命周期、灵活路由、中间件链、WebSocket 及静态文件服务。

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

- **请求级处理器** — 每次请求自动创建和销毁，框架管理生命周期
- **单例处理器** — main 启动时创建一次，每次请求复用，零分配
- **纯函数处理器** — 零开销适配，适合无状态处理逻辑
- **动态路由** — 支持 `/users/:id` 路径参数
- **HTTP keep-alive** — 同一连接循环处理多个请求
- **请求/响应封装** — Query 参数、Headers、Cookies、JSON、Form、文件流
- **WebSocket** — 内置握手升级与消息收发
- **静态文件服务** — 内置目录遍历防护
- **中间件链** — 支持日志、鉴权等拦截器
- **自定义错误处理** — 404 和 500 处理器可定制

## 环境要求

- **Zig**: `0.16.0-dev` 或更新版（使用 `std.Io` API）

```bash
# 开发模式
zig build run

# 发布模式
zig build run -Doptimize=ReleaseFast

# 运行测试
zig build test
```

## 快速开始

### 请求级模式 (推荐)

每次请求创建一个新处理器实例，处理完毕后自动销毁。main 中无需手动管理生命周期。

```zig
const std = @import("std");
const core = @import("core");
const Server = core.Server;
const Router = core.Router;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;
const Config = core.Config;

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
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
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

### 纯函数模式 (零开销)

适合无状态的顶级函数，create/destroy 均为空操作。

```zig
router.notFound(Handler.fromFn(struct {
    fn handler(ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        try res.statusCode(.not_found).text("404 Not Found");
    }
}.handler));
```

### 单例模式 (零分配)

适合全局共享状态的处理器，实例在 main 中一次创建，每次请求复用。

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

## 三种 Handler 模式对比

| 模式 | 工厂函数 | 生命周期 | 分配开销 | 适用场景 |
|------|---------|---------|---------|---------|
| **纯函数** | `fromFn` | 无状态，全局共享 | 零 | 简单的请求处理、404 等 |
| **单例** | `init(T, ptr)` | main 创建，程序退出销毁 | 仅启动时一次 | 全局配置、连接池、计数器 |
| **请求级** | `initPerRequest(T, alloc)` | 每次请求创建/销毁 | 每次 2 次分配 | 请求隔离状态、上下文数据 |

> **`initPerRequest` 的 deinit 规则**: 只释放内部字段（如 `allocator.free`），**不要**调 `allocator.destroy(self)`——框架的 VTable destroy 会自动处理。

## API 参考

### 路由

```zig
router.route(.GET, "/users/:id", handler);       // 静态/动态路由
router.notFound(handler);                         // 404 处理器
router.onError(errorHandler);                     // 分发错误处理器
```

### 请求上下文 (RequestContext)

```zig
ctx.getParam("id");          // 路径参数 /users/:id → "42"
ctx.getQuery("page");        // Query 参数 ?page=1 → "1"
ctx.getHeader("Content-Type"); // 请求头
ctx.getCookie("session");    // Cookie
ctx.getForm("username");     // Form 字段
ctx.json(User, .{});         // JSON body 解析
ctx.readBody();              // 请求体原始数据
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

```zig
const Logger = @import("core/logger.zig").LogMiddleware;
const Auth = @import("core/logger.zig").AuthMiddleware;

var logger = try Logger.create(allocator, io, "api");
defer logger.deinit();

try router.routeWithMiddleware(.GET, "/admin", handler, &.{logger.middle});
```

### WebSocket

```zig
const ws = try websocket.handle(&ctx, request);
try websocket.sendText(&ws, "Hello");
const msg = try websocket.readText(&ws, &buffer);
try websocket.close(&ws);
```

### 静态文件服务

```zig
var static_server = Static.init(allocator, io, "./public", "/static");
try router.route(.GET, "/static/*", Handler.init(Static, &static_server));
```

## 项目结构

```
http-framework/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig           # 程序入口和路由注册示例
│   ├── root.zig            # 包公开 API
│   ├── api/
│   │   ├── home.zig        # 请求级 Handler 示例
│   │   └── user.zig        # 带参数的请求级 Handler 示例
│   └── core/
│       ├── root.zig        # 核心模块导出
│       ├── server.zig      # HTTP 服务器 (keep-alive)
│       ├── router.zig      # 路由引擎 (:id 动态参数)
│       ├── handler.zig     # Handler 接口 (三种模式)
│       ├── request.zig     # 请求上下文
│       ├── response.zig    # 响应构建器
│       ├── middleware.zig  # 中间件接口
│       ├── logger.zig      # 日志+鉴权中间件
│       ├── static.zig      # 静态文件服务器
│       ├── websocket.zig   # WebSocket 支持
│       └── config.zig      # 服务器配置
└── README.md
```

## 许可证

MIT