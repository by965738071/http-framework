//! 纯校验逻辑（不依赖 framework / ORM，便于单测）。

const std = @import("std");

pub const Limits = struct {
    pub const username_min: usize = 3;
    pub const username_max: usize = 32;
    pub const password_min: usize = 6;
    pub const password_max: usize = 128;
    pub const name_max: usize = 64;
    pub const code_max: usize = 64;
    pub const reason_max: usize = 500;
};

/// 用户名：3~32 位，字母数字下划线短横线点号。
pub fn username(v: []const u8) ?[]const u8 {
    if (v.len < Limits.username_min) return "用户名至少 3 个字符";
    if (v.len > Limits.username_max) return "用户名最多 32 个字符";
    for (v) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return "用户名只能包含字母、数字、下划线、短横线和点号";
    }
    return null;
}

/// 密码强度：只做最小长度与字符集校验（不做复杂度绑架）。
pub fn password(v: []const u8) ?[]const u8 {
    if (v.len < Limits.password_min) return "密码至少 6 位";
    if (v.len > Limits.password_max) return "密码最多 128 位";
    return null;
}

/// 邮箱：极简结构校验（必须有且仅有一个 @，@ 后必须有 .，无空白）。
pub fn email(v: []const u8) ?[]const u8 {
    if (v.len == 0) return "邮箱不能为空";
    if (v.len > 128) return "邮箱过长";
    const at = std.mem.indexOfScalar(u8, v, '@') orelse return "邮箱格式不正确";
    if (at == 0) return "邮箱格式不正确";
    if (std.mem.indexOfScalar(u8, v[(at + 1)..], '@') != null) return "邮箱格式不正确";
    const domain = v[(at + 1)..];
    if (domain.len < 3) return "邮箱格式不正确";
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return "邮箱格式不正确";
    for (v) |c| if (std.ascii.isWhitespace(c)) return "邮箱不能包含空白字符";
    return null;
}

/// 组织 / 角色名称：非空且不超过 64 字符，不允许控制字符。
pub fn displayName(v: []const u8) ?[]const u8 {
    if (v.len == 0) return "名称不能为空";
    if (v.len > Limits.name_max) return "名称最多 64 个字符";
    for (v) |c| if (c < 0x20 or c == 0x7f) return "名称不能包含控制字符";
    return null;
}

/// 编码（org.code / role.code）：字母数字下划线短横线，1~64。
pub fn code(v: []const u8) ?[]const u8 {
    if (v.len == 0) return "编码不能为空";
    if (v.len > Limits.code_max) return "编码最多 64 个字符";
    for (v) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return "编码只能包含字母、数字、下划线和短横线";
    }
    return null;
}

pub fn reason(v: []const u8) ?[]const u8 {
    if (v.len > Limits.reason_max) return "说明最多 500 个字符";
    return null;
}

/// 把第一个失败的校验结果转成 ApiError 友好信息；全部通过返回 null。
pub fn firstError(results: []const ?[]const u8) ?[]const u8 {
    for (results) |r| if (r) |msg| return msg;
    return null;
}

// ── 测试 ────────────────────────────────────────────────────────────────

test "username 校验" {
    try std.testing.expect(username("abc") == null);
    try std.testing.expect(username("a_b-c.d") == null);
    try std.testing.expect(username("ab") != null);
    try std.testing.expect(username("a b") != null);
    try std.testing.expect(username("用户") != null);
    var long: [33]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(username(&long) != null);
}

test "password 校验" {
    try std.testing.expect(password("123456") == null);
    try std.testing.expect(password("12345") != null);
}

test "email 校验" {
    try std.testing.expect(email("a@b.com") == null);
    try std.testing.expect(email("no-at") != null);
    try std.testing.expect(email("a@b") != null);
    try std.testing.expect(email("@b.com") != null);
    try std.testing.expect(email("a@b@c.com") != null);
    try std.testing.expect(email("a b@c.com") != null);
    try std.testing.expect(email("") != null);
}

test "displayName 与 code 校验" {
    try std.testing.expect(displayName("技术中心") == null);
    try std.testing.expect(displayName("") != null);
    try std.testing.expect(displayName("a\nb") != null);
    try std.testing.expect(code("tech_1") == null);
    try std.testing.expect(code("tech 1") != null);
    try std.testing.expect(code("") != null);
}

test "firstError 返回第一个错误" {
    try std.testing.expectEqualStrings("B", firstError(&.{ null, "B", "C" }).?);
    try std.testing.expect(firstError(&.{ null, null }) == null);
}

test {
    std.testing.refAllDecls(@This());
}
