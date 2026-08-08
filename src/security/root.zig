//! `security` — 安全中间件 addon
//!
//! 依赖 `core`，全部通过 `router.use()` 或路由级中间件接入。
//! core 不为其中任何一项开专用钩子。

const std = @import("std");

pub const auth = @import("auth.zig");
pub const cors = @import("cors.zig");
pub const csrf = @import("csrf.zig");
pub const headers = @import("security_headers.zig");

pub const AuthMiddleware = auth.AuthMiddleware;
pub const AuthConfig = auth.AuthConfig;
pub const AuthInfo = auth.AuthInfo;
pub const AuthStrategy = auth.AuthStrategy;

pub const CorsMiddleware = cors.CorsMiddleware;
pub const CorsConfig = cors.CorsConfig;

pub const CsrfMiddleware = csrf.CsrfMiddleware;
pub const CsrfConfig = csrf.CsrfConfig;

pub const SecurityHeaders = headers.SecurityHeaders;
pub const SecurityHeadersConfig = headers.SecurityHeadersConfig;

test {
    std.testing.refAllDecls(@This());
}
