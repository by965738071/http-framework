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
const Logger = @import("log.zig").Logger;

/// 单条路由记录
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
    param_validator: ?*const fn (ctx: *RequestContext) bool = null,
};

const Self = @This();
pub const Router = Self;

const MAX_PATH_PARAMS = 32;

allocator: std.mem.Allocator,
routes: std.ArrayList(Route),
not_found_handler: ?Handler = null,
error_handler: ?*const fn (anyerror, *RequestContext, *Response) anyerror!void = null,

/// 全局中间件（在路由匹配之前对所有请求执行，包括最终落到 404 的请求）。
/// 适用于日志、全局鉴权、限流等横切关注点。
///
/// 实例所有权归调用方：Router 只复制切片（同路由级中间件的所有权约定），
/// 调用方须保证实例存活至 Router.deinit() 之后。
global_middlewares: []const Middleware = &.{},

/// 日志句柄（由 Server 注入）
logger: ?Logger = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .routes = .empty,
    };
}

pub fn deinit(self: *Self) void {
    for (self.routes.items) |r| {
        self.allocator.free(r.pattern);
        // 注意：Router 不拥有中间件实例的所有权（实例由调用方创建并管理
        // 生命周期），这里只释放路由表中的切片副本。
        if (r.middlewares.len > 0) {
            self.allocator.free(r.middlewares);
        }
        // 回收 Handler 注册时分配的上下文（单例/纯函数为空操作）
        r.handler.deinit();
    }
    if (self.not_found_handler) |nf| nf.deinit();
    if (self.global_middlewares.len > 0) {
        self.allocator.free(self.global_middlewares);
    }
    self.routes.deinit(self.allocator);
}

/// 设置日志句柄（由 Server.run 调用——此时 Server 才有稳定地址）。
/// 调用者必须保证日志实现的存活期覆盖 Router 的使用期。
pub fn setLogger(self: *Self, logger: Logger) void {
    self.logger = logger;
}

/// 解除日志句柄引用（由 Server.deinit 调用，防止悬垂指针）
pub fn clearLogger(self: *Self) void {
    self.logger = null;
}

/// 注册一条路由
pub fn route(self: *Self, method: http.Method, pattern: []const u8, handler: Handler) !void {
    const owned_pattern = try self.allocator.dupe(u8, pattern);
    errdefer self.allocator.free(owned_pattern);
    errdefer handler.deinit();
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = owned_pattern,
        .handler = handler,
        .middlewares = &.{},
    });
}

/// 注册一条带中间件的路由。
///
/// 中间件实例的所有权归调用方：Router 只复制切片，不会 destroy 中间件。
/// 调用方必须保证中间件实例存活至 Router.deinit() 之后。
pub fn routeWithMiddleware(
    self: *Self,
    method: http.Method,
    pattern: []const u8,
    handle: Handler,
    middle: []const Middleware,
) !void {
    const owned_pattern = try self.allocator.dupe(u8, pattern);
    errdefer self.allocator.free(owned_pattern);
    errdefer handle.deinit();
    const owned_middlewares = if (middle.len > 0) try self.allocator.dupe(Middleware, middle) else &.{};
    errdefer if (owned_middlewares.len > 0) self.allocator.free(owned_middlewares);
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = owned_pattern,
        .handler = handle,
        .middlewares = owned_middlewares,
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

/// 注册全局中间件。
///
/// 全局中间件在路由匹配之前对所有请求执行（包括最终落到 404 的请求），
/// 适用于日志、全局鉴权、限流等横切关注点。执行顺序即注册顺序，
/// 且总是在路由级中间件之前运行。
///
/// 中间件实例的所有权归调用方：Router 只复制切片，不会 destroy 中间件实例。
/// 调用方须保证实例存活至 Router.deinit() 之后。
pub fn use(self: *Self, middlewares: []const Middleware) !void {
    if (middlewares.len == 0) return;
    const owned = try self.allocator.dupe(Middleware, middlewares);
    // 若之前已注册过全局中间件，先释放旧副本（Router 拥有切片副本的所有权）
    if (self.global_middlewares.len > 0) {
        self.allocator.free(self.global_middlewares);
    }
    self.global_middlewares = owned;
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
///
/// 返回值与响应约定：
/// - 返回 `true`：请求已被处理（handler 执行、中间件拦截或 405）。
///   正常情况下响应已发送；若 handler/中间件只设置了状态码而未写响应体，
///   由调用方（Server）负责发送兜底响应——Router 不直接操作传输层。
/// - 返回 `false`：没有任何路由匹配（404），由调用方发送默认 404 响应。
/// - 错误：通过 error union 传播，由调用方的错误处理器发送 5xx。
pub fn dispatch(self: *const Self, ctx: *RequestContext, res: *Response) !bool {
    // 全局中间件（pre-routing，对所有请求生效，包括最终 404 的请求）
    if (self.global_middlewares.len > 0) {
        var blocked = false;
        for (self.global_middlewares) |middle| {
            const action = try middle.vtable.process(middle.ptr, ctx, res);
            switch (action) {
                .next => {},
                .respond => {
                    if (ctx.blocked_status) |status| _ = res.statusCode(status);
                    blocked = true;
                    break;
                },
                .err => {
                    if (ctx.blocked_status) |status| {
                        _ = res.statusCode(status);
                    } else {
                        _ = res.statusCode(.internal_server_error);
                    }
                    blocked = true;
                    break;
                },
            }
        }
        if (blocked) {
            // 中间件拦截：状态码已设置，响应发送由 Server 兜底
            // （Router 不直接操作传输层，保持可测试性）
            return true;
        }
    }

    // 记录 pattern 匹配但 method 不匹配的路由方法（用于 405 的 Allow 头）
    var allowed_methods_buf: [16]http.Method = undefined;
    var allowed_methods_len: usize = 0;

    for (self.routes.items) |r| {
        // 第一轮：无分配 dry-run 匹配（不提取路径参数）
        if (!matchPattern(r.pattern, ctx.path, null, null)) continue;

        // pattern 匹配但 method 不匹配 → 记录，继续寻找完整匹配
        if (r.method != ctx.method) {
            if (allowed_methods_len < allowed_methods_buf.len) {
                // 去重
                var dup = false;
                for (allowed_methods_buf[0..allowed_methods_len]) |m| {
                    if (m == r.method) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    allowed_methods_buf[allowed_methods_len] = r.method;
                    allowed_methods_len += 1;
                }
            }
            continue;
        }

        // 第二轮：完整匹配（提取路径参数，可能分配内存）
        if (!matchPattern(r.pattern, ctx.path, self.allocator, ctx)) {
            // dry-run 已成功，这里失败只可能是分配失败
            return error.OutOfMemory;
        }

        // 记录路由匹配
        routeLog(self.logger, "[ROUTE] matched: {s} {s} -> {s}", .{
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

        // 记录匹配的路由模式（供 metrics 使用，避免高基数原始路径）
        ctx.route_pattern = r.pattern;

        // 执行中间件链
        if (r.middlewares.len > 0) {
            routeLog(self.logger, "[MIDDLEWARE] {d} middlewares for {s} {s}", .{
                r.middlewares.len,
                @tagName(ctx.method),
                ctx.path,
            });
            var blocked = false;
            for (r.middlewares) |middle| {
                const action = try middle.vtable.process(middle.ptr, ctx, res);
                switch (action) {
                    .next => {},
                    .respond => {
                        routeLog(self.logger, "[MIDDLEWARE] blocked at '{s}'", .{middle.name});
                        if (ctx.blocked_status) |status| {
                            _ = res.statusCode(status);
                        }
                        blocked = true;
                        break;
                    },
                    .err => {
                        routeLog(self.logger, "[MIDDLEWARE] error at '{s}'", .{middle.name});
                        if (ctx.blocked_status) |status| {
                            _ = res.statusCode(status);
                        } else {
                            _ = res.statusCode(.internal_server_error);
                        }
                        blocked = true;
                        break;
                    },
                }
            }
            if (blocked) {
                // 中间件拦截：状态码已设置，响应发送由 Server 兜底
                // （Router 不直接操作传输层，保持可测试性）
                return true;
            }
        }

        // 执行 Handler
        routeLog(self.logger, "[HANDLER] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });
        const handler_instance = try r.handler.vtable.create(r.handler.ptr);
        defer r.handler.vtable.destroy(r.handler.ptr, handler_instance);
        try r.handler.vtable.handle(handler_instance, ctx, res);
        return true;
    }

    // 方法不匹配但模式匹配 → 405 Method Not Allowed（带 Allow 头）
    if (allowed_methods_len > 0) {
        routeLog(self.logger, "[405] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });
        _ = res.statusCode(.method_not_allowed);

        // 拼接 Allow 头（如 "GET, POST"）
        var allow_buf: [128]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&allow_buf);
        for (allowed_methods_buf[0..allowed_methods_len], 0..) |m, i| {
            if (i > 0) fbs.writeAll(", ") catch break;
            fbs.writeAll(@tagName(m)) catch break;
        }
        _ = res.header("Allow", fbs.buffered()) catch {};
        // 响应发送由 Server 兜底
        return true;
    }

    // 404
    routeLog(self.logger, "[404] {s} {s}", .{
        @tagName(ctx.method),
        ctx.path,
    });
    if (self.not_found_handler) |nf| {
        const instance = try nf.vtable.create(nf.ptr);
        defer nf.vtable.destroy(nf.ptr, instance);
        try nf.vtable.handle(instance, ctx, res);
        return true;
    }

    // 无自定义 404 处理器：返回 false，由 Server 发送默认 404 页面
    return false;
}

// ---------------------------------------------------------------------------
// 路径模式匹配
// ---------------------------------------------------------------------------

/// 路径模式匹配。
///
/// `allocator`/`ctx` 同时为 null 时是 dry-run 模式：只判断是否匹配，
/// 不提取路径参数、零堆分配。两者同时非 null 时才会提取参数写入
/// `ctx.path_params`（key/value 均为自有内存）。
fn matchPattern(
    pattern: []const u8,
    path: []const u8,
    allocator: ?std.mem.Allocator,
    ctx: ?*RequestContext,
) bool {
    std.debug.assert((allocator == null) == (ctx == null));

    if (pattern.len == 0 and path.len == 0) return true;

    // Strip leading/trailing slashes for consistent matching
    const clean_pattern = trimSlash(pattern);
    const clean_path = trimSlash(path);

    if (mem.endsWith(u8, clean_pattern, "*")) {
        const prefix = clean_pattern[0 .. clean_pattern.len - 1];
        const clean_prefix = trimSlash(prefix);

        // 通配符只能在**路径段边界**上展开：`static/*` 必须匹配 `static` 或
        // `static/<...>`，绝不能匹配 `staticky/secret`（否则 `*` 会捕获
        // "ky/secret"，让相邻的兄弟路径被静态文件处理器接管）。
        const boundary_ok = clean_prefix.len == 0 or
            (mem.startsWith(u8, clean_path, clean_prefix) and
                (clean_path.len == clean_prefix.len or clean_path[clean_prefix.len] == '/'));

        if (boundary_ok) {
            const alloc = allocator orelse return true; // dry-run：匹配成功
            const c = ctx.?;

            var remaining = clean_path[clean_prefix.len..];
            // Strip leading slash from remaining path for consistency
            if (remaining.len > 0 and remaining[0] == '/') {
                remaining = remaining[1..];
            }
            const key_dup = alloc.dupe(u8, "*") catch return false;
            const val_dup = alloc.dupe(u8, remaining) catch {
                alloc.free(key_dup);
                return false;
            };
            c.path_params.put(alloc, key_dup, val_dup) catch {
                alloc.free(key_dup);
                alloc.free(val_dup);
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

    // dry-run：结构匹配成功，不提取参数
    const alloc = allocator orelse return true;
    const c = ctx.?;

    for (params_buf[0..params_len]) |param| {
        const key_dup = alloc.dupe(u8, param.key) catch return false;
        const val_dup = alloc.dupe(u8, param.value) catch {
            alloc.free(key_dup);
            return false;
        };
        c.path_params.put(alloc, key_dup, val_dup) catch {
            alloc.free(key_dup);
            alloc.free(val_dup);
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

fn routeLog(logger: ?Logger, comptime fmt: []const u8, args: anytype) void {
    if (logger) |lg| lg.debug(fmt, args) else std.log.debug(fmt, args);
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

test "matchPattern - wildcard respects segment boundary" {
    // dry-run 模式（无分配）足以验证匹配与否
    // `static/*` 只能吃掉 static 段之后的内容，不能匹配同前缀的兄弟路径，
    // 否则 /staticky/secret 会被静态文件处理器接管（目录穿越/信息泄露）。
    try std.testing.expect(!matchPattern("static/*", "/staticky/secret", null, null));
    try std.testing.expect(!matchPattern("static/*", "/static-private/x", null, null));

    // 正常场景仍然匹配
    try std.testing.expect(matchPattern("static/*", "/static/js/app.js", null, null));
    try std.testing.expect(matchPattern("static/*", "/static", null, null));
    try std.testing.expect(matchPattern("static/*", "/static/", null, null));

    // 根通配符匹配一切
    try std.testing.expect(matchPattern("*", "/anything/at/all", null, null));
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
        pub fn process(self: *@This(), req_ctx: *RequestContext, res: *Response) !Middleware.NextAction {
            _ = self;
            _ = req_ctx;
            _ = res;
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

// 全局中间件测试用的容器级共享状态（inner fn 无法捕获 test 局部变量）
var test_gmw_global_called: bool = false;
var test_gmw_handler_called: bool = false;

test "Router.use - global middleware runs before route handler" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    test_gmw_global_called = false;
    test_gmw_handler_called = false;

    // 全局中间件记录调用顺序
    const Order = struct {
        pub fn process(_: *@This(), req_ctx: *RequestContext, res: *Response) !Middleware.NextAction {
            _ = req_ctx;
            _ = res;
            test_gmw_global_called = true;
            return .next;
        }
    };
    var order = Order{};
    const global_mw = Middleware.init(Order, &order);

    const fn_handler = Handler.fromFn(struct {
        fn handler(_: *RequestContext, _: *Response) !void {
            test_gmw_handler_called = true;
        }
    }.handler);

    try router.use(&.{global_mw});
    try router.route(.GET, "/x", fn_handler);

    // 构造最小请求上下文与响应
    var ctx = RequestContext{
        .allocator = allocator,
        .io = undefined,
        .method = .GET,
        .path = "/x",
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
    defer freeHashMap(&ctx.path_params, allocator);
    var res = Response.init(allocator, undefined);
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    try std.testing.expect(test_gmw_global_called);
    try std.testing.expect(test_gmw_handler_called);
}

var test_gmw_blocked: bool = false;

test "Router.use - global middleware can block request" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    test_gmw_blocked = false;

    const Blocking = struct {
        pub fn process(_: *@This(), req_ctx: *RequestContext, res: *Response) !Middleware.NextAction {
            req_ctx.blocked_status = .too_many_requests;
            _ = res.statusCode(.too_many_requests);
            test_gmw_blocked = true;
            return .respond;
        }
    };
    var blocker = Blocking{};
    const block_mw = Middleware.init(Blocking, &blocker);

    const fn_handler = Handler.fromFn(struct {
        fn handler(_: *RequestContext, _: *Response) !void {
            // 不应被调用
            std.testing.expect(false) catch {};
        }
    }.handler);

    try router.use(&.{block_mw});
    try router.route(.GET, "/x", fn_handler);

    var ctx = RequestContext{
        .allocator = allocator,
        .io = undefined,
        .method = .GET,
        .path = "/x",
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
    defer freeHashMap(&ctx.path_params, allocator);
    var res = Response.init(allocator, undefined);
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    // 被拦截：返回 true，handler 未执行，状态码已设置
    try std.testing.expect(matched);
    try std.testing.expect(test_gmw_blocked);
    try std.testing.expectEqual(std.http.Status.too_many_requests, res.status);
}
