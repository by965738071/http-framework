# Zig HTTP Framework

基于 Zig 0.16-dev 构建的高性能、轻量级 HTTP 服务器框架。提供现代化的路由系统、请求/响应封装以及 WebSocket 支持，旨在为 Zig 开发者提供简洁而强大的 Web 开发体验。

## ✨ 核心特性

- 🚀 **高性能**: 基于 Zig 语言特性与 `std.Io` 异步/同步 IO 模型构建。
- 🛣️ **灵活路由**: 支持静态路由、动态路径参数 (`/users/:id`) 以及 HTTP 方法匹配。
- 📦 **请求/响应封装**: 简化的 API 处理 Query 参数、JSON 序列化/反序列化、表单数据及文件流。
- 🔌 **WebSocket 支持**: 内置 WebSocket 升级与消息处理机制。
- 📁 **静态文件服务**: 开箱即用的静态资源托管支持。
- 🧩 **模块化设计**: 核心组件解耦，易于扩展和定制中间件。

## 📦 安装与构建

### 环境要求

- **Zig 版本**: `0.16.0-dev` (最新 master 分支)
  > ⚠️ 注意：本项目依赖 Zig 0.16-dev 中引入的最新 `std.Io` 和 HTTP 标准库 API，请确保使用正确的编译器版本。

### 构建项目

```bash
# 编译并运行
zig build run

# 仅编译
zig build

# 运行测试
zig build test
```

## 🚀 快速开始

### 1. 创建服务器与路由

```zig
const std = @import("std");
const http_framework = @import("http_framework");
const Server = http_framework.Server;
const Router = http_framework.Router;
const RequestContext = http_framework.RequestContext;
const Response = http_framework.Response;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // 初始化路由
    var router = Router.init(arena);
    defer router.deinit();

    // 注册路由
    try router.route(.GET, "/", homeHandler);
    try router.route(.GET, "/users/:id", userHandler);
    try router.route(.POST, "/users", createUserHandler);

    // 启动服务器
    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:9000");
    var server = try Server.init(arena, io, address, router);
    try server.start();
    defer server.deinit();
}
```

### 2. 处理请求与响应

框架提供了便捷的 `RequestContext` 和 `Response` 对象，简化了常见 Web 操作：

```zig
/// 处理带路径参数的请求
fn userHandler(ctx: *RequestContext, res: *Response) !void {
    const user_id = ctx.getParam("id") orelse "unknown";

    try res.json(.{
        .user_id = user_id,
        .name = "John Doe",
        .email = "john@example.com",
    });
}

/// 处理 POST 请求体
fn createUserHandler(ctx: *RequestContext, res: *Response) !void {
    const body = try ctx.readBody();
    
    // 返回 201 Created 状态码
    try res.statusCode(.created).json(.{
        .success = true,
        .body_length = body.len,
    });
}

/// 返回 HTML 页面
fn homeHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.html(
        \\<!DOCTYPE html>
        \\<html><body><h1>Welcome to Zig HTTP Server!</h1></body></html>
    );
}
```

### 3. 静态文件服务 (可选)

```zig
const StaticFileServer = http_framework.StaticFileServer;

// 将 /static/* 映射到 ./public 目录
const static_server = StaticFileServer.init(arena, io, "./public", "/static");
try router.route(.GET, "/static/*", struct {
    fn handler(ctx: *RequestContext, res: *Response) !void {
        try static_server.handle(ctx, res);
    }
}.handler);
```

## 📂 项目结构

```text
http-framework/
├── build.zig              # Zig 构建脚本
├── build.zig.zon          # 包依赖清单
├── src/
│   ├── main.zig           # 入口文件与示例路由
│   ├── root.zig           # 库模块根文件
│   └── core/
│       ├── server.zig             # HTTP 服务器核心实现
│       ├── router.zig             # 路由匹配与参数解析
│       ├── request_context.zig    # 请求上下文封装
│       ├── response.zig           # 响应构建器
│       └── static_file_server.zig # 静态文件处理器
└── README.md
```

## 🛠️ API 参考

### 路由定义
- `router.route(method, path, handler)`: 注册路由。
- `router.notFound(handler)`: 设置 404 未找到处理器。
- 路径参数使用 `:` 前缀，例如 `/api/users/:id`。

### 请求上下文 (`RequestContext`)
- `ctx.getParam("name")`: 获取路径参数。
- `ctx.query`: 获取查询参数字符串。
- `ctx.readBody()`: 读取请求体数据。
- `ctx.content_type`: 获取请求 Content-Type。

### 响应构建 (`Response`)
- `res.json(data)`: 发送 JSON 响应。
- `res.html(str)`: 发送 HTML 响应。
- `res.text(str)`: 发送纯文本响应。
- `res.statusCode(status)`: 设置 HTTP 状态码。
- `res.header(name, value)`: 添加响应头。

## 📜 许可证

本项目采用 MIT 许可证开源。详见 [LICENSE](LICENSE) 文件。