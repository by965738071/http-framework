//! http_server 层 — 组装层（依赖 http_router, http_app, http_protocol）
//!
//! 回应 bug.md §7：把原来 Server 一个 struct 扛的 9 种关注点拆成：
//! - Listener：TCP accept + 连接数背压
//! - ConnectionRunner：单连接 keep-alive 循环 + dispatch + arena 管理
//! - Shutdown：graceful shutdown（不含信号）
//! - Server：纯组装器

pub const Server = @import("server.zig").Server;
pub const Listener = @import("listener.zig").Listener;
pub const ConnectionRunner = @import("connection.zig").ConnectionRunner;
pub const Shutdown = @import("shutdown.zig").Shutdown;
const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}

/// 集成测试入口（真实 TCP socket → HTTP 请求 → 断言响应）。
/// 在 build.zig 里作为独立 test target 挂在 http_server 模块下运行。
pub const integration_test = @import("integration_test.zig");
