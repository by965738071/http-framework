//! Router — 基于 radix trie 的路由引擎（回应 bug.md §5 + 架构缺陷 #4）
//!
//! 职责：
//! 1. 注册路由到 trie
//! 2. 注册全局中间件
//! 3. 路由分组（前缀 + 组级中间件，支持嵌套）
//! 4. dispatch：trie 匹配 → 组装管道（全局 + 组级）→ 执行
//!
//! 不负责 TCP / 信号 / 连接生命周期（那些在 http_server 层）。

const std = @import("std");
const http = std.http;
const http_app = @import("http_app");
const Handler = http_app.Handler;
const Middleware = http_app.Middleware;
const Context = http_app.Context;
const Response = @import("http_protocol").Response;
const trie_mod = @import("trie.zig");
const Trie = trie_mod.Trie;
const Route = trie_mod.Route;

/// 路由分组 — 共享前缀 + 组级中间件（回应架构缺陷 #4）。
///
/// 用法：
/// ```zig
/// var admin = router.group("/admin");
/// try admin.use(auth_mw);              // 只作用于 /admin/* 的中间件
/// try admin.route(.GET, "/secret", h); // 实际注册为 /admin/secret
/// var v1 = admin.group("/v1");          // 嵌套：/admin/v1/*
/// ```
///
/// 组级中间件在 dispatch 时**追加在全局中间件之后、handler 之前**执行，
/// 因此顺序是：全局 mw → 组 mw（外层组先于内层组）→ handler。
/// 中间件切片存活于 router.arena，随 router 一起释放。
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    middleware: []const Middleware,

    /// 给本组追加一个中间件（作用于本组及其子组的所有路由）。
    pub fn use(self: *RouteGroup, mw: Middleware) !void {
        const alloc = self.router.arena.allocator();
        var list = try alloc.alloc(Middleware, self.middleware.len + 1);
        @memcpy(list[0..self.middleware.len], self.middleware);
        list[self.middleware.len] = mw;
        self.middleware = list;
    }

    /// 在本组前缀下注册路由。最终 pattern = 组前缀 + sub_pattern。
    pub fn route(self: *RouteGroup, method: http.Method, sub_pattern: []const u8, handler: Handler) !void {
        const full = try joinPath(self.router.arena.allocator(), self.prefix, sub_pattern);
        try self.router.trie.insert(method, full, .{ .handler = handler, .middleware = self.middleware });
    }

    /// 创建嵌套子组。子组前缀 = 本组前缀 + sub_prefix，继承本组中间件。
    pub fn group(self: *RouteGroup, sub_prefix: []const u8) !RouteGroup {
        const full = try joinPath(self.router.arena.allocator(), self.prefix, sub_prefix);
        // 拷贝当前中间件切片作为子组的起点（子组 use 时会在其上追加，不影响本组）。
        const inherited = try self.router.arena.allocator().dupe(Middleware, self.middleware);
        return .{ .router = self.router, .prefix = full, .middleware = inherited };
    }
};

/// 路径段数硬上限。trie 按段递归，段数过多会击穿协程栈。
/// 正常 REST 路径极少超过几十段，64 留足余量。
const MAX_PATH_SEGMENTS = 64;

/// 判断路径段数是否超限（连续 `/` 也计入，与 trie 递归行为一致）。
fn tooManyPathSegments(path: []const u8) bool {
    var count: usize = 0;
    for (path) |c| {
        if (c == '/') {
            count += 1;
            if (count > MAX_PATH_SEGMENTS) return true;
        }
    }
    return false;
}

/// 拼接前缀与子路径，规范化斜杠（避免 `//` 与缺失 `/`）。
fn joinPath(alloc: std.mem.Allocator, prefix: []const u8, sub: []const u8) ![]const u8 {
    const p = std.mem.trimEnd(u8, prefix, "/");
    const s = std.mem.trimStart(u8, sub, "/");
    if (s.len == 0) return if (p.len == 0) "/" else p;
    if (p.len == 0) return std.fmt.allocPrint(alloc, "/{s}", .{s});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ p, s });
}

pub const Router = struct {
    trie: Trie,
    global_middleware: std.ArrayList(Middleware) = .empty,
    not_found: ?Handler = null,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{
            .trie = try Trie.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        self.trie.deinit();
        for (self.global_middleware.items) |mw| mw.deinit();
        self.global_middleware.deinit(self.allocator);
        if (self.not_found) |h| h.deinit();
        self.arena.deinit();
    }

    /// 注册路由（无组级中间件）。
    pub fn route(self: *Router, method: http.Method, pattern: []const u8, handler: Handler) !void {
        try self.trie.insert(method, pattern, .{ .handler = handler });
    }

    /// 注册全局中间件（作用于所有路由）。
    pub fn use(self: *Router, mw: Middleware) !void {
        try self.global_middleware.append(self.allocator, mw);
    }

    /// 创建一个路由分组（共享前缀 + 组级中间件，修复 #4）。
    /// 组级中间件只作用于该组（及其子组）下注册的路由。
    pub fn group(self: *Router, prefix: []const u8) RouteGroup {
        return .{ .router = self, .prefix = prefix, .middleware = &.{} };
    }

    /// 设置 404 handler
    pub fn notFoundHandler(self: *Router, handler: Handler) void {
        self.not_found = handler;
    }

    /// 分发请求
    ///
    /// 三种结果都经过全局中间件管道，保证 404/405 响应也带 X-Request-Id、
    /// 日志上下文、计时头等（回应 fix.md §三：404 不走中间件）。
    pub fn dispatch(self: *const Router, ctx: *Context, res: *Response) !bool {
        const method = @as(http.Method, ctx.request.method);

        // 路径段数上限：matchNode 按段递归（非尾递归），超长路径（如 /a/a/.../a
        // 或 //////...）会击穿协程栈 → 远程 DoS。命中上限时按 404 处理（回应审查 C1）。
        if (tooManyPathSegments(ctx.request.path)) {
            const nf = self.not_found orelse Handler.fromFn(defaultNotFoundHandler);
            const next = http_app.Next.root(self.global_middleware.items, nf);
            try next.call(ctx, res);
            return true;
        }

        var result = self.trie.match(method, ctx.request.path, ctx.state, ctx.arena);

        // HEAD 自动回退到 GET（RFC 9110 §9.3.2：HEAD 应在任何提供 GET 的地方可用）。
        // std.http 在 HEAD 请求下会自动抑制 body，所以直接跑 GET handler 即可。
        if (result.route == null and method == .HEAD) {
            const get_result = self.trie.match(.GET, ctx.request.path, ctx.state, ctx.arena);
            if (get_result.route != null) result = get_result;
        }

        // 决定最终要执行的 handler 与组级中间件（命中 / 405 / 404 / 自定义）。
        var group_mw: []const Middleware = &.{};
        const handler: Handler = if (result.route) |r| blk: {
            group_mw = r.middleware;
            break :blk r.handler;
        } else if (result.pattern_matched) blk: {
            // 把 trie 计算出的 allowed_methods 拼成 Allow 头值（去重），存进 state，
            // 供 methodNotAllowedHandler 输出（RFC 9110 §10.2.1）。
            if (result.allowed_count > 0) {
                var buf = std.ArrayList(u8).empty;
                errdefer buf.deinit(ctx.arena);
                var seen: [16]http.Method = undefined;
                var seen_n: usize = 0;
                var i: u8 = 0;
                while (i < result.allowed_count) : (i += 1) {
                    const m = result.allowed_methods[i] orelse continue;
                    // 去重（回溯可能重复收集同一方法）。
                    var dup = false;
                    for (seen[0..seen_n]) |sm| {
                        if (sm == m) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;
                    seen[seen_n] = m;
                    seen_n += 1;
                    if (buf.items.len > 0) try buf.appendSlice(ctx.arena, ", ");
                    try buf.appendSlice(ctx.arena, @tagName(m));
                }
                ctx.state.allow_header = try buf.toOwnedSlice(ctx.arena);
            }
            break :blk Handler.fromFn(methodNotAllowedHandler);
        } else if (self.not_found) |nf| nf else Handler.fromFn(defaultNotFoundHandler);

        ctx.state.route_pattern = result.pattern;

        // 管道顺序：全局中间件 → 组级中间件 → handler（修复 #4）。
        // 全局 mw 切片稳定；组级 mw 来自 trie（注册时已拷贝到 trie arena）也稳定。
        // 无组级中间件时直接用全局切片，避免分配（热路径）。
        if (group_mw.len == 0) {
            const next = http_app.Next.root(self.global_middleware.items, handler);
            try next.call(ctx, res);
        } else {
            // 拼接全局 + 组级中间件到请求 arena。
            const total = self.global_middleware.items.len + group_mw.len;
            var combined = try ctx.arena.alloc(Middleware, total);
            @memcpy(combined[0..self.global_middleware.items.len], self.global_middleware.items);
            @memcpy(combined[self.global_middleware.items.len..], group_mw);
            const next = http_app.Next.root(combined, handler);
            try next.call(ctx, res);
        }
        return true;
    }

    fn methodNotAllowedHandler(ctx: *Context, res: *Response) !void {
        _ = res.statusCode(.method_not_allowed);
        if (ctx.state.allow_header) |allow| {
            _ = try res.header("Allow", allow);
        }
        try res.text("Method Not Allowed");
    }

    fn defaultNotFoundHandler(_: *Context, res: *Response) !void {
        _ = res.statusCode(.not_found);
        try res.text("Not Found");
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Router dispatches to matched route" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *Context, res: *Response) !void {
            try res.text("hello");
        }
    }.h);
    try router.route(.GET, "/hello", handler);

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/hello",
        .path = "/hello",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /hello HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "hello") != null);
}

test "Router returns 404 for unmatched route" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/nope",
        .path = "/nope",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /nope HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    // 修复后：404 也走全局中间件管道，dispatch 始终返回 true
    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "404") != null);
}

test "Router records route pattern instead of raw path (fix TODO)" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *Context, res: *Response) !void {
            try res.text("hello");
        }
    }.h);
    try router.route(.GET, "/users/:id", handler);

    var state = http_app.RequestState{};
    defer state.deinit(allocator);
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/users/42",
        .path = "/users/42",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /users/42 HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = allocator,
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    const matched = try router.dispatch(&ctx, &res);
    try std.testing.expect(matched);
    // 验证 route_pattern 是 pattern 而非原始路径
    try std.testing.expect(state.route_pattern != null);
    try std.testing.expectEqualStrings("/users/:id", state.route_pattern.?);
    // 验证 path_params 正确提取
    try std.testing.expectEqualStrings("42", state.path_params.get("id").?);
}

// 组级中间件测试用：在响应头打上标记，验证它只对组内路由生效。
const MarkerMiddleware = struct {
    value: []const u8,
    pub fn process(self: *@This(), ctx: *Context, res: *Response, next: http_app.Next) !void {
        _ = res.header("X-Group", self.value) catch {};
        try next.call(ctx, res);
    }
};

// 能捕获 header 的 sink（testSink 丢弃了 header，不能验证中间件写入的头）。
fn capturingSink(writer: *std.Io.Writer) @import("http_protocol").Sink {
    const impl = struct {
        fn respond(ptr: *anyopaque, status: http.Status, headers: []const http.Header, body: []const u8) anyerror!void {
            const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try w.print("HTTP/1.1 {d}\r\n", .{@backingInt(status)});
            for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            try w.writeAll("\r\n");
            try w.writeAll(body);
        }
        fn startStream(_: *anyopaque, _: http.Status, _: []const http.Header, _: ?u64, _: []u8) anyerror!http.BodyWriter {
            return error.NotSupported;
        }
    };
    return .{ .ptr = @ptrCast(writer), .vtable = &.{ .respond = impl.respond, .startStream = impl.startStream } };
}

fn dispatchPath(router: *Router, allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]const u8 {
    // 用临时 arena 作为请求级分配器（dispatch 会在 ctx.arena 上拼接中间件切片）。
    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();
    const arena = req_arena.allocator();

    var state = http_app.RequestState{};
    defer state.deinit(arena);
    const cfg = http_app.RequestConfig{};
    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "GET {s} HTTP/1.1\r\n\r\n", .{path});
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = path,
        .path = path,
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{ .request = &req, .state = &state, .config = &cfg, .arena = arena, .io = undefined };
    var writer = std.Io.Writer.fixed(buf);
    var res = Response.init(arena, capturingSink(&writer));
    defer res.deinit();
    _ = try router.dispatch(&ctx, &res);
    return buf[0..writer.end];
}

test "RouteGroup: 组级中间件只作用于组内路由" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    // 组外路由：无组标记
    try router.route(.GET, "/public", h);

    // 组内路由：带组标记
    var marker = MarkerMiddleware{ .value = "admin" };
    var admin = router.group("/admin");
    try admin.use(Middleware.init(MarkerMiddleware, &marker));
    try admin.route(.GET, "/secret", h);

    var buf: [512]u8 = undefined;
    // /public 不应有 X-Group
    const pub_resp = try dispatchPath(&router, allocator, "/public", &buf);
    try std.testing.expect(std.mem.indexOf(u8, pub_resp, "X-Group") == null);

    // /admin/secret 应有 X-Group: admin
    var buf2: [512]u8 = undefined;
    const adm_resp = try dispatchPath(&router, allocator, "/admin/secret", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, adm_resp, "X-Group") != null);
    try std.testing.expect(std.mem.indexOf(u8, adm_resp, "admin") != null);
}

test "RouteGroup: 嵌套子组继承前缀与中间件" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var outer_mw = MarkerMiddleware{ .value = "outer" };
    var api = router.group("/api");
    try api.use(Middleware.init(MarkerMiddleware, &outer_mw));

    var v1 = try api.group("/v1");
    try v1.route(.GET, "/ping", h);

    // 嵌套前缀：/api/v1/ping 应命中，且继承外组中间件标记
    var buf: [512]u8 = undefined;
    const resp = try dispatchPath(&router, allocator, "/api/v1/ping", &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "outer") != null);
}
test {
    std.testing.refAllDecls(@This());
}