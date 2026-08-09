//! `http_framework` — 伞形聚合模块
//!
//! 一次 `@import("http_framework")` 拿到全部能力，适合快速起步。
//!
//! # 想要更小的依赖面？直接依赖子模块
//!
//! 每个子模块都是 build.zig 里独立注册的模块，可以单独 import：
//!
//! ```zig
//! const core = @import("core");           // 只要 HTTP 解析 + 路由 + 请求/响应
//! const codec = @import("codec");         // 加上 JSON / form 反序列化
//! const security = @import("security");   // 加上 CORS / 鉴权 / CSRF
//! ```
//!
//! # 依赖方向
//!
//! `core` 不 import 任何其它模块，这一点由 build.zig 的模块边界强制保证。
//! 所有 addon 单向依赖 core，反向依赖在编译期就无法通过。
//!
//! core 通过 `Logger` / `RequestObserver` / `Worker` 三个接口接纳外部实现，
//! 横切逻辑（CORS、鉴权、限流）一律走 `router.use()`。

const std = @import("std");

// ── 子模块（推荐直接依赖需要的那个）────────────────────────────────
pub const core = @import("core");
pub const codec = @import("codec");
pub const multipart = @import("multipart");
pub const security = @import("security");
pub const observability = @import("observability");
pub const background = @import("background");
pub const session = @import("session");
pub const static = @import("static");
pub const rate_limit = @import("rate_limit");
pub const protocol = @import("protocol");
pub const policy = @import("policy");
pub const template = @import("template");
pub const pool = @import("pool");
pub const orm = @import("orm");

// ── core：最小 HTTP 服务器 ─────────────────────────────────────────
pub const Config = core.Config;
pub const Server = core.Server;
pub const Router = core.Router;
pub const RouteGroup = core.RouteGroup;
pub const RequestContext = core.RequestContext;
pub const Response = core.Response;
pub const Handler = core.Handler;

/// 流式响应句柄，由 `res.stream(buffer, .{})` 返回。
/// 大文件下载 / SSE / 流式 JSON 用它，避免整个响应体进内存。
pub const ResponseStream = core.ResponseStream;
pub const StreamOptions = core.StreamOptions;

pub const Middleware = core.Middleware;
pub const NextAction = core.NextAction;

/// `server.stats()` 的返回类型：连接数、快路径失效计数、内存池计数。
/// 喂给 `MetricsCollector.recordServerStats()` 或自己渲染成 /metrics。
pub const ServerStats = core.Server.Stats;

/// core 的三个扩展点接口（由 addon 实现）
pub const Logger = core.Logger;
pub const LogLevel = core.LogLevel;
pub const StdLogger = core.StdLogger;
pub const RequestObserver = core.RequestObserver;
pub const RequestInfo = core.RequestInfo;
pub const Worker = core.Worker;

// ── Security ──────────────────────────────────────────────────────
pub const AuthMiddleware = security.AuthMiddleware;
pub const AuthConfig = security.AuthConfig;
pub const AuthInfo = security.AuthInfo;
pub const AuthStrategy = security.AuthStrategy;
pub const CorsMiddleware = security.CorsMiddleware;
pub const CorsConfig = security.CorsConfig;
pub const CsrfMiddleware = security.CsrfMiddleware;
pub const SecurityHeaders = security.SecurityHeaders;

// ── Rate Limiting ─────────────────────────────────────────────────
pub const RateLimiter = rate_limit.RateLimiter;
pub const RateLimitConfig = rate_limit.RateLimitConfig;
pub const TokenBucket = rate_limit.TokenBucket;

// ── Session ───────────────────────────────────────────────────────
pub const SessionManager = session.SessionManager;
pub const SessionData = session.SessionData;

// ── Codec ─────────────────────────────────────────────────────────
/// `codec.bodyAs(T, ctx)` / `codec.queryAs(T, ctx)` —— 以前的 `ctx.bodyAs(T)`
pub const bodyAs = codec.bodyAs;
pub const queryAs = codec.queryAs;
pub const Compression = codec.compression;
pub const BodySignature = codec.body_signature;
pub const Validation = codec.validation;

// ── Multipart ─────────────────────────────────────────────────────
/// `multipart.from(ctx)` —— 以前的 `ctx.getMultipart()`
pub const MultipartParser = multipart.Parser;

// ── Protocol ──────────────────────────────────────────────────────
pub const WebSocketManager = protocol.WebSocketManager;
pub const WsEchoHandler = protocol.WsEchoHandler;

// ── Static / Template ─────────────────────────────────────────────
pub const Static = static;
pub const Template = template.Template;

// ── Observability ─────────────────────────────────────────────────
/// 实现 `core.Logger`：`server.setLogger(file_logger.logger())`
pub const FileLogger = observability.FileLogger;
/// 实现 `core.RequestObserver`：`server.setObserver(metrics.observer())`
pub const MetricsCollector = observability.MetricsCollector;
pub const OpenApi = observability.openapi;

// ── Policy ────────────────────────────────────────────────────────
pub const CspBuilder = policy.CspBuilder;
pub const SRIHash = policy.SRIHash;

// ── Background ────────────────────────────────────────────────────
/// 实现 `core.Worker`：`server.setWorker(bg.worker())`
pub const BackgroundQueue = background.BackgroundQueue;

// ── Pool ──────────────────────────────────────────────────────────
/// **出站**连接池：给数据库/HTTP 客户端复用长连接用的通用容器。
///
/// 和 Server 内部的 `core.ConnStatePool` 是两回事，别搞混：
/// 后者池化的是「入站连接的读写缓冲 + 每请求 arena」，由 accept 循环
/// 自动使用，不需要也不应该由调用方管。
pub const ConnectionPool = pool;

// ── Test ──────────────────────────────────────────────────────────
pub const IntegrationTest = @import("test/integration_test.zig");

test {
    std.testing.refAllDecls(@This());
}
