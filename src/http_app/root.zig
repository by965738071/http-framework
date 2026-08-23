//! http_app 层 — 生命周期 + 管道（依赖 http_protocol）
//!
//! 这一层定义框架的核心抽象：
//! - Context：拆分后的请求上下文（Request + State + Config）— 回应 bug.md §4
//! - Handler：union(enum) 替代 3 语义 vtable — 回应 bug.md §2
//! - Middleware：真正的 next 回调管道 — 回应 bug.md §3
//! - AppError：错误是一等公民 — 回应 bug.md §11
//! - Config：分层配置 — 回应 bug.md §10
//! - Lifecycle：统一生命周期钩子 — 回应 bug.md §9
//! - Arenas：两级 arena — 回应 bug.md §12

pub const Request = @import("context.zig").Request;
pub const RequestState = @import("context.zig").RequestState;
pub const RequestConfig = @import("context.zig").RequestConfig;
pub const UserData = @import("context.zig").UserData;
pub const Context = @import("context.zig").Context;
pub const Hijack = @import("context.zig").Hijack;

pub const Handler = @import("handler.zig").Handler;
pub const Middleware = @import("middleware.zig").Middleware;
pub const Next = @import("middleware.zig").Next;
pub const DynPipeline = @import("middleware.zig").DynPipeline;
pub const Pipeline = @import("middleware.zig").Pipeline;

pub const AppError = @import("error.zig").AppError;
pub const ErrorRenderer = @import("error.zig").ErrorRenderer;

pub const RequestId = @import("request_id.zig").RequestId;
pub const RequestIdMiddleware = @import("request_id.zig").RequestIdMiddleware;
pub const REQUEST_ID_HEADER = @import("request_id.zig").REQUEST_ID_HEADER;

pub const Config = @import("config.zig").Config;
pub const NetworkConfig = @import("config.zig").NetworkConfig;
pub const HttpConfig = @import("config.zig").HttpConfig;
pub const BodyConfig = @import("config.zig").BodyConfig;
pub const PoolConfig = @import("config.zig").PoolConfig;
pub const RuntimeState = @import("config.zig").RuntimeState;
pub const ServerStats = @import("config.zig").ServerStats;

pub const Event = @import("lifecycle.zig").Event;
pub const EventData = @import("lifecycle.zig").EventData;
pub const Hook = @import("lifecycle.zig").Hook;
pub const Lifecycle = @import("lifecycle.zig").Lifecycle;

pub const Arenas = @import("arena.zig").Arenas;

pub const Services = @import("services.zig").Services;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
