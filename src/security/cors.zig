//! CORS (Cross-Origin Resource Sharing) 中间件
//!
//! 为 HTTP 服务器添加 CORS 支持，允许或限制跨域请求。
//! 符合 CORS 规范，支持预检请求（OPTIONS）。

const std = @import("std");
const RequestContext = @import("../core/request.zig");
const Response = @import("../core/response.zig");
const Middleware = @import("../core/middleware.zig");

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

    /// 是否阻止未授权来源的请求（true=返回 403，false=仅不添加 CORS 头但仍放行）
    /// 生产环境建议设为 true
    block_unauthorized: bool = false,
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

    /// 处理请求 - 检查 CORS 来源是否允许。
    /// 注意：响应头的添加通过 `addCorsHeaders()` 单独调用，
    /// 因为中间件 VTable 不传递 Response 参数。
    pub fn process(self: *Self, ctx: *RequestContext) !Middleware.NextAction {
        const origin = ctx.getHeader("Origin");

        if (origin == null) {
            return .next;
        }

        if (!self.isOriginAllowed(origin.?)) {
            std.log.warn("CORS: Origin not allowed: {s}", .{origin.?});
            if (self.config.block_unauthorized) {
                ctx.blocked_status = .forbidden;
                return .respond;
            }
            // 非阻塞模式：仅不添加 CORS 头，但仍放行请求
            // 浏览器会因缺少 Access-Control-Allow-Origin 头而阻止前端读取响应
            return .next;
        }

        // 预检请求：标记为 respond（框架在分发前处理）
        if (ctx.method == .OPTIONS and ctx.getHeader("Access-Control-Request-Method") != null) {
            return .respond;
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
            for (self.config.allowed_methods, 0..) |method, i| {
                if (i > 0) try methods_list.appendSlice(self.allocator, ", ");
                try methods_list.appendSlice(self.allocator, @tagName(method));
            }
            const methods_str = try methods_list.toOwnedSlice(self.allocator);
            _ = try res.header("Access-Control-Allow-Methods", methods_str);
        }

        // Access-Control-Allow-Headers
        if (self.config.allowed_headers.len > 0) {
            var headers_list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            for (self.config.allowed_headers, 0..) |header, i| {
                if (i > 0) try headers_list.appendSlice(self.allocator, ", ");
                try headers_list.appendSlice(self.allocator, header);
            }
            const headers_str = try headers_list.toOwnedSlice(self.allocator);
            _ = try res.header("Access-Control-Allow-Headers", headers_str);
        }

        // Access-Control-Expose-Headers
        if (self.config.exposed_headers.len > 0) {
            var exposed_list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            for (self.config.exposed_headers, 0..) |header, i| {
                if (i > 0) {
                    try exposed_list.appendSlice(self.allocator, ", ");
                }
                try exposed_list.appendSlice(self.allocator, header);
            }
            const exposed_str = try exposed_list.toOwnedSlice(self.allocator);
            _ = try res.header("Access-Control-Expose-Headers", exposed_str);
        }

        // Access-Control-Allow-Credentials
        if (self.config.allow_credentials) {
            _ = try res.header("Access-Control-Allow-Credentials", "true");
        }

        // Access-Control-Max-Age (for preflight)
        if (ctx.method == .OPTIONS) {
            const max_age_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.max_age});
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
    try std.testing.expectEqual(@as(u32, 86400), cfg.max_age);
    try std.testing.expectEqual(false, cfg.allow_credentials);
    try std.testing.expectEqual(false, cfg.block_unauthorized);
}

test "CorsMiddleware - create and deinit" {
    const allocator = std.testing.allocator;

    var cors = try CorsMiddleware.init(allocator, .{});
    defer cors.deinit();

    try std.testing.expectEqual(@as(usize, 0), cors.config.allowed_origins.len);
    try std.testing.expectEqual(@as(u32, 86400), cors.config.max_age);
    try std.testing.expectEqual(false, cors.config.allow_credentials);
    try std.testing.expectEqual(false, cors.config.block_unauthorized);
}

test "CorsMiddleware - create with custom config" {
    const allocator = std.testing.allocator;

    const cfg = CorsConfig{
        .allowed_origins = &.{"https://app.example.com"},
        .allowed_methods = &.{ .GET, .POST },
        .allow_credentials = true,
        .max_age = 3600,
        .block_unauthorized = true,
        .exposed_headers = &.{"X-Custom"},
    };
    var cors = try CorsMiddleware.init(allocator, cfg);
    defer cors.deinit();

    try std.testing.expectEqualStrings("https://app.example.com", cors.config.allowed_origins[0]);
    try std.testing.expectEqual(@as(u32, 3600), cors.config.max_age);
    try std.testing.expectEqual(true, cors.config.allow_credentials);
    try std.testing.expectEqual(true, cors.config.block_unauthorized);
    try std.testing.expectEqual(@as(usize, 2), cors.config.allowed_methods.len);
    try std.testing.expectEqualStrings("X-Custom", cors.config.exposed_headers[0]);
}

// ===========================================================================
// 补充测试：全面覆盖 CORS 功能
// ===========================================================================

/// 辅助：在 Response 头部列表中查找指定名称的头
fn findHeader(res: *const Response, name: []const u8) ?[]const u8 {
    for (res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.value;
    }
    return null;
}

/// 辅助结构：持有创建 RequestContext 所需的依赖对象，确保指针在测试期间有效
const TestCtx = struct {
    server: std.http.Server,
    req: std.http.Server.Request,
    ctx: RequestContext,

    fn setup(self: *TestCtx, allocator: std.mem.Allocator, request_bytes: []const u8) !void {
        const head = try std.http.Server.Request.Head.parse(request_bytes);
        self.server = .{
            .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
            .out = undefined,
        };
        self.req = .{
            .server = &self.server,
            .head = head,
            .head_buffer = request_bytes,
        };
        self.ctx = try RequestContext.init(allocator, std.testing.io, &self.req);
    }

    fn deinit(self: *TestCtx) void {
        self.ctx.deinit();
    }
};

// ---- isOriginAllowed 测试 ----

test "isOriginAllowed - 通配符允许所有源" {
    const allocator = std.testing.allocator;
    var cors = try CorsMiddleware.init(allocator, .{ .allowed_origins = &.{"*"} });
    defer cors.deinit();

    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(cors.isOriginAllowed("https://evil.com"));
    try std.testing.expect(cors.isOriginAllowed("http://localhost:3000"));
}

test "isOriginAllowed - 空 allowed_origins 允许所有源" {
    const allocator = std.testing.allocator;
    var cors = try CorsMiddleware.init(allocator, .{});
    defer cors.deinit();

    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(cors.isOriginAllowed("anything"));
}

test "isOriginAllowed - 精确匹配返回 true" {
    const allocator = std.testing.allocator;
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
}

test "isOriginAllowed - 不匹配返回 false" {
    const allocator = std.testing.allocator;
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    try std.testing.expect(!cors.isOriginAllowed("https://other.com"));
    try std.testing.expect(!cors.isOriginAllowed("http://example.com"));
}

test "isOriginAllowed - 多个源中匹配一个" {
    const allocator = std.testing.allocator;
    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{ "https://a.com", "https://b.com", "https://c.com" },
    });
    defer cors.deinit();

    try std.testing.expect(!cors.isOriginAllowed("https://x.com"));
    try std.testing.expect(cors.isOriginAllowed("https://a.com"));
    try std.testing.expect(cors.isOriginAllowed("https://b.com"));
    try std.testing.expect(cors.isOriginAllowed("https://c.com"));
}

// ---- process 测试 ----

test "process - 无 Origin 头返回 next" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}

test "process - Origin 允许返回 next" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}

test "process - Origin 禁止且 block_unauthorized 返回 respond 且 forbidden" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://evil.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .block_unauthorized = true,
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.respond, action);
    try std.testing.expect(tc.ctx.blocked_status == .forbidden);
}

test "process - Origin 禁止但未设置 block 则返回 next" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://evil.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .block_unauthorized = false,
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
    try std.testing.expect(tc.ctx.blocked_status == null);
}

test "process - OPTIONS 预检请求返回 respond" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "OPTIONS /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "Access-Control-Request-Method: POST\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.respond, action);
}

test "process - OPTIONS 但无 Request-Method 头返回 next" {
    const allocator = std.testing.allocator;
    var tc: TestCtx = undefined;
    try tc.setup(allocator, "OPTIONS /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });
    defer cors.deinit();

    const action = try cors.process(&tc.ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);
}

// ---- addCorsHeaders 测试 ----

test "addCorsHeaders - 基本 Allow-Origin 头" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("https://example.com", findHeader(&res, "Access-Control-Allow-Origin").?);
}

test "addCorsHeaders - Allow-Methods 列表正确拼接" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .allowed_methods = &.{ .GET, .POST, .PUT },
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("GET, POST, PUT", findHeader(&res, "Access-Control-Allow-Methods").?);
}

test "addCorsHeaders - Allow-Headers 列表正确拼接" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .allowed_headers = &.{ "Content-Type", "Authorization", "X-Custom" },
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("Content-Type, Authorization, X-Custom", findHeader(&res, "Access-Control-Allow-Headers").?);
}

test "addCorsHeaders - Expose-Headers 列表正确拼接" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .exposed_headers = &.{ "X-Request-Id", "X-Total-Count" },
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("X-Request-Id, X-Total-Count", findHeader(&res, "Access-Control-Expose-Headers").?);
}

test "addCorsHeaders - Allow-Credentials 头" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .allow_credentials = true,
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("true", findHeader(&res, "Access-Control-Allow-Credentials").?);
}

test "addCorsHeaders - Max-Age 头仅在 OPTIONS 时添加" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
        .max_age = 7200,
    });

    // OPTIONS 请求应添加 Max-Age
    var tc_options: TestCtx = undefined;
    try tc_options.setup(testing_alloc, "OPTIONS /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc_options.deinit();

    var res1 = Response.init(testing_alloc, undefined);
    defer res1.deinit();

    try cors.addCorsHeaders(&tc_options.ctx, &res1);
    try std.testing.expectEqualStrings("7200", findHeader(&res1, "Access-Control-Max-Age").?);

    // GET 请求不应添加 Max-Age
    var tc_get: TestCtx = undefined;
    try tc_get.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://example.com\r\n" ++
        "\r\n");
    defer tc_get.deinit();

    var res2 = Response.init(testing_alloc, undefined);
    defer res2.deinit();

    try cors.addCorsHeaders(&tc_get.ctx, &res2);
    try std.testing.expect(findHeader(&res2, "Access-Control-Max-Age") == null);
}

test "addCorsHeaders - 无 Origin 头不添加任何 CORS 头" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
}

test "addCorsHeaders - Origin 不在列表中不添加头" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://evil.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{
        .allowed_origins = &.{"https://example.com"},
    });

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
}

test "addCorsHeaders - 空 allowed_origins 使用通配符" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tc: TestCtx = undefined;
    try tc.setup(testing_alloc, "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Origin: https://any-origin.com\r\n" ++
        "\r\n");
    defer tc.deinit();

    var cors = try CorsMiddleware.init(allocator, .{});

    var res = Response.init(testing_alloc, undefined);
    defer res.deinit();

    try cors.addCorsHeaders(&tc.ctx, &res);
    try std.testing.expectEqualStrings("*", findHeader(&res, "Access-Control-Allow-Origin").?);
}
