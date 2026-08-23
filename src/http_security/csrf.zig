//! CSRF 防护中间件 — 迁移到新架构
//!
//! Double Submit Cookie 模式：
//! 1. 服务端在 Cookie 中设置随机 token
//! 2. 客户端在 X-CSRF-Token 头或表单字段中提交相同 token
//! 3. 常量时间比对两者
//!
//! 修复 bug.md Part 2 P0：旧代码用 mem.eql 比对 token — 时序侧信道。

const std = @import("std");
const root = @import("root.zig");
const Context = root.Context;
const Response = root.Response;
const Next = root.Next;
const constantTimeEql = root.constantTimeEql;

const http = std.http;

pub const CsrfConfig = struct {
    cookie_name: []const u8 = "csrf_token",
    header_name: []const u8 = "X-CSRF-Token",
    form_field_name: []const u8 = "csrf_token",
    token_length: u8 = 32,
    cookie_path: []const u8 = "/",
    secure: bool = false,
    ignored_methods: []const http.Method = &.{ .GET, .HEAD, .OPTIONS },
};

pub const CsrfMiddleware = struct {
    config: CsrfConfig,
    io: std.Io,

    const Self = @This();

    /// 中间件入口：安全方法放行；其他方法验证 CSRF token。
    /// 验证失败时直接写 403 响应并 short-circuit（不调 next）。
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        if (self.isMethodIgnored(ctx.request.method)) {
            // 安全方法：若尚无 CSRF cookie，生成并下发一个（双提交模式需先有 cookie）。
            if (ctx.request.getCookie(self.config.cookie_name) == null) {
                const token = self.generateToken(ctx.arena) catch {
                    try next.call(ctx, res);
                    return;
                };
                self.setCookie(res, token) catch {};
            }
            try next.call(ctx, res);
            return;
        }

        const cookie_token = ctx.request.getCookie(self.config.cookie_name);
        const submitted = ctx.request.getHeader(self.config.header_name) orelse
            ctx.request.getForm(self.config.form_field_name);

        if (cookie_token == null or submitted == null) {
            _ = res.statusCode(.forbidden);
            try res.text("CSRF token missing");
            return; // short-circuit，不调 next
        }

        // 拒绝空 token（否则 constantTimeEql("","") == true 会误放行）。
        if (cookie_token.?.len == 0 or submitted.?.len == 0) {
            _ = res.statusCode(.forbidden);
            try res.text("CSRF token empty");
            return;
        }

        // 常量时间比较——修复 P0 时序侧信道
        if (!constantTimeEql(cookie_token.?, submitted.?)) {
            _ = res.statusCode(.forbidden);
            try res.text("CSRF token mismatch");
            return;
        }

        try next.call(ctx, res);
    }

    /// 生成安全的随机 CSRF token（hex 编码字符串）。
    /// 返回的内存由调用者负责释放。
    pub fn generateToken(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const byte_len = self.config.token_length;
        const random_bytes = try allocator.alloc(u8, byte_len);
        defer allocator.free(random_bytes);

        try std.Io.randomSecure(self.io, random_bytes);

        const hex_len = byte_len * 2;
        const hex = try allocator.alloc(u8, hex_len);
        const hex_chars = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return hex;
    }

    /// 在响应中设置 CSRF Cookie。
    /// 注意：双提交模式要求客户端 JS 能读到该 cookie 并回填到请求头，
    /// 所以**不能**设 HttpOnly（否则 SPA/AJAX 永远读不到 token）。
    pub fn setCookie(self: *const Self, res: *Response, token: []const u8) !void {
        _ = try res.setCookieFull(.{
            .name = self.config.cookie_name,
            .value = token,
            .path = self.config.cookie_path,
            .secure = self.config.secure,
            .http_only = false,
            .same_site = "Strict",
        });
    }

    fn isMethodIgnored(self: *const Self, method: http.Method) bool {
        for (self.config.ignored_methods) |ignored| {
            if (method == ignored) return true;
        }
        return false;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "CsrfConfig defaults" {
    const cfg = CsrfConfig{};
    try std.testing.expectEqualStrings("csrf_token", cfg.cookie_name);
    try std.testing.expectEqualStrings("X-CSRF-Token", cfg.header_name);
    try std.testing.expectEqual(@as(u8, 32), cfg.token_length);
    try std.testing.expectEqual(@as(usize, 3), cfg.ignored_methods.len);
}

test "CsrfMiddleware isMethodIgnored" {
    const csrf = CsrfMiddleware{ .config = .{}, .io = std.testing.io };
    try std.testing.expect(csrf.isMethodIgnored(.GET));
    try std.testing.expect(csrf.isMethodIgnored(.HEAD));
    try std.testing.expect(csrf.isMethodIgnored(.OPTIONS));
    try std.testing.expect(!csrf.isMethodIgnored(.POST));
}

test "CsrfMiddleware.generateToken produces hex string" {
    const allocator = std.testing.allocator;
    const csrf = CsrfMiddleware{ .config = .{ .token_length = 16 }, .io = std.testing.io };
    const token = try csrf.generateToken(allocator);
    defer allocator.free(token);

    try std.testing.expectEqual(@as(usize, 32), token.len);
    for (token) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "CsrfMiddleware.generateToken produces different tokens" {
    const allocator = std.testing.allocator;
    const csrf = CsrfMiddleware{ .config = .{}, .io = std.testing.io };
    const t1 = try csrf.generateToken(allocator);
    defer allocator.free(t1);
    const t2 = try csrf.generateToken(allocator);
    defer allocator.free(t2);
    try std.testing.expect(!std.mem.eql(u8, t1, t2));
}
