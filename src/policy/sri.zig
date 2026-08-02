//! Subresource Integrity (SRI) — Content-SRI response header
//!
//! Provides SHA-256/384/512 hash computation for static resources,
//! enabling clients to verify resource integrity via SRI.
//!
//! # Usage
//!
//! ```zig
//! var sri = SRI.init(allocator, io);
//! defer sri.deinit();
//!
//! // In static file handler:
//! const hash = try sri.hashFile(path, .sha256);
//! defer allocator.free(hash.toString());
//! try res.header("Content-SRI", hash.toString());
//! ```

const std = @import("std");

/// Hash algorithm
pub const HashAlgorithm = enum {
    sha256,
    sha384,
    sha512,
};

/// Base64 alphabet
const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// A computed SRI hash
pub const SRIHash = struct {
    algorithm: HashAlgorithm,
    base64: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Returns the integrity value for <script integrity="..."> tags.
    pub fn integrityAttr(self: *const Self) []const u8 {
        const algo = switch (self.algorithm) {
            .sha256 => "sha256",
            .sha384 => "sha384",
            .sha512 => "sha512",
        };
        // "sha256-xxxxx"
        // 假设 self 有 allocator 字段
        const result = std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ algo, self.base64 }) catch {
            return "";
        };
        // 注意：如果 algo 是编译时常量，但以 []u8 传递也可以
        return result;
    }

    /// Returns the Content-SRI header value.
    pub fn headerValue(self: *const Self) []const u8 {
        return self.integrityAttr();
    }

    /// Deinitialize the base64 buffer.
    pub fn deinit(_: *Self) void {
        // base64 is allocated from the builder's allocator
        // Caller manages the lifetime via the builder
    }
};

/// SRI hash builder
pub const Builder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    /// Compute hash from memory slice.
    pub fn fromMemory(self: *const Self, data: []const u8, algo: HashAlgorithm) !SRIHash {
        const hash_bytes = try self.computeHash(data, algo);
        defer self.allocator.free(hash_bytes);
        const b64 = try self.base64Encode(hash_bytes);
        return .{
            .algorithm = algo,
            .base64 = b64,
            .allocator = self.allocator,
        };
    }

    /// Compute hash from file.
    pub fn fromFile(self: *const Self, path: []const u8, algo: HashAlgorithm) !SRIHash {
        const data = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(data);
        return self.fromMemory(data, algo);
    }

    /// Compute hash from an existing byte buffer (owned).
    fn computeHash(self: *const Self, data: []const u8, algo: HashAlgorithm) ![]const u8 {
        return switch (algo) {
            .sha256 => {
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update(data);

                var digest: [32]u8 = undefined; // 栈上定长数组
                hash.final(&digest); // 现在类型匹配

                const result = try self.allocator.alloc(u8, 32);
                errdefer self.allocator.free(result);
                @memcpy(result, &digest); // 复制到分配的内存
                return result;
            },
            .sha384 => {
                var hash = std.crypto.hash.sha2.Sha384.init(.{});
                hash.update(data);

                var digest: [48]u8 = undefined;
                hash.final(&digest);

                const result = try self.allocator.alloc(u8, 48);
                errdefer self.allocator.free(result);
                @memcpy(result, &digest);
                return result;
            },
            .sha512 => {
                var hash = std.crypto.hash.sha2.Sha512.init(.{});
                hash.update(data);

                var digest: [64]u8 = undefined;
                hash.final(&digest);

                const result = try self.allocator.alloc(u8, 64);
                errdefer self.allocator.free(result);
                @memcpy(result, &digest);
                return result;
            },
        };
    }

    /// Base64 encode a byte slice.
    fn base64Encode(self: *const Self, data: []const u8) ![]u8 {
        // Base64 output length: ceil(n/3)*4 + 1 (null terminator)
        const output_len = (data.len + 2) / 3 * 4;
        const output = try self.allocator.alloc(u8, output_len);
        errdefer self.allocator.free(output);

        var i: usize = 0;
        var j: usize = 0;
        while (i + 3 <= data.len) : ({
            i += 3;
            j += 4;
        }) {
            const a = data[i];
            const b = data[i + 1];
            const c = data[i + 2];

            output[j] = b64_alphabet[a >> 2];
            output[j + 1] = b64_alphabet[((a & 0x03) << 4) | (b >> 4)];
            output[j + 2] = b64_alphabet[((b & 0x0F) << 2) | (c >> 6)];
            output[j + 3] = b64_alphabet[c & 0x3F];
        }

        // Handle remaining bytes
        const remainder = data.len - i;
        if (remainder == 1) {
            const a = data[i];
            output[j] = b64_alphabet[a >> 2];
            output[j + 1] = b64_alphabet[(a & 0x03) << 4];
            output[j + 2] = '=';
            output[j + 3] = '=';
            j += 4;
        } else if (remainder == 2) {
            const a = data[i];
            const b = data[i + 1];
            output[j] = b64_alphabet[a >> 2];
            output[j + 1] = b64_alphabet[((a & 0x03) << 4) | (b >> 4)];
            output[j + 2] = b64_alphabet[(b & 0x0F) << 2];
            output[j + 3] = '=';
            j += 4;
        }

        return output[0..j];
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "SRI - sha256 from memory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const data = "hello world";
    const sri = try builder.fromMemory(data, .sha256);
    defer allocator.free(sri.base64);

    try std.testing.expect(sri.base64.len > 0);
    const attr = sri.integrityAttr(); // 获取分配的字符串
    defer allocator.free(attr); // 确保释放
    try std.testing.expectEqualStrings("sha256-", attr[0..7]);
    //try std.testing.expectEqualStrings("sha256-", sri.integrityAttr()[0..7]);
}

test "SRI - sha256 known value" {
    // SHA-256 of empty string: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const data: []const u8 = "";
    const sri = try builder.fromMemory(data, .sha256);
    defer allocator.free(sri.base64);

    // Expected: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" in base64 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWzcG3hSuW"
    try std.testing.expectEqualStrings("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", sri.base64);
}

test "SRI - sha384 from memory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const data = "test data";
    const sri = try builder.fromMemory(data, .sha384);
    defer allocator.free(sri.base64);

    try std.testing.expect(sri.base64.len > 0);
}

test "SRI - sha512 from memory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const data = "test data";
    const sri = try builder.fromMemory(data, .sha512);
    defer allocator.free(sri.base64);

    try std.testing.expect(sri.base64.len > 0);
}

test "SRI - different data produces different hashes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const sri1 = try builder.fromMemory("hello", .sha256);
    defer allocator.free(sri1.base64);
    const sri2 = try builder.fromMemory("world", .sha256);
    defer allocator.free(sri2.base64);

    try std.testing.expect(!std.mem.eql(u8, sri1.base64, sri2.base64));
}

test "SRI - same data produces same hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var builder = Builder.init(allocator, io);

    const data = "reproducible test";
    const sri1 = try builder.fromMemory(data, .sha256);
    defer allocator.free(sri1.base64);
    const sri2 = try builder.fromMemory(data, .sha256);
    defer allocator.free(sri2.base64);

    try std.testing.expect(std.mem.eql(u8, sri1.base64, sri2.base64));
}
