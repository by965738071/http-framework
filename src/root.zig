//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const core = @import("core");

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
pub const Static = core.Static;
pub const WsEchoHandler = core.WsEchoHandler;
pub const SecurityHeaders = core.SecurityHeaders;
pub const Csrf = core.Csrf;
pub const Validation = core.Validation;
pub const Background = core.Background;
pub const RouteGroup = core.Router.RouteGroup;
pub const Http2 = core.Http2;
pub const Orm = core.Orm;

// Optional: expose the entire core module for advanced use
pub const Core = core;

test {
    @import("std").testing.refAllDecls(@This());
}

// No additional test or helper functions are required in this file.
