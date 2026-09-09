//! http_rate_limit addon — 速率限制
//!
//! 依赖：http_app, http_protocol

const std = @import("std");

pub const rate_limiter = @import("rate_limiter.zig");
pub const RateLimiter = rate_limiter.RateLimiter;
pub const RateLimitConfig = rate_limiter.RateLimitConfig;

test {
    std.testing.refAllDecls(@This());
}
