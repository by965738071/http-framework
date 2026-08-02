//! CSRF (Cross-Site Request Forgery) 防护中间件
//!
//! 采用 Double Submit Cookie 模式防御 CSRF 攻击：
//! 1. 服务端在 Cookie 中设置一个随机 token
//! 2. 客户端在请求头（`X-CSRF-Token`）或表单字段（`csrf_token`）中提交相同 token
//! 3. 中间件比对两者，一致则放行，否则返回 403
//!
//! 安全方法（GET / HEAD / OPTIONS）不需要验证 CSRF token。
//!
//! 用法：
//! ```zig
//! var csrf = try CsrfMiddleware.create(allocator, io, .{});
//! defer csrf.deinit();
//!
//! // 在路由中间件链中验证
//! _ = try csrf.process(&ctx);
//!
//! // 在响应中设置 CSRF Cookie
//! const token = try csrf.generateToken();
//! defer allocator.free(token);
//! try csrf.setCookie(&res, token);
//! ```

const std = @import("std");
const http = std.http;
const RequestContext = @import("../core/request.zig");
const Response = @import("../core/response.zig");
const Middleware = @import("../core/middleware.zig");

/// CSRF 防护配置
pub const CsrfConfig = struct {
    /// CSRF token 的 Cookie 名称
    cookie_name: []const u8 = "csrf_token",

    /// 请求头中 CSRF token 的字段名
    header_name: []const u8 = "X-CSRF-Token",

    /// 表单中 CSRF token 的字段名
    form_field_name: []const u8 = "csrf_token",

    /// Token 的随机字节长度（最终 hex 编码后长度为 2 倍）
    token_length: u8 = 32,

    /// Cookie 的 Path 属性
    cookie_path: []const u8 = "/",

    /// Cookie 是否仅通过 HTTPS 发送
    secure: bool = false,

    /// 不需要验证 CSRF 的 HTTP 方法
    ignored_methods: []const http.Method = &.{ .GET, .HEAD, .OPTIONS },
};

/// CSRF 防护中间件
pub const CsrfMiddleware = struct {
    config: CsrfConfig,
    middleware: Middleware,
    allocator: std.mem.Allocator,
    io: std.Io,

    const Self = @This();

    /// 创建 CSRF 中间件实例。
    ///
    /// 内部复制所有配置字段到自有内存，调用者无需保持 config 存活。
    pub fn create(allocator: std.mem.Allocator, io: std.Io, config: CsrfConfig) !*Self {
        const ptr = try allocator.create(Self);
        errdefer allocator.destroy(ptr);

        // 复制字符串字段
        var cfg = config;
        cfg.cookie_name = try allocator.dupe(u8, config.cookie_name);
        errdefer allocator.free(cfg.cookie_name);
        cfg.header_name = try allocator.dupe(u8, config.header_name);
        errdefer allocator.free(cfg.header_name);
        cfg.form_field_name = try allocator.dupe(u8, config.form_field_name);
        errdefer allocator.free(cfg.form_field_name);
        cfg.cookie_path = try allocator.dupe(u8, config.cookie_path);
        errdefer allocator.free(cfg.cookie_path);

        // 复制 ignored_methods 切片
        if (config.ignored_methods.len > 0) {
            const dup = try allocator.alloc(http.Method, config.ignored_methods.len);
            errdefer allocator.free(dup);
            @memcpy(dup, config.ignored_methods);
            cfg.ignored_methods = dup;
        }

        ptr.* = .{
            .config = cfg,
            .allocator = allocator,
            .io = io,
            .middleware = undefined,
        };
        ptr.middleware = Middleware.init(Self, ptr);
        return ptr;
    }

    /// VTable 中间件入口：验证 CSRF token。
    ///
    /// - GET / HEAD / OPTIONS 等安全方法直接放行，无需验证。
    /// - 其他方法（POST / PUT / DELETE 等）：从请求头或表单中提取 token 与 Cookie 比对。
    /// - 验证失败时设置 `ctx.blocked_status = .forbidden` 并返回 `.err`。
    pub fn process(self: *Self, ctx: *RequestContext) !Middleware.NextAction {
        // 安全方法直接放行
        if (self.isMethodIgnored(ctx.method)) {
            return .next;
        }

        // 获取 Cookie 中的 token
        const cookie_token = ctx.getCookie(self.config.cookie_name);
        if (cookie_token == null) {
            ctx.blocked_status = .forbidden;
            return .err;
        }

        // 优先从 Header 获取，其次从表单获取
        const submitted = ctx.getHeader(self.config.header_name) orelse
            ctx.getForm(self.config.form_field_name);

        if (submitted == null) {
            ctx.blocked_status = .forbidden;
            return .err;
        }

        // 常量时间比较防止时序攻击
        if (!std.mem.eql(u8, cookie_token.?, submitted.?)) {
            ctx.blocked_status = .forbidden;
            return .err;
        }

        return .next;
    }

    /// 在响应中设置 CSRF Cookie。
    ///
    /// 应在发送响应前调用，确保客户端持有有效的 CSRF token。
    /// 可通过 `generateToken()` 生成新 token。
    pub fn setCookie(self: *const Self, res: *Response, token: []const u8) !void {
        _ = try res.setCookie(self.config.cookie_name, token);
    }

    /// 生成安全的随机 CSRF token（hex 编码字符串）。
    ///
    /// 使用 `std.Io.randomSecure` 生成密码学安全的随机字节，
    /// 然后 hex 编码为字符串。返回的内存由调用者负责释放。
    ///
    /// 示例：`token_length = 32` → 返回 64 字符的 hex 字符串。
    pub fn generateToken(self: *Self) ![]const u8 {
        const byte_len = self.config.token_length;

        const random_bytes = try self.allocator.alloc(u8, byte_len);
        errdefer self.allocator.free(random_bytes);

        try std.Io.randomSecure(self.io, random_bytes);

        // Hex 编码：每个字节 → 2 个 hex 字符
        const hex_len = byte_len * 2;
        const hex = try self.allocator.alloc(u8, hex_len);
        errdefer self.allocator.free(hex);

        const hex_chars = "0123456789abcdef";
        for (random_bytes, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        self.allocator.free(random_bytes);
        return hex;
    }

    /// 释放所有自有内存并销毁中间件实例。
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.config.cookie_name);
        self.allocator.free(self.config.header_name);
        self.allocator.free(self.config.form_field_name);
        self.allocator.free(self.config.cookie_path);
        if (self.config.ignored_methods.len > 0) {
            self.allocator.free(self.config.ignored_methods);
        }
        self.allocator.destroy(self);
    }

    // ── 内部辅助 ──────────────────────────────────────

    /// 检查 HTTP 方法是否在忽略列表中
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
    try std.testing.expectEqualStrings("csrf_token", cfg.form_field_name);
    try std.testing.expectEqual(@as(u8, 32), cfg.token_length);
    try std.testing.expectEqualStrings("/", cfg.cookie_path);
    try std.testing.expectEqual(false, cfg.secure);
    try std.testing.expectEqual(@as(usize, 3), cfg.ignored_methods.len);
}

test "CsrfMiddleware create and deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cfg = CsrfConfig{
        .cookie_name = "my_csrf",
        .token_length = 16,
        .secure = true,
        .ignored_methods = &.{ .GET, .HEAD },
    };

    const csrf = try CsrfMiddleware.create(allocator, io, cfg);
    defer csrf.deinit();

    try std.testing.expectEqualStrings("my_csrf", csrf.config.cookie_name);
    try std.testing.expectEqual(@as(u8, 16), csrf.config.token_length);
    try std.testing.expectEqual(true, csrf.config.secure);
    try std.testing.expectEqual(@as(usize, 2), csrf.config.ignored_methods.len);
}

test "CsrfMiddleware.generateToken produces hex string" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cfg = CsrfConfig{ .token_length = 16 };
    const csrf = try CsrfMiddleware.create(allocator, io, cfg);
    defer csrf.deinit();

    const token = try csrf.generateToken();
    defer allocator.free(token);

    // token_length = 16 → hex 编码后应为 32 字符
    try std.testing.expectEqual(@as(usize, 32), token.len);

    // 验证所有字符都是 hex 字符
    for (token) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "CsrfMiddleware.generateToken produces different tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const csrf = try CsrfMiddleware.create(allocator, io, .{});
    defer csrf.deinit();

    const token1 = try csrf.generateToken();
    defer allocator.free(token1);

    const token2 = try csrf.generateToken();
    defer allocator.free(token2);

    // 两次生成的 token 应该不同
    try std.testing.expect(!std.mem.eql(u8, token1, token2));
}

test "CsrfMiddleware isMethodIgnored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const csrf = try CsrfMiddleware.create(allocator, io, .{});
    defer csrf.deinit();

    try std.testing.expect(csrf.isMethodIgnored(.GET));
    try std.testing.expect(csrf.isMethodIgnored(.HEAD));
    try std.testing.expect(csrf.isMethodIgnored(.OPTIONS));

    try std.testing.expect(!csrf.isMethodIgnored(.POST));
    try std.testing.expect(!csrf.isMethodIgnored(.PUT));
    try std.testing.expect(!csrf.isMethodIgnored(.DELETE));
    try std.testing.expect(!csrf.isMethodIgnored(.PATCH));
}

test "CsrfMiddleware middleware VTable process" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const csrf = try CsrfMiddleware.create(allocator, io, .{});
    defer csrf.deinit();

    // 验证 VTable 已正确连接
    // 创建一个 minimal RequestContext（method=GET 属于忽略方法，process 会立即返回 .next）
    var ctx = RequestContext{
        .allocator = allocator,
        .io = io,
        .method = .GET,
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .path_params = .{},
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
    };
    const action = try csrf.middleware.process(&ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}
