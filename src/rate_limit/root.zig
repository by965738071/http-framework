//! `rate_limit` — 限流 addon
//!
//! 依赖 `core`，以中间件形式接入。

const std = @import("std");

pub const rate_limiter = @import("rate_limiter.zig");
pub const token_bucket = @import("token_bucket.zig");

pub const RateLimiter = rate_limiter.RateLimiter;
pub const RateLimitConfig = rate_limiter.RateLimitConfig;
pub const TokenBucket = token_bucket.TokenBucket;

test {
    std.testing.refAllDecls(@This());
}
