//! HTTP 路由引擎
//!
//! 支持静态路径和动态路径参数（`:param` 语法），
//! 以及中间件链、404/错误处理器。

const std = @import("std");
const mem = std.mem;
const http = std.http;

const RequestContext = @import("request.zig");
const freeHashMap = RequestContext.freeHashMap;
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");
const Handler = @import("handler.zig");
const RotatingFileLogger = @import("logger.zig").RotatingFileLogger;

/// 单条路由记录
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
    param_validator: ?*const fn (ctx: *RequestContext) bool = null,
};

/// 路由分发结果
pub const DispatchResult = enum {
    handled,
    not_found,
    method_not_allowed,
    middleware_blocked,
};

const Self = @This();
pub const Router = Self;

const MAX_PATH_PARAMS = 32;

allocator: std.mem.Allocator,
routes: std.ArrayList(Route),
not_found_handler: ?Handler = null,
error_handler: ?*const fn (anyerror, *RequestContext, *Response) anyerror!void = null,

/// 文件日志器（由 Server 注入）
file_logger: ?*RotatingFileLogger = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .routes = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.routes.items) |r| {
        self.allocator.free(r.pattern);
    }
    self.routes.deinit(self.allocator);
}

/// 设置文件日志器（由 Server.init 调用）
pub fn setLogger(self: *Self, logger: *RotatingFileLogger) void {
    self.file_logger = logger;
}

/// 注册一条路由
pub fn route(self: *Self, method: http.Method, pattern: []const u8, handler: Handler) !void {
    const owned_pattern = try self.allocator.dupe(u8, pattern);
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = owned_pattern,
        .handler = handler,
    });
}

/// 注册一条带中间件的路由
pub fn routeWithMiddleware(
    self: *Self,
    method: http.Method,
    pattern: []const u8,
    handle: Handler,
    middle: []const Middleware,
) !void {
    const owned_pattern = try self.allocator.dupe(u8, pattern);
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = owned_pattern,
        .handler = handle,
        .middlewares = middle,
    });
}

pub fn notFound(self: *Self, handler: Handler) void {
    self.not_found_handler = handler;
}

pub fn onError(
    self: *Self,
    handler: *const fn (anyerror, *RequestContext, *Response) anyerror!void,
) void {
    self.error_handler = handler;
}

// =========================================================================
// 路由分组
// =========================================================================

/// 路由组 — 共享前缀和中间件的一组路由。
///
/// 使用方式：
/// ```zig
/// var api = router.group("/api/v1", &.{auth_middleware});
/// try api.route(.GET, "/users", users_handler);
/// try api.route(.POST, "/users", create_user_handler);
/// ```
pub const RouteGroup = struct {
    prefix: []const u8,
    shared_middlewares: []const Middleware,
    router: *Self,

    /// 注册路由（自动拼接 prefix + pattern，合并共享中间件）
    pub fn route(self: *const RouteGroup, method: http.Method, pattern: []const u8, handler: Handler) !void {
        const full_pattern = try concatPath(self.router.allocator, self.prefix, pattern);
        defer self.router.allocator.free(full_pattern);

        if (self.shared_middlewares.len > 0) {
            try self.router.routeWithMiddleware(method, full_pattern, handler, self.shared_middlewares);
        } else {
            try self.router.route(method, full_pattern, handler);
        }
    }

    /// 注册带额外中间件的路由（合并组的共享中间件 + 路由自己的中间件）
    pub fn routeWithMiddleware(
        self: *const RouteGroup,
        method: http.Method,
        pattern: []const u8,
        handler: Handler,
        extra_middlewares: []const Middleware,
    ) !void {
        const full_pattern = try concatPath(self.router.allocator, self.prefix, pattern);
        defer self.router.allocator.free(full_pattern);

        // 合并共享中间件和额外中间件
        const total_len = self.shared_middlewares.len + extra_middlewares.len;
        const merged = try self.router.allocator.alloc(Middleware, total_len);
        defer self.router.allocator.free(merged);

        @memcpy(merged[0..self.shared_middlewares.len], self.shared_middlewares);
        @memcpy(merged[self.shared_middlewares.len..], extra_middlewares);

        try self.router.routeWithMiddleware(method, full_pattern, handler, merged);
    }

    /// 设置组的 404 处理器（注意：这会覆盖 Router 级别的 404）
    pub fn notFound(self: *const RouteGroup, handler: Handler) void {
        self.router.notFound(handler);
    }
};

/// 创建一个路由组。
///
/// `prefix` — 该组所有路由的公共前缀（如 "/api/v1"）
/// `shared_middlewares` — 该组所有路由共享的中间件
///
/// 返回的 `RouteGroup` 生命周期由调用者管理（栈分配即可）。
pub fn group(self: *Self, prefix: []const u8, shared_middlewares: []const Middleware) RouteGroup {
    return .{
        .prefix = prefix,
        .shared_middlewares = shared_middlewares,
        .router = self,
    };
}

/// 拼接路径前缀和路由模式（处理前后斜杠）
fn concatPath(allocator: std.mem.Allocator, prefix: []const u8, pattern: []const u8) ![]const u8 {
    const p = trimSlash(prefix);
    const r = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;

    if (p.len == 0) return allocator.dupe(u8, r);
    if (r.len == 0) return allocator.dupe(u8, p);

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ p, r });
}

/// 分发请求到匹配的路由。
/// 返回 `true` 表示已处理，`false` 表示无匹配。
pub fn dispatch(self: *const Self, ctx: *RequestContext, res: *Response) !bool {
    var method_matched = false;

    for (self.routes.items) |r| {
        const clean_pattern = trimSlash(r.pattern);
        const clean_path = trimSlash(ctx.path);

        if (!matchPattern(clean_pattern, clean_path, self.allocator, ctx)) continue;

        // 记录路由匹配
        routeLog(self.file_logger, "[ROUTE] matched: {s} {s} -> {s}", .{
            @tagName(ctx.method),
            ctx.path,
            r.pattern,
        });

        if (r.param_validator) |validator| {
            if (!validator(ctx)) {
                freeHashMap(&ctx.path_params, self.allocator);
                ctx.path_params = std.StringHashMapUnmanaged([]const u8).empty;
                continue;
            }
        }

        if (r.method != ctx.method) {
            method_matched = true;
            freeHashMap(&ctx.path_params, self.allocator);
            ctx.path_params = std.StringHashMapUnmanaged([]const u8).empty;
            continue;
        }

        // 执行中间件链
        if (r.middlewares.len > 0) {
            routeLog(self.file_logger, "[MIDDLEWARE] {d} middlewares for {s} {s}", .{
                r.middlewares.len,
                @tagName(ctx.method),
                ctx.path,
            });
            var blocked = false;
            for (r.middlewares) |middle| {
                const action = try middle.vtable.process(middle.ptr, ctx);
                switch (action) {
                    .next => {},
                    .respond => {
                        routeLog(self.file_logger, "[MIDDLEWARE] blocked at '{s}'", .{middle.name});
                        if (ctx.blocked_status) |status| {
                            _ = res.statusCode(status);
                        }
                        blocked = true;
                        break;
                    },
                    .err => return true,
                }
            }
            if (blocked) return true;
        }

        // 执行 Handler
        routeLog(self.file_logger, "[HANDLER] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });
        const handler_instance = try r.handler.vtable.create(r.handler.ptr);
        defer r.handler.vtable.destroy(r.handler.ptr, handler_instance);
        try r.handler.vtable.handle(handler_instance, ctx, res);
        return true;
    }

    // 方法不匹配但模式匹配
    if (method_matched) {
        routeLog(self.file_logger, "[405] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });
        _ = res.statusCode(.method_not_allowed);
        return true;
    }

    // 404
    routeLog(self.file_logger, "[404] {s} {s}", .{
        @tagName(ctx.method),
        ctx.path,
    });
    if (self.not_found_handler) |nf| {
        const instance = try nf.vtable.create(nf.ptr);
        defer nf.vtable.destroy(nf.ptr, instance);
        try nf.vtable.handle(instance, ctx, res);
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// 路径模式匹配
// ---------------------------------------------------------------------------

fn matchPattern(
    pattern: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    ctx: *RequestContext,
) bool {
    if (pattern.len == 0 and path.len == 0) return true;

    // Strip leading/trailing slashes for consistent matching
    const clean_pattern = trimSlash(pattern);
    const clean_path = trimSlash(path);

    if (mem.endsWith(u8, clean_pattern, "*")) {
        const prefix = clean_pattern[0 .. clean_pattern.len - 1];
        const clean_prefix = trimSlash(prefix);

        if (mem.startsWith(u8, clean_path, clean_prefix)) {
            var remaining = clean_path[clean_prefix.len..];
            // Strip leading slash from remaining path for consistency
            if (remaining.len > 0 and remaining[0] == '/') {
                remaining = remaining[1..];
            }
            const key_dup = allocator.dupe(u8, "*") catch return false;
            const val_dup = allocator.dupe(u8, remaining) catch {
                allocator.free(key_dup);
                return false;
            };
            ctx.path_params.put(allocator, key_dup, val_dup) catch {
                allocator.free(key_dup);
                allocator.free(val_dup);
                return false;
            };
            return true;
        }
        return false;
    }

    var p_parts = mem.splitScalar(u8, clean_pattern, '/');
    var path_parts = mem.splitScalar(u8, clean_path, '/');

    var params_buf: [MAX_PATH_PARAMS]struct { key: []const u8, value: []const u8 } = undefined;
    var params_len: usize = 0;

    while (p_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return false;
        if (p_part.len == 0 and path_part.len == 0) continue;

        if (p_part.len > 0 and p_part[0] == ':') {
            if (params_len >= MAX_PATH_PARAMS) return false;
            params_buf[params_len] = .{
                .key = p_part[1..],
                .value = path_part,
            };
            params_len += 1;
        } else if (!mem.eql(u8, p_part, path_part)) {
            return false;
        }
    }

    if (path_parts.next() != null) return false;

    for (params_buf[0..params_len]) |param| {
        const key_dup = allocator.dupe(u8, param.key) catch return false;
        const val_dup = allocator.dupe(u8, param.value) catch {
            allocator.free(key_dup);
            return false;
        };
        ctx.path_params.put(allocator, key_dup, val_dup) catch {
            allocator.free(key_dup);
            allocator.free(val_dup);
            return false;
        };
    }

    return true;
}

fn trimSlash(path: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = path.len;

    if (end > 0 and path[0] == '/') start = 1;
    if (end > start and path[end - 1] == '/') end -= 1;

    return path[start..end];
}

// ---------------------------------------------------------------------------
// 日志辅助
// ---------------------------------------------------------------------------

fn routeLog(file_logger: ?*RotatingFileLogger, comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
    if (file_logger) |logger| {
        logger.debug(fmt, args) catch {};
    }
}

// =========================================================================
// 测试
// =========================================================================

test "trimSlash" {
    try std.testing.expectEqualStrings("", trimSlash(""));
    try std.testing.expectEqualStrings("", trimSlash("/"));
    try std.testing.expectEqualStrings("foo", trimSlash("/foo/"));
    try std.testing.expectEqualStrings("foo/bar", trimSlash("/foo/bar"));
    try std.testing.expectEqualStrings("foo/bar", trimSlash("foo/bar/"));
}

test "matchPattern - static path" {
    const allocator = std.testing.allocator;
    var ctx = RequestContext{
        .allocator = undefined,
        .io = undefined,
        .method = .GET,
        .path = "/users",
        .query = "",
        .version = .@"HTTP/1.1",
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
    defer {
        freeHashMap(&ctx.path_params, allocator);
    }

    try std.testing.expect(matchPattern("users", "/users", allocator, &ctx));
    try std.testing.expect(!matchPattern("users", "/posts", allocator, &ctx));
    try std.testing.expect(!matchPattern("users/123", "/users", allocator, &ctx));
}

test "matchPattern - path params" {
    const allocator = std.testing.allocator;
    var ctx = RequestContext{
        .allocator = undefined,
        .io = undefined,
        .method = .GET,
        .path = "/users/42",
        .query = "",
        .version = .@"HTTP/1.1",
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
    defer {
        freeHashMap(&ctx.path_params, allocator);
    }

    try std.testing.expect(matchPattern("users/:id", "/users/42", allocator, &ctx));
    try std.testing.expectEqualStrings("42", ctx.path_params.get("id").?);
}

test "matchPattern - wildcard" {
    const allocator = std.testing.allocator;
    var ctx = RequestContext{
        .allocator = undefined,
        .io = undefined,
        .method = .GET,
        .path = "/static/js/app.js",
        .query = "",
        .version = .@"HTTP/1.1",
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
    defer {
        freeHashMap(&ctx.path_params, allocator);
    }

    try std.testing.expect(matchPattern("static/*", "/static/js/app.js", allocator, &ctx));
    try std.testing.expectEqualStrings("js/app.js", ctx.path_params.get("*").?);
}

test "RouteGroup - basic routing with prefix" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const fn_handler = Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            _ = res;
        }
    }.handler);

    var api = router.group("api/v1", &.{});
    try api.route(.GET, "/users", fn_handler);

    // 验证路由已注册且 pattern 正确拼接
    try std.testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try std.testing.expectEqualStrings("api/v1/users", router.routes.items[0].pattern);
}

test "RouteGroup - prefix trimming handles slashes" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const fn_handler = Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            _ = res;
        }
    }.handler);

    // 前缀有尾部斜杠，pattern 有前导斜杠 → 应该正确拼接
    var api = router.group("/api/v1/", &.{});
    try api.route(.GET, "/users", fn_handler);

    try std.testing.expectEqualStrings("api/v1/users", router.routes.items[0].pattern);
}

test "RouteGroup - shared middlewares are attached" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const fn_handler = Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            _ = res;
        }
    }.handler);

    // 创建一个简单的中间件
    const MwType = struct {
        pub fn process(self: *@This(), req_ctx: *RequestContext) !Middleware.NextAction {
            _ = self;
            _ = req_ctx;
            return .next;
        }
    };
    var mw_instance = MwType{};
    const mw = Middleware.init(MwType, &mw_instance);

    var api = router.group("/admin", &.{mw});
    try api.route(.GET, "/dashboard", fn_handler);

    try std.testing.expectEqual(@as(usize, 1), router.routes.items[0].middlewares.len);
}

test "matchPattern - trailing slash" {
    const allocator = std.testing.allocator;
    var ctx = RequestContext{
        .allocator = undefined,
        .io = undefined,
        .method = .GET,
        .path = "/users/",
        .query = "",
        .version = .@"HTTP/1.1",
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .request = undefined,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
    defer {
        freeHashMap(&ctx.path_params, allocator);
    }

    try std.testing.expect(matchPattern("users", "/users/", allocator, &ctx));
    try std.testing.expect(!matchPattern("users/posts", "/users/", allocator, &ctx));
}
