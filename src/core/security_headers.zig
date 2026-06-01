//! Security Headers Middleware
//!
//! 为 HTTP 响应添加安全相关的头部，防御常见 Web 漏洞：
//! - XSS（跨站脚本）
//! - Clickjacking（点击劫持）
//! - MIME 类型嗅探
//! - 中间人攻击（HSTS）
//! - 信息泄露（Referrer-Policy、Server）
//!
//! 用法：
//! ```zig
//! var sh = try SecurityHeaders.create(allocator, io, .{});
//! defer sh.deinit();
//! sh.addHeaders(&response);
//! ```

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");

/// 安全头配置
///
/// 所有字段均为可选：`null` 表示不添加对应头部。
pub const SecurityHeadersConfig = struct {
    /// X-Content-Type-Options：禁止 MIME 类型嗅探
    x_content_type_options: ?[]const u8 = "nosniff",

    /// X-Frame-Options：防止点击劫持
    x_frame_options: ?[]const u8 = "DENY",

    /// Content-Security-Policy：内容安全策略
    content_security_policy: ?[]const u8 = "default-src 'self'",

    /// Strict-Transport-Security：强制 HTTPS（生产环境推荐设置）
    strict_transport_security: ?[]const u8 = null,

    /// X-XSS-Protection：启用浏览器 XSS 过滤器
    x_xss_protection: ?[]const u8 = "1; mode=block",

    /// Referrer-Policy：控制 Referer 头信息
    referrer_policy: ?[]const u8 = "strict-origin-when-cross-origin",

    /// Permissions-Policy：控制浏览器功能权限
    permissions_policy: ?[]const u8 = null,

    /// Server：设置或隐藏 Server 响应头（`null` 表示不修改）
    server: ?[]const u8 = null,
};

/// 安全响应头中间件
pub const SecurityHeaders = struct {
    config: SecurityHeadersConfig,
    middleware: Middleware,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 创建安全头中间件实例。
    ///
    /// 内部复制所有字符串字段到自有内存，调用者无需保持 config 存活。
    pub fn create(allocator: std.mem.Allocator, io: std.Io, config: SecurityHeadersConfig) !*Self {
        _ = io;

        const ptr = try allocator.create(Self);
        errdefer allocator.destroy(ptr);

        // 复制所有字符串字段
        var cfg = config;
        if (config.x_content_type_options) |v| cfg.x_content_type_options = try allocator.dupe(u8, v);
        if (config.x_frame_options) |v| cfg.x_frame_options = try allocator.dupe(u8, v);
        if (config.content_security_policy) |v| cfg.content_security_policy = try allocator.dupe(u8, v);
        if (config.strict_transport_security) |v| cfg.strict_transport_security = try allocator.dupe(u8, v);
        if (config.x_xss_protection) |v| cfg.x_xss_protection = try allocator.dupe(u8, v);
        if (config.referrer_policy) |v| cfg.referrer_policy = try allocator.dupe(u8, v);
        if (config.permissions_policy) |v| cfg.permissions_policy = try allocator.dupe(u8, v);
        if (config.server) |v| cfg.server = try allocator.dupe(u8, v);

        ptr.* = .{
            .config = cfg,
            .allocator = allocator,
            .middleware = undefined,
        };
        ptr.middleware = Middleware.init(Self, ptr);
        return ptr;
    }

    /// VTable 中间件入口：安全头中间件为透传，不拦截请求。
    pub fn process(self: *Self, ctx: *RequestContext) !Middleware.NextAction {
        _ = self;
        _ = ctx;
        return .next;
    }

    /// 向响应添加所有配置的安全头。
    ///
    /// 应在发送响应前调用。`null` 值的配置项不会添加。
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

    /// 释放所有自有内存并销毁中间件实例。
    pub fn deinit(self: *Self) void {
        if (self.config.x_content_type_options) |v| self.allocator.free(v);
        if (self.config.x_frame_options) |v| self.allocator.free(v);
        if (self.config.content_security_policy) |v| self.allocator.free(v);
        if (self.config.strict_transport_security) |v| self.allocator.free(v);
        if (self.config.x_xss_protection) |v| self.allocator.free(v);
        if (self.config.referrer_policy) |v| self.allocator.free(v);
        if (self.config.permissions_policy) |v| self.allocator.free(v);
        if (self.config.server) |v| self.allocator.free(v);
        self.allocator.destroy(self);
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
    try std.testing.expectEqualStrings("1; mode=block", cfg.x_xss_protection.?);
    try std.testing.expectEqualStrings("strict-origin-when-cross-origin", cfg.referrer_policy.?);
    try std.testing.expectEqual(null, cfg.strict_transport_security);
    try std.testing.expectEqual(null, cfg.permissions_policy);
    try std.testing.expectEqual(null, cfg.server);
}

test "SecurityHeaders create and deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cfg = SecurityHeadersConfig{
        .strict_transport_security = "max-age=31536000; includeSubDomains",
        .server = "my-server",
    };

    const sh = try SecurityHeaders.create(allocator, io, cfg);
    defer sh.deinit();

    // 验证复制后的值
    try std.testing.expectEqualStrings("max-age=31536000; includeSubDomains", sh.config.strict_transport_security.?);
    try std.testing.expectEqualStrings("my-server", sh.config.server.?);

    // 验证默认值未被修改
    try std.testing.expectEqualStrings("nosniff", sh.config.x_content_type_options.?);
}

test "SecurityHeaders.addHeaders adds configured headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 自定义配置，显式设置 HSTS 和隐藏 Server
    const cfg = SecurityHeadersConfig{
        .strict_transport_security = "max-age=31536000; includeSubDomains",
        .permissions_policy = "camera=(), microphone=()",
    };
    const sh = try SecurityHeaders.create(allocator, io, cfg);
    defer sh.deinit();

    // 创建一个假的 http.Server.Request 用来构造 Response
    var buf: [4096]u8 = undefined;
    const empty_reader = std.Io.Reader.fixed("");
    const buf_writer = std.Io.Writer.fixed(&buf);
    var http_server = std.http.Server.init(
        @constCast(&empty_reader),
        @constCast(&buf_writer),
    );
    var req = std.http.Server.Request{
        .server = &http_server,
        .head = .{
            .method = .GET,
            .target = "/",
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = false,
        },
        .head_buffer = "",
        .respond_err = null,
    };

    var res = Response.init(allocator, &req);
    defer res.deinit();

    try sh.addHeaders(&res);

    // Response 的 headers 列表应该包含配置的头部
    try std.testing.expect(res.headers.items.len >= 6);

    // 验证所有期望的头部都在 headers 列表中
    var found_xcto = false;
    var found_xfo = false;
    var found_csp = false;
    var found_hsts = false;
    var found_xxss = false;
    var found_rp = false;
    var found_pp = false;

    for (res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "X-Content-Type-Options")) {
            try std.testing.expectEqualStrings("nosniff", h.value);
            found_xcto = true;
        } else if (std.mem.eql(u8, h.name, "X-Frame-Options")) {
            try std.testing.expectEqualStrings("DENY", h.value);
            found_xfo = true;
        } else if (std.mem.eql(u8, h.name, "Content-Security-Policy")) {
            try std.testing.expectEqualStrings("default-src 'self'", h.value);
            found_csp = true;
        } else if (std.mem.eql(u8, h.name, "Strict-Transport-Security")) {
            try std.testing.expectEqualStrings("max-age=31536000; includeSubDomains", h.value);
            found_hsts = true;
        } else if (std.mem.eql(u8, h.name, "X-XSS-Protection")) {
            try std.testing.expectEqualStrings("1; mode=block", h.value);
            found_xxss = true;
        } else if (std.mem.eql(u8, h.name, "Referrer-Policy")) {
            try std.testing.expectEqualStrings("strict-origin-when-cross-origin", h.value);
            found_rp = true;
        } else if (std.mem.eql(u8, h.name, "Permissions-Policy")) {
            try std.testing.expectEqualStrings("camera=(), microphone=()", h.value);
            found_pp = true;
        }
    }

    try std.testing.expect(found_xcto);
    try std.testing.expect(found_xfo);
    try std.testing.expect(found_csp);
    try std.testing.expect(found_hsts);
    try std.testing.expect(found_xxss);
    try std.testing.expect(found_rp);
    try std.testing.expect(found_pp);
}

test "SecurityHeaders null values omit headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 全部设为 null — 不应添加任何安全头
    const cfg = SecurityHeadersConfig{
        .x_content_type_options = null,
        .x_frame_options = null,
        .content_security_policy = null,
        .strict_transport_security = null,
        .x_xss_protection = null,
        .referrer_policy = null,
        .permissions_policy = null,
        .server = null,
    };
    const sh = try SecurityHeaders.create(allocator, io, cfg);
    defer sh.deinit();

    var buf: [4096]u8 = undefined;
    const empty_reader2 = std.Io.Reader.fixed("");
    const buf_writer2 = std.Io.Writer.fixed(&buf);
    var http_server = std.http.Server.init(
        @constCast(&empty_reader2),
        @constCast(&buf_writer2),
    );
    var req = std.http.Server.Request{
        .server = &http_server,
        .head = .{
            .method = .GET,
            .target = "/",
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = false,
        },
        .head_buffer = "",
        .respond_err = null,
    };

    var res = Response.init(allocator, &req);
    defer res.deinit();

    try sh.addHeaders(&res);

    // 不应有任何安全相关的头部
    const security_header_names = [_][]const u8{
        "X-Content-Type-Options",
        "X-Frame-Options",
        "Content-Security-Policy",
        "Strict-Transport-Security",
        "X-XSS-Protection",
        "Referrer-Policy",
        "Permissions-Policy",
        "Server",
    };

    for (res.headers.items) |h| {
        for (security_header_names) |name| {
            try std.testing.expect(!std.mem.eql(u8, h.name, name));
        }
    }
}

test "SecurityHeaders middleware VTable process returns next" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const sh = try SecurityHeaders.create(allocator, io, .{});
    defer sh.deinit();

    // VTable process 应该返回 .next（透传）
    const dummy_ctx: *RequestContext = @ptrFromInt(0x1000);
    const action = try sh.middleware.process(dummy_ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}
