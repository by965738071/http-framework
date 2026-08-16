//! 安全响应头中间件 — 迁移到新架构
//!
//! 为响应添加安全相关头部：X-Content-Type-Options, X-Frame-Options, CSP, HSTS 等。

const std = @import("std");
const root = @import("root.zig");
const Context = root.Context;
const Response = root.Response;
const Next = root.Next;

pub const SecurityHeadersConfig = struct {
    x_content_type_options: ?[]const u8 = "nosniff",
    x_frame_options: ?[]const u8 = "DENY",
    content_security_policy: ?[]const u8 = "default-src 'self'",
    strict_transport_security: ?[]const u8 = null,
    x_xss_protection: ?[]const u8 = "1; mode=block",
    referrer_policy: ?[]const u8 = "strict-origin-when-cross-origin",
    permissions_policy: ?[]const u8 = null,
    server: ?[]const u8 = null,
};

pub const SecurityHeaders = struct {
    config: SecurityHeadersConfig,

    const Self = @This();

    /// 中间件入口：添加安全头后调 next。
    /// 用缓冲模式确保头能在 handler 之后也保留。
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        try self.addHeaders(res);
        try next.call(ctx, res);
    }

    pub fn addHeaders(self: *const Self, res: *Response) !void {
        if (self.config.x_content_type_options) |val| {
            _ = try res.header("X-Content-Type-Options", val);
        }
        if (self.config.x_frame_options) |val| {
            _ = try res.header("X-Frame-Options", val);
        }
        if (self.config.content_security_policy) |val| {
            _ = try res.header("Content-Security-Policy", val);
        }
        if (self.config.strict_transport_security) |val| {
            _ = try res.header("Strict-Transport-Security", val);
        }
        if (self.config.x_xss_protection) |val| {
            _ = try res.header("X-XSS-Protection", val);
        }
        if (self.config.referrer_policy) |val| {
            _ = try res.header("Referrer-Policy", val);
        }
        if (self.config.permissions_policy) |val| {
            _ = try res.header("Permissions-Policy", val);
        }
        if (self.config.server) |val| {
            _ = try res.header("Server", val);
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "SecurityHeadersConfig defaults" {
    const cfg = SecurityHeadersConfig{};
    try std.testing.expectEqualStrings("nosniff", cfg.x_content_type_options.?);
    try std.testing.expectEqualStrings("DENY", cfg.x_frame_options.?);
    try std.testing.expectEqualStrings("default-src 'self'", cfg.content_security_policy.?);
    try std.testing.expectEqual(null, cfg.strict_transport_security);
}

test "SecurityHeaders.addHeaders adds configured headers" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, root.http_protocol.Sink.testSink(&writer));
    defer res.deinit();

    const sh = SecurityHeaders{ .config = .{
        .strict_transport_security = "max-age=31536000",
        .permissions_policy = "camera=()",
    } };
    try sh.addHeaders(&res);

    var found_hsts = false;
    var found_pp = false;
    for (res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "Strict-Transport-Security")) found_hsts = true;
        if (std.mem.eql(u8, h.name, "Permissions-Policy")) found_pp = true;
    }
    try std.testing.expect(found_hsts);
    try std.testing.expect(found_pp);
}

test "SecurityHeaders null values omit headers" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, root.http_protocol.Sink.testSink(&writer));
    defer res.deinit();

    const sh = SecurityHeaders{ .config = .{
        .x_content_type_options = null,
        .x_frame_options = null,
        .content_security_policy = null,
        .strict_transport_security = null,
        .x_xss_protection = null,
        .referrer_policy = null,
        .permissions_policy = null,
        .server = null,
    } };
    try sh.addHeaders(&res);

    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
}
