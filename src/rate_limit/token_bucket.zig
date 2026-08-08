//! Token Bucket — Flow control with burst support
//!
//! Unlike the sliding window RateLimiter, the TokenBucket allows bursts
//! up to the configured capacity while maintaining a steady average rate.
//!
//! # Usage
//!
//! ```zig
//! var bucket = try TokenBucket.init(allocator, io, .{
//!     .rate = 100,       // 100 tokens/sec
//!     .capacity = 200,   // max burst of 200
//! });
//! defer bucket.deinit();
//!
//! // In middleware:
//! switch (bucket.tryConsume()) {
//!     .next => return .next,
//!     .respond => {
//!         ctx.blocked_status = .too_many_requests;
//!         return .respond;
//!     },
//!     .err => return .err,
//! }
//! ```

const std = @import("std");
const Middleware = @import("core").Middleware;
const RequestContext = @import("core").RequestContext;
const Response = @import("core").Response;

/// Token bucket configuration
pub const Config = struct {
    /// Tokens added per second (average rate)
    rate: u32 = 100,

    /// Maximum bucket capacity (burst limit)
    capacity: u32 = 200,

    /// Initial tokens (default: fill to capacity)
    initial_tokens: ?f64 = null,
};

/// Result of a token consumption attempt
pub const Result = enum {
    /// Token consumed, allow request
    allowed,
    /// No tokens available, deny request
    denied,
    /// Error occurred
    failed,
};

/// Token bucket rate limiter
pub const TokenBucket = struct {
    config: Config,
    tokens: f64,
    last_refill: i128, // nanosecond timestamp
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,
    io: std.Io,
    middleware: Middleware,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !*Self {
        const ptr = try allocator.create(Self);
        ptr.* = .{
            .config = config,
            .tokens = config.initial_tokens orelse @as(f64, @floatFromInt(config.capacity)),
            .last_refill = std.Io.Clock.now(.real, io).nanoseconds,
            .mutex = std.Io.Mutex.init,
            .allocator = allocator,
            .io = io,
            .middleware = undefined,
        };
        ptr.middleware = Middleware.init(Self, ptr);
        return ptr;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Try to consume a single token.
    pub fn tryConsume(self: *Self) Result {
        if (self.tryConsumeN(1)) return .allowed else return .denied;
    }

    /// Try to consume N tokens.
    pub fn tryConsumeN(self: *Self, n: u32) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock(self.io);

        self.refill();

        if (self.tokens >= @as(f64, @floatFromInt(n))) {
            self.tokens -= @as(f64, @floatFromInt(n));
            return true;
        }
        return false;
    }

    /// Get current token count.
    pub fn availableTokens(self: *Self) !f64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        self.refill();
        return self.tokens;
    }

    /// Get configuration.
    pub fn getConfig(self: *const Self) *const Config {
        return &self.config;
    }

    /// Middleware VTable: process request
    pub fn process(self: *Self, ctx: *RequestContext, res: *Response) !Middleware.NextAction {
        _ = res;
        switch (self.tryConsume()) {
            .allowed => return .next,
            .denied => {
                ctx.blocked_status = .too_many_requests;
                return .respond;
            },
            .failed => return .err,
        }
    }

    /// Internal: refill tokens based on elapsed time.
    fn refill(self: *Self) void {
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;
        const elapsed_ns: f64 = @floatFromInt(now - self.last_refill);
        const tokens_to_add: f64 = elapsed_ns * @as(f64, @floatFromInt(self.config.rate)) / 1_000_000_000.0;

        if (tokens_to_add > 0) {
            self.tokens = @min(
                @as(f64, @floatFromInt(self.config.capacity)),
                self.tokens + tokens_to_add,
            );
            self.last_refill = now;
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "TokenBucket - init fills to capacity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 100,
        .capacity = 200,
    });
    defer bucket.deinit();

    try std.testing.expect(bucket.tokens >= 199);
}

test "TokenBucket - consume tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 10,
        .initial_tokens = 10.0,
    });
    defer bucket.deinit();

    // Should be able to consume 10 tokens
    for (0..10) |_| {
        try std.testing.expect(bucket.tryConsume() == .allowed);
    }

    // 11th should fail
    try std.testing.expect(bucket.tryConsume() == .denied);
}

test "TokenBucket - refill over time" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 1000, // 1000 tokens/sec = 1 per ms
        .capacity = 100,
        .initial_tokens = 50.0,
    });
    defer bucket.deinit();

    // Consume all
    for (0..50) |_| {
        _ = bucket.tryConsume();
    }

    // Should be denied now
    try std.testing.expect(bucket.tryConsume() == .denied);

    // Simulate time passing by manually adjusting last_refill
    // (In real code, time passes naturally)
    bucket.last_refill -= 1_000_000_000; // Pretend 1 second passed

    try std.testing.expect(bucket.tryConsume() == .allowed);
}

test "TokenBucket - burst capacity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10, // slow refill
        .capacity = 50, // but large burst
        .initial_tokens = 50.0,
    });
    defer bucket.deinit();

    // Should allow burst of 50
    for (0..49) |_| {
        try std.testing.expect(bucket.tryConsume() == .allowed);
    }

    try std.testing.expect(bucket.tryConsume() == .allowed);
    try std.testing.expect(bucket.tryConsume() == .denied);
}

test "TokenBucket - concurrent safety" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 1,
        .capacity = 100,
        .initial_tokens = 100.0,
    });
    defer bucket.deinit();

    var g: std.Io.Group = .init;
    errdefer g.cancel(io);

    var results = std.ArrayList(Result).empty;
    defer results.deinit(allocator);

    // 用于保护 ArrayList 的互斥锁
    var mu: std.Io.Mutex = .{ .state = .init(.unlocked) };

    // Spawn 200 concurrent consume attempts
    for (0..200) |_| {
        g.async(io, struct {
            fn worker(b: *TokenBucket, res: *std.ArrayList(Result), alloc: std.mem.Allocator, m: *std.Io.Mutex, test_io: std.Io) void {
                const r = b.tryConsume();
                m.lockUncancelable(test_io);
                defer m.unlock(test_io);
                res.append(alloc, r) catch {};
            }
        }.worker, .{ bucket, &results, allocator, &mu, io });
    }

    _ = g.await(io) catch {};

    // Exactly 100 should succeed
    var allowed: usize = 0;
    for (results.items) |r| {
        if (r == .allowed) allowed += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), allowed);
}

test "TokenBucket - tryConsumeN consumes multiple tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 100,
        .initial_tokens = 50.0,
    });
    defer bucket.deinit();

    // Consume 10 tokens at once
    try std.testing.expect(bucket.tryConsumeN(10));

    // Consume remaining 40 tokens
    try std.testing.expect(bucket.tryConsumeN(40));

    // Should be empty now
    try std.testing.expect(!bucket.tryConsumeN(1));
}

test "TokenBucket - tryConsumeN edge cases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 100,
        .initial_tokens = 5.0,
    });
    defer bucket.deinit();

    // Consume exactly available (5 tokens)
    try std.testing.expect(bucket.tryConsumeN(5));
    // Consume 1 more should fail
    try std.testing.expect(!bucket.tryConsumeN(1));
}

test "TokenBucket - availableTokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 1000,
        .capacity = 100,
        .initial_tokens = 42.0,
    });
    defer bucket.deinit();

    // availableTokens should be ~42 after init
    const tokens = try bucket.availableTokens();
    try std.testing.expect(tokens >= 41.0);
    try std.testing.expect(tokens <= 43.0);

    // Consume 10 and check again
    _ = bucket.tryConsumeN(10);
    const tokens2 = try bucket.availableTokens();
    try std.testing.expect(tokens2 >= 31.0);
    try std.testing.expect(tokens2 <= 33.0);
}

test "TokenBucket - capacity cap prevents overflow" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 1_000_000, // very fast refill
        .capacity = 50,
        .initial_tokens = 0.0,
    });
    defer bucket.deinit();

    // Simulate a large time jump in the past
    bucket.last_refill -= 3_600_000_000_000; // 1 hour in nanoseconds

    // availableTokens should be capped at capacity, not exceed it
    const tokens = try bucket.availableTokens();
    try std.testing.expect(tokens <= 50.0);
    try std.testing.expectEqual(@as(f64, 50.0), tokens);
}

test "TokenBucket - initial_tokens = 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 10,
        .initial_tokens = 0.0,
    });
    defer bucket.deinit();

    // Should be empty
    try std.testing.expect(bucket.tryConsume() == .denied);

    // Simulate 1 second passing
    bucket.last_refill -= 1_000_000_000;

    // Should have refilled by ~10 tokens
    try std.testing.expect(bucket.tryConsume() == .allowed);
}

test "TokenBucket - getConfig returns config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 50,
        .capacity = 100,
        .initial_tokens = 30.0,
    });
    defer bucket.deinit();

    const config = bucket.getConfig();
    try std.testing.expectEqual(@as(u32, 50), config.rate);
    try std.testing.expectEqual(@as(u32, 100), config.capacity);
}

test "TokenBucket - process middleware returns next when tokens available" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 10,
        .initial_tokens = 5.0,
    });
    defer bucket.deinit();

    // ct is not dereferenced in the .allowed path, so a mock pointer is safe
    const ctx: *RequestContext = @ptrFromInt(0x1000);
    var res = Response.init(allocator, undefined);
    defer res.deinit();
    const action = try bucket.process(ctx, &res);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}

test "TokenBucket - process middleware denies when no tokens available" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bucket = try TokenBucket.init(allocator, io, .{
        .rate = 10,
        .capacity = 1,
        .initial_tokens = 0.0,
    });
    defer bucket.deinit();

    var ctx = RequestContext{
        .allocator = allocator,
        .io = io,
        .method = .GET,
        .path = "/test",
        .query = "",
        .version = undefined,
        .path_params = .empty,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = undefined,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .blocked_status = null,
    };
    var res = Response.init(allocator, undefined);
    defer res.deinit();
    const action = try bucket.process(&ctx, &res);
    try std.testing.expectEqual(Middleware.NextAction.respond, action);
    try std.testing.expectEqual(@as(std.http.Status, .too_many_requests), ctx.blocked_status.?);
}
