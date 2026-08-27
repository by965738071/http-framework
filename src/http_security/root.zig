//! 安全中间件 addon — 迁移到新 4 层架构
//!
//! 依赖：http_app（Context, Middleware, Next）
//!       http_protocol（Request, Response, Sink）
//!
//! 修复 bug.md Part 2 中的 P0/P1 安全缺陷：
//! - CSRF token 比对用常量时间比较（旧代码用 mem.eql — 时序侧信道）
//! - Auth 凭证比对用常量时间比较
//! - Auth base64 解码缓冲区溢出处理（旧代码固定 256 字节、无 catch）

const std = @import("std");
const http_app_mod = @import("http_app");
const http_protocol_mod = @import("http_protocol");

pub const http_protocol = http_protocol_mod;
pub const http_app = http_app_mod;

pub const Context = http_app_mod.Context;
pub const Response = http_protocol_mod.Response;
pub const Middleware = http_app_mod.Middleware;
pub const Next = http_app_mod.Next;
pub const Request = http_protocol_mod.Request;

pub const csrf = @import("csrf.zig");
pub const auth = @import("auth.zig");
pub const cors = @import("cors.zig");
pub const security_headers = @import("security_headers.zig");

/// 常量时间字节比较——防止时序侧信道攻击。
///
/// bug.md §6 root.zig:32-37：旧实现长度不等时直接 return，让比较耗时随输入长度
/// 变化（虽然“长度”本身通常不是机密，但攻击者可以通过响应时间来区分长度匹配与否，
/// 把逐字节猜解变成先猜长度）。修复：循环次数固定为较长者长度，长度差混入累积器，
/// 不提前返回；逐字节 `acc |= x ^ y` 与 std.crypto.timing_safe.eql 的数组版同构。
///
/// 注：`std.crypto.timing_safe.eql` 要求 comptime 定长数组，而认证 token/密码是
/// 变长字符串，无法直接套用；这里复刻其逐 lane 的恒定时间算术。循环体内的分支只
/// 依赖公共信息（输入长度），不依赖秘密字节。
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    const n = @max(a.len, b.len);
    // 长度差直接混入累积器：旧版把长度不等当成「0 填充后逐字节比」，会让
    // "secret\x00" 与 "secret" 误判相等（尾随 NUL 绕过鉴权）。该分支只依赖
    // 公共信息（长度），不泄漏秘密字节；循环次数仍固定为 max 长度。
    var acc: u8 = if (a.len == b.len) 0 else 1;
    for (0..n) |i| {
        const x = if (i < a.len) a[i] else @as(u8, 0);
        const y = if (i < b.len) b[i] else @as(u8, 0);
        acc |= x ^ y;
    }
    return acc == 0;
}

test "constantTimeEql" {
    const std_testing = std.testing;
    try std_testing.expect(constantTimeEql("abc", "abc"));
    try std_testing.expect(!constantTimeEql("abc", "abd"));
    try std_testing.expect(!constantTimeEql("abc", "ab"));
    try std.testing.expect(!constantTimeEql("", "a"));
    try std.testing.expect(constantTimeEql("", ""));
    // 长度不等但多出的字节全为 NUL：必须仍判不等（旧实现 0 填充后误报相等，
    // 造成 `?api_key=secret%00` 这类尾随 NUL 绕过鉴权）。
    try std.testing.expect(!constantTimeEql("abc\x00", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abc\x00"));
}

test {
    std.testing.refAllDecls(@This());
}
