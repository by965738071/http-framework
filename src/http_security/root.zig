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
/// 长度不同时直接返回 false（长度不是秘密：攻击者知道自己输入多长）。
/// 长度相同时，遍历整个范围，不短路。
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, 0..) |x, i| acc |= x ^ b[i];
    return acc == 0;
}

test "constantTimeEql" {
    const std_testing = std.testing;
    try std_testing.expect(constantTimeEql("abc", "abc"));
    try std_testing.expect(!constantTimeEql("abc", "abd"));
    try std_testing.expect(!constantTimeEql("abc", "ab"));
    try std_testing.expect(!constantTimeEql("", "a"));
    try std_testing.expect(constantTimeEql("", ""));
}

test {
    std.testing.refAllDecls(@This());
}
