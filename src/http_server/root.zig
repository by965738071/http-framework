//! http_server 层 — 组装层。
//!
//! 分层（高内聚、低耦合）：
//! - connection.zig：**后端无关**的纯 HTTP 引擎（ConnectionRunner）——只依赖
//!   std.Io.Reader/Writer，跑 HTTP 状态机 + router + 中间件 + dispatch。
//! - zio_server.zig：**zio 专属**——监听/accept/背压/信号/关机/连接读写/运行时
//!   启动，建好 reader/writer 后交给 ConnectionRunner。唯一 @import("zio") 的文件。
//! - std_server.zig：**zig std 专属**（`std.Io.Threaded`）——与 zio_server.zig
//!   平行，复用同一个 ConnectionRunner，公开 API 与 zio 版完全对齐。
//!
//! 默认导出的 ZioServer = zio_server.Server。切换运行时只需换一对符号：
//! `ZioServer`/`runZio`（zio 协程）或 `StdServer`/`runStd`（std.Io.Threaded）。

const zio_server = @import("zio_server.zig");
const std_server = @import("std_server.zig");

pub const ZioServer = zio_server.Server;
pub const StdServer = std_server.Server;
pub const ConnectionRunner = @import("connection.zig").ConnectionRunner;

/// 启动 zio 运行时并在其协程上下文中运行 app（io, allocator）。
pub const runZio = zio_server.run;
/// 启动 zig std 运行时（`std.Io.Threaded`）并运行 app（io, allocator）。
/// appFn 直接跑在主线程（无协程上下文）。
pub const runStd = std_server.run;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}

/// 集成测试入口（中间件管道 + 路由，不走真实 TCP）。
pub const integration_test = @import("integration_test.zig");
