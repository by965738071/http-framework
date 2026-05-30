//! CORS (Cross-Origin Resource Sharing) 中间件
//!
//! 为 HTTP 服务器添加 CORS 支持，允许或限制跨域请求。
//! 符合 CORS 规范，支持预检请求（OPTIONS）。

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");

/// CORS 配置
pub const CorsConfig = struct {
    /// 允许的源（* 表示任意，或指定具体域名）
    allowed_origins: []const []const u8 = &.{},

    /// 允许的 HTTP 方法
    allowed_methods: []const std.http.Method = &.{},

    /// 允许的请求头
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization" },

    /// 暴露的响应头
    exposed_headers: []const []const u8 = &.{},

    /// 是否允许携带凭证（Cookie、HTTP 认证等）
    allow_credentials: bool = false,

    /// 预检请求缓存时间（秒），默认 24 小时
    max_age: u32 = 86400,
};

/// CORS 中间件
pub const CorsMiddleware = struct {
    config: CorsConfig,
    middleware: Middleware,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 创建 CORS 中间件
    pub fn init(allocator: std.mem.Allocator, config: CorsConfig) !*Self {
        const ptr = try allocator.create(Self);
        ptr.* = .{
            .config = config,
            .middleware = undefined,
            .allocator = allocator,
        };
        ptr.middleware = Middleware.init(Self, ptr);
        return ptr;
    }

    /// 处理请求 - 检查 CORS 并添加响应头
    pub fn process(self: *Self, ctx: *RequestContext) !Middleware.NextAction {
        const origin = ctx.getHeader("Origin");

        // 如果没有 Origin 头，不是跨域请求，直接放行
        if (origin == null) {
            return .next;
        }

        // 检查是否为预检请求（OPTIONS 方法 + Access-Control-Request-Method）
        const is_preflight = ctx.method == .OPTIONS and ctx.getHeader("Access-Control-Request-Method") != null;

        // 检查源是否被允许
        if (self.isOriginAllowed(origin.?)) {
            // 如果是预检请求，需要特殊处理
            if (is_preflight) {
                // 预检请求：设置 CORS 头并返回 204
                // 注意：中间件接口限制，这里需要访问 Response
                // 实际实现需要在路由分发时处理
                return .next;
            }
        } else {
            std.log.warn("CORS: Origin not allowed: {s}", .{origin.?});
        }

        return .next;
    }

    /// 销毁中间件
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// 检查源是否被允许
    fn isOriginAllowed(self: *const Self, origin: []const u8) bool {
        // 如果配置为空，允许所有源（不推荐生产环境使用）
        if (self.config.allowed_origins.len == 0) {
            return true;
        }

        for (self.config.allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, "*") or std.mem.eql(u8, allowed, origin)) {
                return true;
            }
        }
        return false;
    }

    /// 添加 CORS 响应头到 Response
    pub fn addCorsHeaders(self: *const Self, ctx: *RequestContext, res: *Response) !void {
        const origin = ctx.getHeader("Origin") orelse return;

        if (!self.isOriginAllowed(origin)) {
            return;
        }

        // Access-Control-Allow-Origin
        if (self.config.allowed_origins.len == 0) {
            _ = try res.header("Access-Control-Allow-Origin", "*");
        } else {
            _ = try res.header("Access-Control-Allow-Origin", origin);
        }

        // Access-Control-Allow-Methods
        if (self.config.allowed_methods.len > 0) {
            var methods_list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer methods_list.deinit(self.allocator);
            for (self.config.allowed_methods, 0..) |method, i| {
                if (i > 0) try methods_list.appendSlice(self.allocator, ", ");
                try methods_list.appendSlice(self.allocator, @tagName(method));
            }
            const methods_str = try methods_list.toOwnedSlice(self.allocator);
            defer self.allocator.free(methods_str);
            _ = try res.header("Access-Control-Allow-Methods", methods_str);
        }

        // Access-Control-Allow-Headers
        if (self.config.allowed_headers.len > 0) {
            var headers_list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer headers_list.deinit(self.allocator);
            for (self.config.allowed_headers, 0..) |header, i| {
                if (i > 0) try headers_list.appendSlice(self.allocator, ", ");
                try headers_list.appendSlice(self.allocator, header);
            }
            const headers_str = try headers_list.toOwnedSlice(self.allocator);
            defer self.allocator.free(headers_str);
            _ = try res.header("Access-Control-Allow-Headers", headers_str);
        }

        // Access-Control-Expose-Headers
        if (self.config.exposed_headers.len > 0) {
            var exposed_list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer exposed_list.deinit(self.allocator);

            for (self.config.exposed_headers, 0..) |header, i| {
                if (i > 0) {
                    try exposed_list.appendSlice(self.allocator, ", ");
                }
                try exposed_list.appendSlice(self.allocator, header);
            }
            const exposed_str = try exposed_list.toOwnedSlice(self.allocator);
            defer self.allocator.free(exposed_str);
            _ = try res.header("Access-Control-Expose-Headers", exposed_str);
        }

        // Access-Control-Allow-Credentials
        if (self.config.allow_credentials) {
            _ = try res.header("Access-Control-Allow-Credentials", "true");
        }

        // Access-Control-Max-Age (for preflight)
        if (ctx.method == .OPTIONS) {
            var max_age_buf: [32]u8 = undefined;
            const max_age_str = try std.fmt.bufPrint(&max_age_buf, "{d}", .{self.config.max_age});
            _ = try res.header("Access-Control-Max-Age", max_age_str);
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "CorsConfig defaults" {
    const cfg = CorsConfig{};
    try std.testing.expectEqual(@as(usize, 0), cfg.allowed_origins.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.allowed_methods.len);
    try std.testing.expectEqual(@as(u32, 86400), cfg.max_age);
    try std.testing.expectEqual(false, cfg.allow_credentials);
}
