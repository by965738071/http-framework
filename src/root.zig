//! By convention, root.zig is the root source file when making a package.
//!
//! This file re‑exports the public API of the HTTP framework so that
//! external projects can simply `@import("http-framework")` and access all
//! the core types and functions.

const std = @import("std");

// ── Core HTTP server modules ──────────────────────────────────────
pub const Config = @import("./config/config.zig").Config;
pub const Server = @import("./core/server.zig").Server;
pub const Router = @import("./core/router.zig");
pub const RequestContext = @import("./core/request.zig");
pub const Response = @import("./core/response.zig");
pub const Handler = @import("./handler/handler.zig");
pub const Middleware = @import("./core/middleware.zig");
pub const NextAction = @import("./core/middleware.zig").NextAction;
pub const RouteGroup = @import("./core/router.zig").RouteGroup;
pub const ConnectionPool = @import("./core/connection_pool.zig");

// ── Security ──────────────────────────────────────────────────────
pub const Auth = @import("./security/auth.zig");
pub const AuthMiddleware = @import("./security/auth.zig").AuthMiddleware;
pub const AuthConfig = @import("./security/auth.zig").AuthConfig;
pub const AuthInfo = @import("./security/auth.zig").AuthInfo;
pub const AuthStrategy = @import("./security/auth.zig").AuthStrategy;
pub const Cors = @import("./security/cors.zig");
pub const CorsMiddleware = @import("./security/cors.zig").CorsMiddleware;
pub const CorsConfig = @import("./security/cors.zig").CorsConfig;
pub const Csrf = @import("./security/csrf.zig");
pub const SecurityHeaders = @import("./security/security_headers.zig");

// ── Rate Limiting ─────────────────────────────────────────────────
pub const RateLimiter = @import("./rate_limit/rate_limiter.zig");
pub const RateLimitConfig = @import("./rate_limit/rate_limiter.zig").RateLimitConfig;
pub const TokenBucket = @import("./rate_limit/token_bucket.zig");

// ── Session ───────────────────────────────────────────────────────
pub const Session = @import("./session/session.zig");
pub const SessionManager = @import("./session/session.zig").SessionManager;
pub const SessionData = @import("./session/session.zig").SessionData;

// ── Codec / Serialization ─────────────────────────────────────────
pub const Deserialize = @import("./codec/deserialize.zig");
pub const Compression = @import("./codec/compression.zig");
pub const BodySignature = @import("./codec/body_signature.zig");
pub const Validation = @import("./codec/validation.zig");

// ── Protocol Extensions ───────────────────────────────────────────
pub const WebSocket = @import("./protocol/websocket.zig");
pub const WebSocketManager = @import("./protocol/websocket.zig").WebSocketManager;
pub const WsEchoHandler = @import("./protocol/websocket.zig").WsEchoHandler;
pub const Http2 = @import("./protocol/http2.zig");
pub const Http2Full = @import("./protocol/http2_full.zig");

// ── Static / Template ─────────────────────────────────────────────
pub const Static = @import("./static/static.zig");
pub const Template = @import("./template/template.zig");
pub const TemplateEngine = @import("./template/template_engine.zig");

// ── Multipart ─────────────────────────────────────────────────────
pub const Multipart = @import("./multipart/multipart.zig");

// ── Observability ─────────────────────────────────────────────────
pub const Metrics = @import("./observability/metrics.zig");
pub const OpenApi = @import("./observability/openapi.zig");

// ── Policy ────────────────────────────────────────────────────────
pub const Csp = @import("./policy/csp.zig");
pub const SRI = @import("./policy/sri.zig");

// ── Background ────────────────────────────────────────────────────
pub const Background = @import("./background/background.zig");
pub const BackgroundQueue = @import("./background/background.zig").BackgroundQueue;

// ── Test ──────────────────────────────────────────────────────────
pub const IntegrationTest = @import("./test/integration_test.zig");

// Optional: expose the entire core module for advanced use
pub const Core = @import("./core/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
