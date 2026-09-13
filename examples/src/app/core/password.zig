//! 口令哈希：PBKDF2-HMAC-SHA256 + 每用户随机盐。
//!
//! 存储格式（PHC 风格）：
//!   `pbkdf2-sha256$<rounds>$<salt_hex>$<hash_hex>`
//!
//! 明确**不**做明文比较（现有 examples/src/admin.zig 就是把 password 原样
//! 存进 `password_hash` 字段再字符串相等比较，那是演示代码的遗留问题）。

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const salt_len: usize = 16;
pub const hash_len: usize = 32;
/// 迭代次数：Release 下约几十毫秒；Debug 下 std 未做向量化，会慢一个量级，
/// 所以取偏保守的值，别让登录请求在 Debug 下卡秒级。
pub const rounds: u32 = 10_000;

pub const SchemeError = error{
    MalformedHash,
    UnsupportedScheme,
    InvalidEncoding,
};

/// 由口令 + 盐派生 32 字节密钥。
pub fn derive(password: []const u8, salt: [salt_len]u8) ![hash_len]u8 {
    var dk: [hash_len]u8 = undefined;
    // 注意路径是 `std.crypto.pwhash.pbkdf2`（本版本没有 `std.crypto.pbkdf2`）。
    try std.crypto.pwhash.pbkdf2(&dk, password, &salt, rounds, HmacSha256);
    return dk;
}

/// 生成存储格式串。返回值由 `allocator` 拥有。
pub fn encode(allocator: std.mem.Allocator, password: []const u8, salt: [salt_len]u8) ![]const u8 {
    const dk = try derive(password, salt);
    const salt_hex = std.fmt.bytesToHex(&salt, .lower);
    const hash_hex = std.fmt.bytesToHex(&dk, .lower);
    return std.fmt.allocPrint(
        allocator,
        "pbkdf2-sha256${d}${s}${s}",
        .{ rounds, &salt_hex, &hash_hex },
    );
}

/// 校验口令。哈希格式非法时返回 SchemeError。
pub fn verify(password: []const u8, encoded: []const u8) !bool {
    // 连分隔符都没有的一定不是本格式（而不是「scheme 不支持」）。
    if (std.mem.indexOfScalar(u8, encoded, '$') == null) return error.MalformedHash;
    var parts = std.mem.splitScalar(u8, encoded, '$');
    const scheme = parts.next() orelse return error.MalformedHash;
    if (!std.mem.eql(u8, scheme, "pbkdf2-sha256")) return error.UnsupportedScheme;
    const rounds_str = parts.next() orelse return error.MalformedHash;
    const salt_hex = parts.next() orelse return error.MalformedHash;
    const hash_hex = parts.next() orelse return error.MalformedHash;
    if (parts.next() != null) return error.MalformedHash;

    _ = try std.fmt.parseInt(u32, rounds_str, 10);
    if (salt_hex.len != salt_len * 2) return error.InvalidEncoding;
    if (hash_hex.len != hash_len * 2) return error.InvalidEncoding;

    var salt: [salt_len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&salt, salt_hex);
    var expected: [hash_len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hash_hex);

    const actual = try derive(password, salt);
    return std.crypto.timing_safe.eql([hash_len]u8, expected, actual);
}

/// 生成随机盐。`io` 来自 zio 运行时（框架的 `io.random`）。
pub fn randomSalt(io: std.Io) [salt_len]u8 {
    var salt: [salt_len]u8 = undefined;
    io.random(&salt);
    return salt;
}

// ── 测试 ────────────────────────────────────────────────────────────────

const test_salt: [salt_len]u8 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

test "derive 是确定性的" {
    const a = try derive("secret", test_salt);
    const b = try derive("secret", test_salt);
    try std.testing.expectEqualSlices(u8, &a, &b);
    const c = try derive("secret2", test_salt);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "encode/verify 往返正确" {
    const encoded = try encode(std.testing.allocator, "admin123", test_salt);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "pbkdf2-sha256$"));
    try std.testing.expect(try verify("admin123", encoded));
    try std.testing.expect(!(try verify("wrong", encoded)));
}

test "verify 拒绝畸形哈希" {
    try std.testing.expectError(error.MalformedHash, verify("x", "garbage"));
    try std.testing.expectError(error.UnsupportedScheme, verify("x", "bcrypt$1$aa$bb"));
    const bad_hex = try std.fmt.allocPrint(std.testing.allocator, "pbkdf2-sha256${d}$zz$bb", .{rounds});
    defer std.testing.allocator.free(bad_hex);
    try std.testing.expectError(error.InvalidEncoding, verify("x", bad_hex));
}

test {
    std.testing.refAllDecls(@This());
}
