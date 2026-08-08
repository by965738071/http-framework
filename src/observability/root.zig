//! `observability` — 日志 / 指标 / API 文档 addon
//!
//! 这个模块实现 core 定义的两个扩展点接口：
//!
//! - `FileLogger` → `core.Logger`（轮转、压缩、异步队列都在这里，core 不关心）
//! - `MetricsCollector` → `core.RequestObserver`
//!
//! ```zig
//! var flog = try observability.FileLogger.init(alloc, io, "logs/app.log", .{});
//! defer flog.deinit();
//! server.setLogger(flog.logger());
//!
//! var metrics = observability.MetricsCollector.init(alloc);
//! defer metrics.deinit();
//! server.setObserver(metrics.observer());
//! ```

const std = @import("std");

pub const file_logger = @import("file_logger.zig");
pub const metrics = @import("metrics.zig");
pub const openapi = @import("openapi.zig");

/// 带轮转的文件日志实现（`core.Logger`）
pub const FileLogger = file_logger.RotatingFileLogger;
pub const LogMiddleware = file_logger.LogMiddleware;
pub const FileLogMiddleware = file_logger.FileLogMiddleware;

/// 请求指标收集器（`core.RequestObserver`）
pub const MetricsCollector = metrics.MetricsCollector;
pub const RequestMetrics = metrics.RequestMetrics;

test {
    std.testing.refAllDecls(@This());
}
