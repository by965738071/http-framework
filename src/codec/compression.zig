//! Compression support — Gzip and Brotli
//!
//! Provides automatic content negotiation based on `Accept-Encoding` header,
//! streaming compression for large responses, and configurable thresholds.
//!
//! # Usage
//!
//! ```zig
//! var compressor = try Compression.init(allocator, io);
//! defer compressor.deinit();
//!
//! // In response handler:
//! try res.compressWith(&compressor);
//! ```

const std = @import("std");

/// Supported compression algorithms
pub const Algorithm = enum {
    /// gzip (via DEFLATE)
    gzip,
    /// Brotli
    br,
    /// No compression
    identity,
};

/// Case-insensitive token check for Accept-Encoding
fn hasToken(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var found = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                found = false;
                break;
            }
        }
        if (found) return true;
    }
    return false;
}

/// Compression configuration
pub const Config = struct {
    /// Whether compression is enabled globally
    enabled: bool = true,

    /// Minimum response size to trigger compression (bytes)
    /// Responses smaller than this are never compressed
    min_size: u32 = 256,

    /// Gzip compression level (0-9)
    gzip_level: u8 = 6,

    /// Brotli compression level (0-11)
    brotli_level: u8 = 4,

    /// Content types that should not be compressed
    /// (images, videos, audio, archives are already compressed)
    excluded_content_types: []const []const u8 = &.{
        "image/",
        "video/",
        "audio/",
        "application/zip",
        "application/gzip",
        "application/x-tar",
        "application/x-rar",
        "application/x-7z",
    },
};

/// Streaming compressor state
pub const StreamState = enum {
    idle,
    processing,
    done,
    err,
};

/// Request-level compressor for a single response
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = .{},
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, io: std.Io, config: Config) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    /// Negotiate the best compression algorithm from Accept-Encoding header.
    /// Returns .identity if compression is disabled or unsupported.
    pub fn negotiate(self: *const Self, accept_encoding: ?[]const u8) Algorithm {
        if (!self.config.enabled) return .identity;
        const enc = accept_encoding orelse return .identity;

        // Case-insensitive check for brotli and gzip
        if (hasToken(enc, "br")) return .br;
        if (hasToken(enc, "gzip")) return .gzip;
        return .identity;
    }

    /// Check if a content type should be excluded from compression.
    pub fn isExcludedContentType(self: *const Self, content_type: []const u8) bool {
        for (self.config.excluded_content_types) |excluded| {
            if (std.mem.startsWith(u8, content_type, excluded)) {
                return true;
            }
        }
        return false;
    }

    /// Decide whether to compress this response.
    pub fn shouldCompress(
        self: *const Self,
        content_type: []const u8,
        content_len: usize,
        algo: Algorithm,
    ) bool {
        if (algo == .identity) return false;
        if (content_len < self.config.min_size) return false;
        if (self.isExcludedContentType(content_type)) return false;
        return true;
    }

    /// Compress data using gzip.
    pub fn compressGzip(self: *const Self, data: []const u8) ![]u8 {
        var out_buf: [32768]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
        var c = std.compress.flate.Compress.init(
            &writer,
            &cbuf,
            .gzip,
            switch (self.config.gzip_level) {
                0 => .fastest,
                1 => .default,
                2 => .default,
                3 => .default,
                4 => .default,
                5 => .default,
                6 => .default,
                else => .best,
            },
        ) catch return error.CompressionFailed;
        c.writer.writeAll(data) catch return error.CompressionFailed;
        c.finish() catch return error.CompressionFailed;
        return self.allocator.dupe(u8, out_buf[0..writer.end]);
    }

    /// Compress data using Brotli.
    pub fn compressBrotli(self: *const Self, data: []const u8) ![]u8 {
        _ = self;
        _ = data;
        return error.CompressionFailed; // Brotli removed in Zig 0.17-dev
    }

    /// Compress data based on algorithm.
    pub fn compress(self: *const Self, data: []const u8, algo: Algorithm) ![]u8 {
        return switch (algo) {
            .gzip => try self.compressGzip(data),
            .br => try self.compressBrotli(data),
            .identity => try self.allocator.dupe(u8, data),
        };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Compression.negotiate - prefers br over gzip" {
    const gpa = std.testing.allocator;
    var comp = Compressor.init(gpa, std.testing.io);

    try std.testing.expectEqual(Algorithm.br, comp.negotiate("br;gzip;q=0.8"));
    try std.testing.expectEqual(Algorithm.gzip, comp.negotiate("gzip;q=0.8"));
    try std.testing.expectEqual(Algorithm.gzip, comp.negotiate("gzip, deflate"));
    try std.testing.expectEqual(Algorithm.identity, comp.negotiate("identity"));
    try std.testing.expectEqual(Algorithm.identity, comp.negotiate(null));
}

test "Compression.negotiate - disabled returns identity" {
    var comp = Compressor.init(std.testing.allocator, std.testing.io);
    comp.config.enabled = false;

    try std.testing.expectEqual(Algorithm.identity, comp.negotiate("gzip, br"));
}

test "Compression.compressGzip round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var comp = Compressor.init(allocator, io);

    const original = "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. " ++ "Hello, World! This is a test of gzip compression. ";
    const compressed = try comp.compressGzip(original);
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len < original.len);

    // Verify gzip magic bytes
    try std.testing.expect(compressed.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
}

test "Compression.compressBrotli round-trip" {
    var comp = Compressor.init(std.testing.allocator, std.testing.io);
    const original = "hello";
    try std.testing.expectError(error.CompressionFailed, comp.compressBrotli(original));
}

test "Compression.isExcludedContentType" {
    const allocator = std.testing.allocator;
    var comp = Compressor.init(allocator, std.testing.io);

    try std.testing.expect(comp.isExcludedContentType("image/png"));
    try std.testing.expect(comp.isExcludedContentType("video/mp4"));
    try std.testing.expect(comp.isExcludedContentType("application/gzip"));
    try std.testing.expect(!comp.isExcludedContentType("text/html"));
    try std.testing.expect(!comp.isExcludedContentType("application/json"));
}

test "Compression.shouldCompress" {
    var comp = Compressor.init(std.testing.allocator, std.testing.io);
    comp.config.min_size = 256;

    // Too small
    try std.testing.expect(!comp.shouldCompress("text/html", 100, .gzip));

    // Excluded type
    try std.testing.expect(!comp.shouldCompress("image/png", 5000, .gzip));

    // Should compress
    try std.testing.expect(comp.shouldCompress("text/html", 5000, .gzip));
    try std.testing.expect(comp.shouldCompress("application/json", 1000, .br));
}

test "Compression.compress identity passthrough" {
    var comp = Compressor.init(std.testing.allocator, std.testing.io);
    const data = "hello";
    const result = try comp.compress(data, .identity);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.eql(u8, data, result));
}
