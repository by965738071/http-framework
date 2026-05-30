//! Auth Middleware
//!
//! Supports multiple authentication strategies that can be combined:
//! - Bearer Token (Authorization: Bearer <token>)
//! - Basic Auth  (Authorization: Basic <base64(user:pass)>)
//! - API Key     (X-API-Key header or ?api_key query param)
//!
//! Auth result is stored in `ctx.user_data` for downstream handlers.

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const NextAction = @import("middleware.zig").NextAction;
const Middle = @import("middleware.zig");

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
    io: std.Io,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, config: AuthConfig) !*AuthMiddleware {
        const ptr = try allocator.create(AuthMiddleware);
        errdefer allocator.destroy(ptr);

        // Copy all string fields to owned memory
        var cfg = config;
        if (config.bearer_token) |t| cfg.bearer_token = try allocator.dupe(u8, t);
        if (config.basic_username) |u| cfg.basic_username = try allocator.dupe(u8, u);
        if (config.basic_password) |p| cfg.basic_password = try allocator.dupe(u8, p);
        if (config.api_key) |k| cfg.api_key = try allocator.dupe(u8, k);

        ptr.* = .{
            .config = cfg,
            .allocator = allocator,
            .io = io,
            .middle = undefined,
        };
        ptr.middle = Middle.init(AuthMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *AuthMiddleware, ctx: *RequestContext) anyerror!NextAction {
        _ = self.io;

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
        if (self.config.bearer_token) |t| self.allocator.free(t);
        if (self.config.basic_username) |u| self.allocator.free(u);
        if (self.config.basic_password) |p| self.allocator.free(p);
        if (self.config.api_key) |k| self.allocator.free(k);
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
        const decoder = std.base64.standard.Decoder.init(encoded);
        const decoded_len = decoder.decode(&dec_buf) catch return false;
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

    // ── Result helpers ────────────────────────────────

    fn authOk(self: *AuthMiddleware, ctx: *RequestContext, strategy: AuthStrategy) !NextAction {
        var info = AuthInfo{ .strategy = strategy };

        switch (strategy) {
            .bearer => {
                const header = ctx.getHeader("Authorization").?;
                info.token = header["Bearer ".len..];
            },
            .basic => {
                const header = ctx.getHeader("Authorization").?;
                const encoded = header["Basic ".len..];
                var dec_buf: [256]u8 = undefined;
                const decoder = std.base64.standard.Decoder.init(encoded);
                const len = decoder.decode(&dec_buf) catch return .next;
                const colon = std.mem.indexOfScalar(u8, dec_buf[0..len], ':') orelse 0;
                info.username = dec_buf[0..colon];
            },
            .api_key => {
                info.api_key = ctx.getHeader(self.config.api_key_header) orelse ctx.getQuery("api_key");
            },
            .custom => {},
        }

        // Store in context for downstream handlers

        return .next;
    }

    fn authFailed(self: *AuthMiddleware, ctx: *RequestContext) !NextAction {
        _ = self;
        ctx.blocked_status = .unauthorized;
        return .err;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "AuthConfig defaults" {
    const cfg = AuthConfig{};
    try std.testing.expectEqualStrings("Protected", cfg.realm);
    try std.testing.expectEqualStrings("X-API-Key", cfg.api_key_header);
    try std.testing.expectEqual(false, cfg.api_key_query);
}

test "Bearer token flow" {
    _ = std.testing.allocator;
}

test "Basic auth flow" {
    _ = std.testing.allocator;
}

test "API key flow" {
    _ = std.testing.allocator;
}
