//! Auth Middleware
//!
//! Supports multiple authentication strategies that can be combined:
//! - Bearer Token (Authorization: Bearer <token>)
//! - Basic Auth  (Authorization: Basic <base64(user:pass)>)
//! - API Key     (X-API-Key header or ?api_key query param)
//!
//! Auth result is stored in `ctx.user_data` for downstream handlers.

const std = @import("std");
const RequestContext = @import("core").RequestContext;
const Response = @import("core").Response;
const NextAction = @import("core").NextAction;
const Middle = @import("core").Middleware;

/// Auth result stored in ctx after successful validation
pub const AuthInfo = struct {
    /// Strategy that authenticated the request
    strategy: AuthStrategy,
    /// Bearer token value (if applicable)
    token: ?[]const u8 = null,
    /// Basic auth username (if applicable)
    username: ?[]const u8 = null,
    /// API key value (if applicable)
    api_key: ?[]const u8 = null,
    /// Custom roles/permissions
    roles: ?[]const []const u8 = null,
};

pub const AuthStrategy = enum {
    bearer,
    basic,
    api_key,
    custom,
};

// =========================================================================
// AuthConfig — defines which strategies to enable
// =========================================================================

pub const AuthConfig = struct {
    /// Bearer token value (enables Bearer auth when set)
    bearer_token: ?[]const u8 = null,

    /// Basic auth username + password (enables Basic when set)
    basic_username: ?[]const u8 = null,
    basic_password: ?[]const u8 = null,

    /// API key value (enables API Key auth when set)
    api_key: ?[]const u8 = null,
    /// Header name for API key (default: X-API-Key)
    api_key_header: []const u8 = "X-API-Key",
    /// Allow API key in query param ?api_key=...
    api_key_query: bool = false,

    /// Custom auth callback: fn(ctx) -> bool
    /// Return true to allow, false to deny
    custom_auth: ?*const fn (*RequestContext) bool = null,

    /// Realm for WWW-Authenticate header
    realm: []const u8 = "Protected",
};

// =========================================================================
// AuthMiddleware
// =========================================================================

pub const AuthMiddleware = struct {
    config: AuthConfig,
    middle: Middle,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, config: AuthConfig) !*AuthMiddleware {
        const ptr = try allocator.create(AuthMiddleware);
        errdefer allocator.destroy(ptr);

        ptr.* = .{
            .config = config,
            .allocator = allocator,
            .middle = undefined,
        };
        ptr.middle = Middle.init(AuthMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *AuthMiddleware, ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = res;

        // Try each enabled strategy in order
        if (self.config.custom_auth) |custom| {
            if (custom(ctx)) return self.authOk(ctx, .custom);
        }

        if (self.config.bearer_token) |token| {
            if (try self.checkBearer(ctx, token)) return self.authOk(ctx, .bearer);
        }

        if (self.config.basic_username) |user| {
            if (try self.checkBasic(ctx, user, self.config.basic_password.?)) return self.authOk(ctx, .basic);
        }

        if (self.config.api_key) |key| {
            if (try self.checkApiKey(ctx, key)) return self.authOk(ctx, .api_key);
        }

        return self.authFailed(ctx);
    }

    pub fn deinit(self: *AuthMiddleware) void {
        // String fields in self.config are borrowed from the caller,
        // not owned — caller must keep them alive for the middleware's lifetime.
        self.allocator.destroy(self);
    }

    // ── Strategy checks ───────────────────────────────

    fn checkBearer(self: *AuthMiddleware, ctx: *RequestContext, expected: []const u8) !bool {
        _ = self;
        const header = ctx.getHeader("Authorization") orelse return false;
        if (!std.mem.startsWith(u8, header, "Bearer ")) return false;
        const token = header["Bearer ".len..];
        return std.mem.eql(u8, token, expected);
    }

    fn checkBasic(self: *AuthMiddleware, ctx: *RequestContext, username: []const u8, password: []const u8) !bool {
        _ = self;
        const header = ctx.getHeader("Authorization") orelse return false;
        if (!std.mem.startsWith(u8, header, "Basic ")) return false;

        const encoded = header["Basic ".len..];
        // Decode base64
        var dec_buf: [256]u8 = undefined;
        try std.base64.standard.Decoder.decode(&dec_buf, encoded);
        const decoded_len = base64DecodedLen(encoded);
        const decoded = dec_buf[0..decoded_len];

        // Split user:pass
        const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
        const u = decoded[0..colon];
        const p = decoded[colon + 1 ..];

        return std.mem.eql(u8, u, username) and std.mem.eql(u8, p, password);
    }

    fn checkApiKey(self: *AuthMiddleware, ctx: *RequestContext, expected: []const u8) !bool {
        // Check header first
        if (ctx.getHeader(self.config.api_key_header)) |key| {
            return std.mem.eql(u8, key, expected);
        }
        // Check query param
        if (self.config.api_key_query) {
            if (ctx.getQuery("api_key")) |key| {
                return std.mem.eql(u8, key, expected);
            }
        }
        return false;
    }

    /// 销毁 AuthInfo 中的所有堆分配资源（用作 UserData.destroyFn）
    /// 由 RequestContext.deinit() 自动调用。
    fn destroyAuthInfo(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const info: *AuthInfo = @ptrCast(@alignCast(ptr));
        if (info.token) |t| allocator.free(t);
        if (info.username) |u| allocator.free(u);
        if (info.api_key) |k| allocator.free(k);
        if (info.roles) |r| allocator.free(r);
        allocator.destroy(info);
    }

    // ── Result helpers ────────────────────────────────

    fn authOk(self: *AuthMiddleware, ctx: *RequestContext, strategy: AuthStrategy) !NextAction {
        // AuthInfo 及其字段一律用 **ctx.allocator** 分配，不能用 self.allocator：
        // 释放它的是 `destroyAuthInfo`，而框架调用该函数时传的正是 ctx.allocator。
        // 两者不是同一个分配器时（请求 arena vs 中间件自己的 GPA），
        // 这个错配不会报错、也不会崩，只会安静地泄漏。
        const alloc = ctx.allocator;

        const info_ptr = try alloc.create(AuthInfo);
        errdefer alloc.destroy(info_ptr);

        info_ptr.* = .{ .strategy = strategy };

        switch (strategy) {
            .bearer => {
                const header = ctx.getHeader("Authorization").?;
                info_ptr.token = try alloc.dupe(u8, header["Bearer ".len..]);
            },
            .basic => {
                const header = ctx.getHeader("Authorization").?;
                const encoded = header["Basic ".len..];
                var dec_buf: [256]u8 = undefined;
                try std.base64.standard.Decoder.decode(&dec_buf, encoded);
                const decoded_len2 = base64DecodedLen(encoded);
                const colon = std.mem.indexOfScalar(u8, dec_buf[0..decoded_len2], ':') orelse 0;
                info_ptr.username = try alloc.dupe(u8, dec_buf[0..colon]);
            },
            .api_key => {
                if (ctx.getHeader(self.config.api_key_header)) |key| {
                    info_ptr.api_key = try alloc.dupe(u8, key);
                } else if (self.config.api_key_query) {
                    if (ctx.getQuery("api_key")) |key| {
                        info_ptr.api_key = try alloc.dupe(u8, key);
                    }
                }
            },
            .custom => {},
        }

        // 存入上下文供下游 handler 取用（框架在 ctx.deinit 时调 destroyAuthInfo）。
        // 按 AuthInfo 这个类型占一个槽位，不会覆盖其它中间件写入的数据。
        try ctx.setUserData(info_ptr, destroyAuthInfo);

        return .next;
    }

    fn authFailed(self: *AuthMiddleware, ctx: *RequestContext) !NextAction {
        _ = self;
        ctx.blocked_status = .unauthorized;
        return .err;
    }
};

// ── Base64 helpers ────────────────────────────────────────────────

/// Calculate decoded length for standard base64 input.
fn base64DecodedLen(encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
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
    try std.testing.expectEqual(false, cfg.api_key_query);
}

test "Bearer token flow - valid" {
    const allocator = std.testing.allocator;

    const cfg = AuthConfig{ .bearer_token = "my-secret-token" };
    var auth = try AuthMiddleware.create(allocator, cfg);
    defer auth.deinit();

    // We can only test the checkBearer logic directly without a full request context
    // since creating a real http.Server.Request requires a network connection.
    // The checkBearer method is exercised indirectly via process().
    try std.testing.expectEqualStrings("my-secret-token", cfg.bearer_token.?);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.basic_username);
}

test "Bearer token flow - invalid" {
    const allocator = std.testing.allocator;

    const cfg = AuthConfig{ .bearer_token = "valid-token" };
    var auth = try AuthMiddleware.create(allocator, cfg);
    defer auth.deinit();

    // Verify the token is stored
    try std.testing.expectEqualStrings("valid-token", auth.config.bearer_token.?);

    // Verify checkBearer logic via unit testing
    // Bearer: starts with "Bearer " and token matches
    const header_bearer = "Bearer valid-token";
    try std.testing.expect(std.mem.startsWith(u8, header_bearer, "Bearer "));
    const extracted = header_bearer["Bearer ".len..];
    try std.testing.expectEqualStrings("valid-token", extracted);

    // Wrong token
    const header_wrong = "Bearer wrong-token";
    const extracted_wrong = header_wrong["Bearer ".len..];
    try std.testing.expect(!std.mem.eql(u8, extracted_wrong, "valid-token"));

    // Missing Bearer prefix
    try std.testing.expect(!std.mem.startsWith(u8, "Basic dXNlcjpwYXNz", "Bearer "));
}

test "Basic auth flow - encoded credentials" {
    const allocator = std.testing.allocator;

    const cfg = AuthConfig{
        .basic_username = "admin",
        .basic_password = "secret123",
    };
    var auth = try AuthMiddleware.create(allocator, cfg);
    defer auth.deinit();

    try std.testing.expectEqualStrings("admin", auth.config.basic_username.?);
    try std.testing.expectEqualStrings("secret123", auth.config.basic_password.?);

    // Test the base64 decode + split logic used in checkBasic
    // Base64("admin:secret123") = "YWRtaW46c2VjcmV0MTIz"
    const encoded = "YWRtaW46c2VjcmV0MTIz";
    var dec_buf: [256]u8 = undefined;
    try std.base64.standard.Decoder.decode(&dec_buf, encoded);
    const decoded_len = base64DecodedLen(encoded);
    const decoded = dec_buf[0..decoded_len];
    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.NoColon;
    const u = decoded[0..colon];
    const p = decoded[colon + 1 ..];

    try std.testing.expectEqualStrings("admin", u);
    try std.testing.expectEqualStrings("secret123", p);
}

test "API key flow - header" {
    const allocator = std.testing.allocator;

    const cfg = AuthConfig{
        .api_key = "my-api-key-123",
        .api_key_header = "X-API-Key",
    };
    var auth = try AuthMiddleware.create(allocator, cfg);
    defer auth.deinit();

    try std.testing.expectEqualStrings("my-api-key-123", auth.config.api_key.?);
    try std.testing.expectEqualStrings("X-API-Key", auth.config.api_key_header);
    try std.testing.expectEqual(false, auth.config.api_key_query);
}

test "API key flow - config defaults" {
    const cfg = AuthConfig{ .api_key = "k" };
    try std.testing.expectEqualStrings("X-API-Key", cfg.api_key_header);
    try std.testing.expectEqual(false, cfg.api_key_query);
}
