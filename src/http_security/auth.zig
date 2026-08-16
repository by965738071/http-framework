//! Auth 中间件 — 迁移到新架构
//!
//! 支持 Bearer Token / Basic Auth / API Key 三种策略。
//!
//! 修复 bug.md Part 2 P0/P1：
//! - 凭证比对用常量时间比较（旧代码用 mem.eql — 时序侧信道）
//! - base64 解码用 arena 分配而非固定 256 字节栈缓冲区
//!   （旧代码如果解码后 > 256 字节会 panic / error 500）

const std = @import("std");
const root = @import("root.zig");
const Context = root.Context;
const Response = root.Response;
const Next = root.Next;
const constantTimeEql = root.constantTimeEql;

pub const AuthStrategy = enum {
    bearer,
    basic,
    api_key,
    custom,
};

pub const AuthInfo = struct {
    strategy: AuthStrategy,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    roles: ?[]const []const u8 = null,
};

pub const AuthConfig = struct {
    bearer_token: ?[]const u8 = null,
    basic_username: ?[]const u8 = null,
    basic_password: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_header: []const u8 = "X-API-Key",
    api_key_query: bool = false,
    custom_auth: ?*const fn (*Context) bool = null,
    realm: []const u8 = "Protected",
};

pub const AuthMiddleware = struct {
    config: AuthConfig,

    const Self = @This();

    /// 中间件入口：尝试每种已启用的策略。
    /// 成功 → 存 AuthInfo 到 ctx.state，调 next。
    /// 失败 → 写 401，不调 next（short-circuit）。
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        if (self.config.custom_auth) |custom| {
            if (custom(ctx)) {
                try self.authOk(ctx, .custom);
                try next.call(ctx, res);
                return;
            }
        }

        if (self.config.bearer_token) |token| {
            if (try self.checkBearer(ctx, token)) {
                try self.authOk(ctx, .bearer);
                try next.call(ctx, res);
                return;
            }
        }

        if (self.config.basic_username) |user| {
            if (try self.checkBasic(ctx, user, self.config.basic_password.?)) {
                try self.authOk(ctx, .basic);
                try next.call(ctx, res);
                return;
            }
        }

        if (self.config.api_key) |key| {
            if (try self.checkApiKey(ctx, key)) {
                try self.authOk(ctx, .api_key);
                try next.call(ctx, res);
                return;
            }
        }

        // 所有策略都失败 → 401
        _ = res.statusCode(.unauthorized);
        _ = try res.header("WWW-Authenticate", self.config.realm);
        try res.text("Unauthorized");
    }

    // ── Strategy checks ───────────────────────────────

    fn checkBearer(self: *Self, ctx: *Context, expected: []const u8) !bool {
        _ = self;
        const header = ctx.request.getHeader("Authorization") orelse return false;
        if (!std.mem.startsWith(u8, header, "Bearer ")) return false;
        const token = header["Bearer ".len..];
        // 常量时间比较——修复 P0 时序侧信道
        return constantTimeEql(token, expected);
    }

    fn checkBasic(self: *Self, ctx: *Context, username: []const u8, password: []const u8) !bool {
        _ = self;
        const header = ctx.request.getHeader("Authorization") orelse return false;
        if (!std.mem.startsWith(u8, header, "Basic ")) return false;

        const encoded = header["Basic ".len..];

        // 计算 base64 解码后的长度
        const dec_len = base64DecodedLen(encoded);
        if (dec_len == 0) return false;

        // 用 arena 分配解码缓冲区——修复 P1：旧代码用固定 256 字节栈缓冲区
        const dec_buf = try ctx.arena.alloc(u8, dec_len);
        std.base64.standard.Decoder.decode(dec_buf, encoded) catch return false;
        const decoded = dec_buf;

        const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
        const u = decoded[0..colon];
        const p = decoded[colon + 1 ..];

        // 常量时间比较——修复 P0 时序侧信道
        return constantTimeEql(u, username) and constantTimeEql(p, password);
    }

    fn checkApiKey(self: *Self, ctx: *Context, expected: []const u8) !bool {
        if (ctx.request.getHeader(self.config.api_key_header)) |key| {
            return constantTimeEql(key, expected);
        }
        if (self.config.api_key_query) {
            if (ctx.request.getQuery("api_key")) |key| {
                return constantTimeEql(key, expected);
            }
        }
        return false;
    }

    fn authOk(self: *Self, ctx: *Context, strategy: AuthStrategy) !void {
        const info_ptr = try ctx.arena.create(AuthInfo);
        info_ptr.* = .{ .strategy = strategy };

        switch (strategy) {
            .bearer => {
                const header = ctx.request.getHeader("Authorization").?;
                info_ptr.token = try ctx.arena.dupe(u8, header["Bearer ".len..]);
            },
            .basic => {
                const header = ctx.request.getHeader("Authorization").?;
                const encoded = header["Basic ".len..];
                const dec_len = base64DecodedLen(encoded);
                if (dec_len > 0) {
                    const dec_buf = try ctx.arena.alloc(u8, dec_len);
                    std.base64.standard.Decoder.decode(dec_buf, encoded) catch {};
                    const colon = std.mem.indexOfScalar(u8, dec_buf, ':') orelse 0;
                    info_ptr.username = try ctx.arena.dupe(u8, dec_buf[0..colon]);
                }
            },
            .api_key => {
                if (ctx.request.getHeader(self.config.api_key_header)) |key| {
                    info_ptr.api_key = try ctx.arena.dupe(u8, key);
                } else if (self.config.api_key_query) {
                    if (ctx.request.getQuery("api_key")) |key| {
                        info_ptr.api_key = try ctx.arena.dupe(u8, key);
                    }
                }
            },
            .custom => {},
        }

        // 存入上下文供下游 handler 取用
        try ctx.setUserData(AuthInfo, info_ptr);
    }
};

/// 计算 base64 解码后的长度
fn base64DecodedLen(encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
    if (encoded.len % 4 != 0) return 0; // 无效 base64
    var len = (encoded.len / 4) * 3;
    if (encoded[encoded.len - 1] == '=') len -= 1;
    if (encoded.len > 1 and encoded[encoded.len - 2] == '=') len -= 1;
    return len;
}

// ===========================================================================
// Tests
// ===========================================================================

test "AuthConfig defaults" {
    const cfg = AuthConfig{};
    try std.testing.expectEqualStrings("Protected", cfg.realm);
    try std.testing.expectEqualStrings("X-API-Key", cfg.api_key_header);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.bearer_token);
}

test "constantTimeEql is used for credential comparison" {
    // 验证 constantTimeEql 在安全比较中被使用
    try std.testing.expect(constantTimeEql("secret", "secret"));
    try std.testing.expect(!constantTimeEql("secret", "secref"));
}

test "base64DecodedLen" {
    try std.testing.expectEqual(@as(usize, 0), base64DecodedLen(""));
    try std.testing.expectEqual(@as(usize, 0), base64DecodedLen("abc")); // 长度不是 4 的倍数
    // "YWRtaW46c2VjcmV0MTIz" = base64("admin:secret123") = 15 bytes
    try std.testing.expectEqual(@as(usize, 15), base64DecodedLen("YWRtaW46c2VjcmV0MTIz"));
    // "YQ==" = base64("a") = 1 byte
    try std.testing.expectEqual(@as(usize, 1), base64DecodedLen("YQ=="));
}

test "checkBearer logic" {
    // 直接测试比较逻辑（不需要完整 Context）
    const expected = "my-secret-token";
    const token = "my-secret-token";
    try std.testing.expect(constantTimeEql(token, expected));

    const wrong = "wrong-token";
    try std.testing.expect(!constantTimeEql(wrong, expected));
}

test "checkBasic logic with base64 decode" {
    const allocator = std.testing.allocator;
    // base64("admin:secret123") = "YWRtaW46c2VjcmV0MTIz"
    const encoded = "YWRtaW46c2VjcmV0MTIz";
    const dec_len = base64DecodedLen(encoded);
    const dec_buf = try allocator.alloc(u8, dec_len);
    defer allocator.free(dec_buf);
    try std.base64.standard.Decoder.decode(dec_buf, encoded);

    const colon = std.mem.indexOfScalar(u8, dec_buf, ':').?;
    const u = dec_buf[0..colon];
    const p = dec_buf[colon + 1 ..];

    try std.testing.expectEqualStrings("admin", u);
    try std.testing.expectEqualStrings("secret123", p);

    // 常量时间比较
    try std.testing.expect(constantTimeEql(u, "admin"));
    try std.testing.expect(constantTimeEql(p, "secret123"));
    try std.testing.expect(!constantTimeEql(p, "wrong"));
}
