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
        const req: *RequestContext = @ptrCast(@alignCast(ctx));

        const signature = req.getHeader(self.config.header_name) orelse {
            return Error.MissingSignature;
        };
        const timestamp_str = req.getHeader(self.config.timestamp_header) orelse return Error.MissingTimestamp;

        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch {
            return Error.TimestampExpired;
        };

        // Check timestamp window (anti-replay)
        const now_s: i64 = @intCast(@divTrunc(
            std.Io.Clock.now(.real, self.io).nanoseconds,
            1_000_000_000,
        ));
        if (@abs(now_s - timestamp) > @as(i64, @intCast(self.config.window_ms / 1000))) {
            return Error.TimestampExpired;
        }

        // Read the request body
        const body = req.readBody() catch return Error.BodyReadFailed;

        // Compute expected signature
        const expected = self.computeSignature(timestamp, body) catch return Error.SignatureMismatch;
        defer self.allocator.free(expected);

        // Constant-time comparison to prevent timing attacks
        if (!self.constantTimeCompare(signature, expected)) {
            return Error.SignatureMismatch;
        }
    }

    /// Compute HMAC-SHA256 signature for the given timestamp and body.
    pub fn computeSignature(self: *Self, timestamp: i64, body: []const u8) ![]const u8 {
        // Message format: timestamp + body
        var msg_buf: [64]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&msg_buf, "{d}", .{timestamp}) catch unreachable;

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

    /// Compute HMAC-SHA256 and return hex-encoded string.
    fn computeHmac(self: *Self, data: []const u8) ![]const u8 {
        var hash = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha256).init(self.config.secret_key);
        hash.update(data);
        var result: [32]u8 = undefined;
        hash.final(&result);

        // Hex-encode for use in HTTP headers
        const hex = try self.allocator.alloc(u8, 64);
        for (result, 0..) |byte, i| {
            const hi_digit = std.fmt.digitToChar(byte >> 4, .lower);
            const lo_digit = std.fmt.digitToChar(byte & 0xF, .lower);
            hex[i * 2] = hi_digit;
            hex[i * 2 + 1] = lo_digit;
        }
        return hex;
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
};

/// RequestContext import for verify
const RequestContext = @import("core").RequestContext;

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

test "BodySignature - verify returns MissingSignature without header" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    // Create a minimal request context without X-Signature header
    const request_bytes = "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };
    var ctx = try RequestContext.init(allocator, io, &req);
    defer ctx.deinit();

    // Pre-set body data to avoid actual TCP read
    ctx.body_read = true;
    ctx.body_data = try allocator.dupe(u8, "{\"key\":\"value\"}");

    const result = sig.verify(@ptrCast(&ctx));
    try std.testing.expectError(Error.MissingSignature, result);
}

test "BodySignature - verify returns MissingTimestamp without timestamp header" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    const request_bytes = "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Signature: abc123\r\n" ++
        "\r\n";
    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };
    var ctx = try RequestContext.init(allocator, io, &req);
    defer ctx.deinit();

    ctx.body_read = true;
    ctx.body_data = try allocator.dupe(u8, "body");

    const result = sig.verify(@ptrCast(&ctx));
    try std.testing.expectError(Error.MissingTimestamp, result);
}

test "BodySignature - verify returns TimestampExpired for old timestamp" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{
        .secret_key = "test-key",
        .window_ms = 1000, // 1 second window
    });

    const old_timestamp = "1000000000"; // year 2001
    const request_bytes = "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Signature: abc\r\n" ++
        "X-Timestamp: " ++ old_timestamp ++ "\r\n" ++
        "\r\n";
    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };
    var ctx = try RequestContext.init(allocator, io, &req);
    defer ctx.deinit();

    ctx.body_read = true;
    ctx.body_data = try allocator.dupe(u8, "body");

    const result = sig.verify(@ptrCast(&ctx));
    try std.testing.expectError(Error.TimestampExpired, result);
}

test "BodySignature - verify returns SignatureMismatch for wrong signature" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    // Use current timestamp to avoid expiry
    const now_s: i64 = @intCast(@divTrunc(
        std.Io.Clock.now(.real, io).nanoseconds,
        1_000_000_000,
    ));
    var ts_buf: [24]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now_s}) catch unreachable;

    var req_buf: [4096]u8 = undefined;
    const request_bytes = try std.fmt.bufPrint(&req_buf, "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Signature: {s}\r\n" ++
        "X-Timestamp: {s}\r\n" ++
        "\r\n", .{ "this-is-a-wrong-signature-that-will-not-match", ts_str });

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };
    var ctx = try RequestContext.init(allocator, io, &req);
    defer ctx.deinit();

    ctx.body_read = true;
    ctx.body_data = try allocator.dupe(u8, "request body data");

    const result = sig.verify(@ptrCast(&ctx));
    try std.testing.expectError(Error.SignatureMismatch, result);
}

test "BodySignature - verify succeeds with valid signature" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    const body = "{\"name\":\"test\"}";

    // Use current timestamp to avoid expiry
    const now_s: i64 = @intCast(@divTrunc(
        std.Io.Clock.now(.real, io).nanoseconds,
        1_000_000_000,
    ));

    // Generate a valid signature
    const expected_sig = try sig.generateSignature(now_s, body);
    defer allocator.free(expected_sig);

    var ts_buf: [24]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now_s}) catch unreachable;

    var req_buf: [4096]u8 = undefined;
    const request_bytes = try std.fmt.bufPrint(&req_buf, "POST /api/data HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Signature: {s}\r\n" ++
        "X-Timestamp: {s}\r\n" ++
        "\r\n", .{ expected_sig, ts_str });
    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };
    var ctx = try RequestContext.init(allocator, io, &req);
    defer ctx.deinit();

    ctx.body_read = true;
    const body_dup = try allocator.dupe(u8, body);
    ctx.body_data = body_dup;

    try sig.verify(@ptrCast(&ctx));
}

test "BodySignature - generateSignature returns 64-char hex string" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    const timestamp: i64 = 1700000000;
    const body = "test request body";

    const signature = try sig.generateSignature(timestamp, body);
    defer allocator.free(signature);

    // HMAC-SHA256 -> 32 bytes -> 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), signature.len);

    // All characters should be valid hex
    for (signature) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "BodySignature - different data produces different signature" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sig = try BodySignature.init(allocator, io, .{ .secret_key = "test-key" });

    const sig1 = try sig.generateSignature(100, "hello");
    defer allocator.free(sig1);

    const sig2 = try sig.generateSignature(100, "world");
    defer allocator.free(sig2);

    const sig3 = try sig.generateSignature(200, "hello");
    defer allocator.free(sig3);

    // Different body -> different signature
    try std.testing.expect(!std.mem.eql(u8, sig1, sig2));
    // Different timestamp -> different signature
    try std.testing.expect(!std.mem.eql(u8, sig1, sig3));
}
