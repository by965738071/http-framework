//! http_server 层 — 组装层。
//!
//! 分层（高内聚、低耦合）：
//! - connection.zig：**后端无关**的纯 HTTP 引擎（ConnectionRunner）——只依赖
//!   std.Io.Reader/Writer，跑 HTTP 状态机 + router + 中间件 + dispatch。
//! - zio_server.zig：**zio 专属**——监听/accept/背压/信号/关机/连接读写/运行时
//!   启动，建好 reader/writer 后交给 ConnectionRunner。唯一 @import("zio") 的文件。
//!
//! 默认导出的 Server = zio_server.Server。将来接别的运行时：新增
//! xio_server.zig（照 zio_server.zig 重写运行时相关部分，复用 ConnectionRunner），
//! 再在此切换/并列导出即可。

const zio_server = @import("zio_server.zig");

pub const Server = zio_server.Server;
pub const ConnectionRunner = @import("connection.zig").ConnectionRunner;

/// 启动 zio 运行时并在其协程上下文中运行 app（io, allocator）。
pub const runZio = zio_server.run;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}

/// 集成测试入口（中间件管道 + 路由，不走真实 TCP）。
pub const integration_test = @import("integration_test.zig");
