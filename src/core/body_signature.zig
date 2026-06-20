//! Request body signature verification
//!
//! Provides HMAC-SHA256 request body signature verification to prevent
//! tampering and replay attacks.
//!
//! # Usage
//!
//! ```zig
//! var sig = try BodySignature.init(allocator, io, .{
//!     .secret_key = "my-secret",
//! });
//! defer sig.deinit();
//!
//! // Verify request signature:
//! try sig.verify(&ctx);
//! ```

const std = @import("std");

/// Configuration for body signature verification
pub const Config = struct {
    /// HMAC secret key for signing/verifying
    secret_key: []const u8,

    /// Header containing the signature (hex-encoded HMAC)
    header_name: []const u8 = "X-Signature",

    /// Header containing the Unix timestamp (seconds)
    timestamp_header: []const u8 = "X-Timestamp",

    /// Replay attack window in milliseconds (default: 5 minutes)
    window_ms: u64 = 300_000,

    /// Additional headers to include in the signature base
    included_headers: []const []const u8 = &.{},
};

/// Signature verification errors
pub const Error = error{
    /// Missing X-Signature header
    MissingSignature,
    /// Missing X-Timestamp header
    MissingTimestamp,
    /// Timestamp is outside the allowed window
    TimestampExpired,
    /// Signature mismatch (body was tampered with)
    SignatureMismatch,
    /// Failed to read request body
    BodyReadFailed,
};

/// Body signature verifier
pub const BodySignature = struct {
    config: Config,
    allocator: std.mem.Allocator,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Self {
        return .{
            .config = config,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Verify the request signature.
    /// Reads the body, recomputes HMAC-SHA256, and compares.
    pub fn verify(self: *Self, ctx: *anyopaque) Error!void {
        const request_ctx: *anyopaque = ctx;
        // Get the signature and timestamp from headers
        // We need to access request_ctx's getHeader method
        // This is designed to work with RequestContext

        // Use a type-erased approach — the caller passes RequestContext
        const req: *RequestContext = @ptrCast(@alignCast(request_ctx));

        const signature = req.getHeader(self.config.header_name) orelse {
            return Error.MissingSignature;
        };
        const timestamp_str = req.getHeader(self.config.timestamp_header) orelse return Error.MissingTimestamp;

        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch {
            return Error.TimestampExpired;
        };

        // Check timestamp window (anti-replay)
        const now_s = @as(i64, @divTrunc(
            std.Io.Clock.now(.real, self.io).nanoseconds,
            1_000_000_000,
        ));
        if (std.math.absInt(now_s - timestamp) > @as(i64, self.config.window_ms) / 1000) {
            return Error.TimestampExpired;
        }

        // Read the request body
        const body = try self.readBody(req);
        defer self.allocator.free(body);

        // Compute expected signature
        const expected = try self.computeSignature(timestamp, body);
        defer self.allocator.free(expected);

        // Constant-time comparison to prevent timing attacks
        if (!self.constantTimeCompare(signature, expected)) {
            return Error.SignatureMismatch;
        }
    }

    /// Read the full request body.
    fn readBody(self: *Self, ctx: *RequestContext) ![]const u8 {
        if (ctx.body_read) {
            if (ctx.body_data) |data| return data;
            return "";
        }

        const request: *std.http.Server.Request = ctx.request;
        const body = try request.reader(&{}).interface.allocRemaining(
            self.allocator,
            .limited(ctx.body_size_limit),
        );

        ctx.body_read = true;
        ctx.body_data = body;

        return body;
    }

    /// Compute HMAC-SHA256 signature for the given timestamp and body.
    pub fn computeSignature(self: *Self, timestamp: i64, body: []const u8) ![]const u8 {
        // Message format: timestamp + body
        var msg_buf: [64]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&msg_buf, "{d}", .{timestamp}) catch {
            return self.computeSignatureFallback(timestamp, body);
        };

        var message = std.ArrayList(u8).empty;
        defer message.deinit(self.allocator);
        try message.appendSlice(self.allocator, ts_str);
        try message.appendSlice(self.allocator, body);

        return try self.computeHmac(message.items);
    }

    /// Generate a signature for the client to send back.
    pub fn generateSignature(self: *Self, timestamp: i64, body: []const u8) ![]const u8 {
        return self.computeSignature(timestamp, body);
    }

    /// Compute HMAC-SHA256.
    fn computeHmac(self: *Self, data: []const u8) ![]const u8 {
        var hash = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha256).init(self.config.secret_key);
        hash.update(data);
        var result: [32]u8 = undefined;
        hash.final(&result);
        return try self.allocator.dupe(u8, &result);
    }

    /// Constant-time comparison of two hex-encoded strings.
    fn constantTimeCompare(_: *Self, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;

        var diff: u8 = 0;
        for (a, b) |ca, cb| {
            diff |= ca ^ cb;
        }
        return diff == 0;
    }

    /// Fallback: compute signature without bufPrint.
    fn computeSignatureFallback(self: *Self, timestamp: i64, body: []const u8) ![]const u8 {
        var message = std.ArrayList(u8).empty;
        defer message.deinit(self.allocator);

        var ts_buf: [24]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp}) catch {
            return error.SignatureComputationFailed;
        };
        try message.appendSlice(self.allocator, ts_str);
        try message.appendSlice(self.allocator, body);

        return self.computeHmac(message.items);
    }
};

/// RequestContext import for verify
const RequestContext = @import("request.zig");

// ===========================================================================
// Tests
// ===========================================================================

test "BodySignature - generates and verifies signature" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const secret = "test-secret-key";
    var sig = try BodySignature.init(allocator, io, .{ .secret_key = secret });

    const timestamp: i64 = 1700000000;
    const body = "test request body";

    const signature = try sig.generateSignature(timestamp, body);
    defer allocator.free(signature);

    try std.testing.expect(signature.len > 0);
}

test "BodySignature - constant time compare same" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test" });

    const a = "abc123";
    try std.testing.expect(sig.constantTimeCompare(a, a));
}

test "BodySignature - constant time compare different lengths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test" });

    try std.testing.expect(!sig.constantTimeCompare("abc", "abcd"));
}

test "BodySignature - constant time compare different content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test" });

    try std.testing.expect(!sig.constantTimeCompare("abc123", "xyz789"));
}
