//! `core` — 最小 HTTP 服务器
//!
//! 这个模块只做四件事：**HTTP 解析、路由匹配、请求上下文、响应构建**，
//! 外加把它们串起来的 Server 事件循环。
//!
//! # 依赖方向
//!
//! `core` 不 import 任何其它模块——这一点由 build.zig 的模块边界强制保证，
//! 而不是靠约定。所有附加能力（multipart、session、模板、静态文件、安全头、
//! 限流、metrics、后台任务……）都是**依赖 core 的 addon**，反向依赖在编译期
//! 就无法通过。
//!
//! # 扩展点
//!
//! core 通过三个接口把外部能力接进来，自己不认识任何具体实现：
//!
//! | 接口              | 用途                     | 典型实现                          |
//! |-------------------|--------------------------|-----------------------------------|
//! | `Logger`          | 写一行日志               | `observability.FileLogger`        |
//! | `RequestObserver` | 请求完成后的观测点       | `observability.MetricsCollector`  |
//! | `Worker`          | 周期性后台任务           | `background.BackgroundQueue`      |
//!
//! 除此之外，`Handler` 与 `Middleware` 本身也是 vtable 接口——横切逻辑
//! （CORS、鉴权、限流）一律通过 `router.use()` 注册，Server 不为任何具体
//! addon 开后门。

const std = @import("std");

// ── HTTP 基元 ─────────────────────────────────────────────────────
pub const RequestContext = @import("request.zig");
pub const Response = @import("response.zig");
pub const Handler = @import("handler.zig");
pub const Middleware = @import("middleware.zig");
pub const NextAction = @import("middleware.zig").NextAction;

// ── 路由 ──────────────────────────────────────────────────────────
pub const Router = @import("router.zig");
pub const Route = @import("router.zig").Route;
pub const RouteGroup = @import("router.zig").RouteGroup;

// ── 服务器 ────────────────────────────────────────────────────────
pub const Server = @import("server.zig").Server;
pub const Config = @import("config.zig").Config;

// ── 扩展点接口（由 addon 实现）────────────────────────────────────
pub const log = @import("log.zig");
pub const Logger = log.Logger;
pub const LogLevel = log.Level;
pub const StdLogger = log.StdLogger;

pub const observer = @import("observer.zig");
pub const RequestObserver = observer.RequestObserver;
pub const RequestInfo = observer.RequestInfo;

pub const Worker = @import("worker.zig").Worker;

test {
    std.testing.refAllDecls(@This());
}
