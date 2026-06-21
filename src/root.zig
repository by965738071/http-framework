//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const core = @import("core");
const orm = @import("orm");

/// By convention, `root.zig` is the root source file when making a package.
///
/// This file re‑exports the public API of the HTTP framework so that
/// external projects can simply `@import("http-framework")` and access all
/// the core types and functions.
///
/// ## Usage example
///
/// ```zig
/// const http_framework = @import("http-framework");
/// const Server   = http_framework.Server;
/// const Router   = http_framework.Router;
/// const Handler  = http_framework.Handler;
/// const RequestContext = http_framework.RequestContext;
/// const Response = http_framework.Response;
/// const Config   = http_framework.Config;
/// ```

// Re‑export core types and helpers
pub const Server = core.Server;
pub const Router = core.Router;
pub const RequestContext = core.RequestContext;
pub const Response = core.Response;
pub const Handler = core.Handler;
pub const Config = core.Config;
pub const Middleware = core.Middleware;
pub const NextAction = core.Middleware.NextAction;
pub const WebSocket = core.WebSocket;
pub const WebSocketManager = core.WebSocket.WebSocketManager;
pub const WsEchoHandler = core.WsEchoHandler;
pub const Static = core.Static;
pub const SecurityHeaders = core.SecurityHeaders;
pub const Csrf = core.Csrf;
pub const Validation = core.Validation;
pub const Background = core.Background;
pub const BackgroundQueue = core.Background.BackgroundQueue;
pub const RouteGroup = core.Router.RouteGroup;
pub const Http2 = core.Http2;
pub const Orm = orm;

// ── 常用中间件/组件直接导出（方便使用者直接引用）──────────
pub const Auth = core.Auth;
pub const AuthMiddleware = core.Auth.AuthMiddleware;
pub const AuthConfig = core.Auth.AuthConfig;
pub const AuthInfo = core.Auth.AuthInfo;
pub const AuthStrategy = core.Auth.AuthStrategy;
pub const Cors = core.Cors;
pub const CorsMiddleware = core.Cors.CorsMiddleware;
pub const CorsConfig = core.Cors.CorsConfig;
pub const RateLimiter = core.RateLimiter.RateLimiter;
pub const RateLimitConfig = core.RateLimiter.RateLimitConfig;
pub const Session = core.Session;
pub const SessionManager = core.Session.SessionManager;
pub const SessionData = core.Session.SessionData;
pub const Multipart = core.Multipart;
pub const Metrics = core.Metrics;
pub const Template = core.Template;
pub const Compression = core.Compression;
pub const OpenApi = core.OpenApi;

// Optional: expose the entire core module for advanced use
pub const Core = core;

test {
    @import("std").testing.refAllDecls(@This());
}

// No additional test or helper functions are required in this file.
