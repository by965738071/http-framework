//! CORS 中间件 — 迁移到新架构
//!
//! 处理跨域请求：
//! - 简单请求：添加 Access-Control-Allow-Origin 等头
//! - 预检请求（OPTIONS）：直接响应，不调 next
//!
//! 依赖：http_app.Middleware（next 回调模型）

const std = @import("std");
const root = @import("root.zig");
const Context = root.Context;
const Response = root.Response;
const Next = root.Next;

const http = std.http;

pub const CorsConfig = struct {
    /// null = 通配符（允许所有源）
    allowed_origins: ?[]const []const u8 = null,
    allowed_methods: []const http.Method = &.{ .GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS },
    allowed_headers: ?[]const []const u8 = &.{ "Content-Type", "Authorization", "X-CSRF-Token" },
    exposed_headers: ?[]const []const u8 = null,
    allow_credentials: bool = false,
    max_age: ?u32 = 86400,
    block_unauthorized: bool = false,
};

pub const CorsMiddleware = struct {
    config: CorsConfig,
    // 注意：不再持有 arena 字段。CORS 头字符串用请求级 ctx.arena
    // 分配，连接结束自动回收。旧实现用 page_allocator 字段，
    // 每个 CORS 请求泄漏几十字节（fix.md §三.2）。
    const Self = @This();

    /// 中间件入口：
    /// - 无 Origin 头 → 放行
    /// - Origin 不在白名单且 block_unauthorized → 403
    /// - OPTIONS 预检（带 Access-Control-Request-Method）→ 添加 CORS 头并直接响应
    /// - 简单请求 → 添加 CORS 头后调 next
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        const is_preflight = ctx.request.method == .OPTIONS and
            ctx.request.getHeader("Access-Control-Request-Method") != null;

        const origin = ctx.request.getHeader("Origin") orelse {
            try next.call(ctx, res);
            return;
        };

        if (!self.isOriginAllowed(origin)) {
            if (self.config.block_unauthorized) {
                _ = res.statusCode(.forbidden);
                try res.text("CORS: origin not allowed");
                return; // short-circuit
            }
            // 不 block 但也不加 CORS 头——浏览器会自己拒绝。
            // 配了白名单时响应随 Origin 而变，补 Vary: Origin 防缓存污染。
            if (self.config.allowed_origins != null) _ = res.header("Vary", "Origin") catch {};
            try next.call(ctx, res);
            return;
        }

        // 添加 CORS 头（用请求级 arena，连接结束自动回收）
        try self.addCorsHeaders(ctx.arena, res, origin, is_preflight);

        // OPTIONS 预检请求：直接响应
        if (is_preflight) {
            _ = res.statusCode(.no_content);
            try res.text("");
            return; // short-circuit，不调 next
        }

        try next.call(ctx, res);
    }

    fn isOriginAllowed(self: *const Self, origin: []const u8) bool {
        const allowed = self.config.allowed_origins orelse return true; // null = 通配符
        for (allowed) |o| {
            if (std.mem.eql(u8, o, origin)) return true;
        }
        return false;
    }

    fn addCorsHeaders(self: *Self, arena: std.mem.Allocator, res: *Response, origin: []const u8, is_preflight: bool) !void {
        // Allow-Origin
        // 修复 D1：禁止“反射任意 Origin + 允许凭据”这个 CORS 规范禁止的组合。
        const wildcard = self.config.allowed_origins == null;
        if (wildcard and self.config.allow_credentials) {
            _ = try res.header("Access-Control-Allow-Origin", "*");
            // 此时不发 Allow-Credentials（`*` 与凭据互斥）。
        } else if (wildcard) {
            _ = try res.header("Access-Control-Allow-Origin", "*");
        } else {
            // 白名单命中：反射具体 Origin，补 Vary: Origin 防缓存污染。
            _ = try res.header("Access-Control-Allow-Origin", origin);
            _ = try res.header("Vary", "Origin");
            if (self.config.allow_credentials) {
                _ = try res.header("Access-Control-Allow-Credentials", "true");
            }
        }

        // 以下头仅在预检（OPTIONS + Access-Control-Request-Method）时才有意义，
        // 简单请求不应携带（避免每个响应冗余头）。
        if (is_preflight) {
            if (self.config.allowed_methods.len > 0) {
                const methods_str = try joinMethods(arena, self.config.allowed_methods);
                _ = try res.header("Access-Control-Allow-Methods", methods_str);
            }
            if (self.config.allowed_headers) |headers| {
                if (headers.len > 0) {
                    const headers_str = try joinStrings(arena, headers, ", ");
                    _ = try res.header("Access-Control-Allow-Headers", headers_str);
                }
            }
            if (self.config.max_age) |age| {
                const age_str = try std.fmt.allocPrint(arena, "{d}", .{age});
                _ = try res.header("Access-Control-Max-Age", age_str);
            }
        }

        // Expose-Headers 对实际响应（非预检）有意义。
        if (self.config.exposed_headers) |headers| {
            if (headers.len > 0) {
                const exposed_str = try joinStrings(arena, headers, ", ");
                _ = try res.header("Access-Control-Expose-Headers", exposed_str);
            }
        }
    }
};

fn joinMethods(arena: std.mem.Allocator, methods: []const http.Method) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(arena);
    for (methods, 0..) |m, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, @tagName(m));
    }
    return buf.toOwnedSlice(arena);
}

fn joinStrings(arena: std.mem.Allocator, strings: []const []const u8, sep: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(arena);
    for (strings, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(arena, sep);
        try buf.appendSlice(arena, s);
    }
    return buf.toOwnedSlice(arena);
}

// ===========================================================================
// Tests
// ===========================================================================

test "CorsConfig defaults" {
    const cfg = CorsConfig{};
    try std.testing.expect(cfg.allowed_origins == null);
    try std.testing.expectEqual(@as(usize, 6), cfg.allowed_methods.len);
    try std.testing.expectEqual(true, cfg.allow_credentials == false);
}

test "CorsMiddleware isOriginAllowed - wildcard (null)" {
    const cors = CorsMiddleware{ .config = .{} };
    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(cors.isOriginAllowed("https://evil.com"));
}

test "CorsMiddleware isOriginAllowed - exact match" {
    const origins = [_][]const u8{ "https://example.com", "https://api.example.com" };
    const cors = CorsMiddleware{
        .config = .{ .allowed_origins = &origins },
    };
    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(cors.isOriginAllowed("https://api.example.com"));
    try std.testing.expect(!cors.isOriginAllowed("https://evil.com"));
}
test {
    std.testing.refAllDecls(@This());
}