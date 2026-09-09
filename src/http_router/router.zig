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
/// var admin = try router.group("/admin");
/// try admin.use(auth_mw);              // 只作用于 /admin/* 的中间件
/// try admin.route(.GET, "/secret", h); // 实际注册为 /admin/secret
/// var v1 = admin.group("/v1");          // 嵌套：/admin/v1/*
/// ```
///
/// 组级中间件在 dispatch 时**追加在全局中间件之后、handler 之前**执行，
/// 因此顺序是：全局 mw → 组 mw（外层组先于内层组）→ handler。
/// 中间件切片存活于 router.arena，随 router 一起消失；中间件**实例**的所有权
/// 也归 Router（`use` 时登记进 Router.group_middleware，deinit 去重释放）。
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
        // 同时登记进 Router 的组级中间件列表，让 Router 成为它的释放者。
        // RouteGroup 是借用视图（没有 deinit，切片活在 router.arena 里随
        // router 一起消失），中间件实例却是调用方的，不登记就永远没人调
        // T.deinit()。这里只登记所有权，**不影响 dispatch 顺序**（顺序仍由
        // 上面的 group 切片决定，组级 mw 不会因此变成全局的）。
        try self.router.group_middleware.append(self.router.allocator, mw);
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
    /// 组级中间件的所有权登记处（**只用于释放**，不参与 dispatch 顺序）。
    /// 组级中间件经由 RouteGroup.use 登记进来，生命周期与 Router 相同。
    group_middleware: std.ArrayList(Middleware) = .empty,
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
        // 先判定 not-found handler 的归属，再 deinit trie：trie.deinit 会把
        // registered 列表本身释放掉，之后就查不到了。
        //
        // Handler 是值类型（union），复制它只是复制里面的指针。factory handler
        // 的 FactoryCtx 由 Handler.initFactory 用 allocator 分配、由
        // Handler.deinit 释放——所以「同一个 Handler 值」被两条释放路径各
        // deinit 一次就是 double-free：trie 那边对每个注册过的 handler 释放一次
        //（insert 时按值去重），not_found 这边再无条件释放一次。
        // 典型触发方式：`router.route(.GET, "/x", h); router.notFoundHandler(h);`
        const not_found_owned_by_trie = if (self.not_found) |nf| self.handlerOwnedByTrie(nf) else false;
        self.trie.deinit();
        // 全局与组级中间件统一去重后释放（见 Middleware.deinitAll）：同一个
        // 中间件值既可能 use() 两次，也可能同时挂在全局和某个组上。
        Middleware.deinitAll(self.global_middleware.items, &.{});
        Middleware.deinitAll(self.group_middleware.items, self.global_middleware.items);
        self.global_middleware.deinit(self.allocator);
        self.group_middleware.deinit(self.allocator);
        if (self.not_found) |h| {
            // 已由 trie 释放过（同一 handler 兼作路由与 404）→ 跳过，避免双重释放。
            if (!not_found_owned_by_trie) h.deinit();
        }
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
    ///
    /// prefix 拷进 router.arena 而不是借用调用方的切片：分组往往在路由注册
    /// 阶段长期存活，调用方传进来的可能是栈上/临时的缓冲区，借过来就是悬垂
    /// 指针，且要等到几行之后的 route()/group() 才解引用，症状极难定位。
    /// 与 RouteGroup.group 一致，复制可能失败，所以返回 error union。
    pub fn group(self: *Router, prefix: []const u8) !RouteGroup {
        const owned = try self.arena.allocator().dupe(u8, prefix);
        return .{ .router = self, .prefix = owned, .middleware = &.{} };
    }

    /// 设置 404 handler。handler 的所有权归 Router（deinit 时释放）。
    /// 与已注册路由共用同一个 handler 值是允许的，deinit 只释放一次。
    /// 重复调用会**先释放旧 handler**——Handler 是值类型，直接覆盖等于丢掉
    /// FactoryCtx 的唯一引用，永久泄漏。两种例外见实现注释。
    pub fn notFoundHandler(self: *Router, handler: Handler) void {
        if (self.not_found) |old| {
            // 例外一：旧 handler 同时在 trie.registered 里（也被 route() 注册
            // 过）→ trie 才是它的持有者，deinit 时会释放一次，这里再 deinit
            // 就是 double-free。判定与 deinit 共用 handlerOwnedByTrie。
            //
            // 例外二：新旧是同一个值。先释放再赋同一个值，等于把已经释放过的
            // 指针留在 not_found 里，等 deinit 再放一次。
            if (!std.meta.eql(old, handler) and !self.handlerOwnedByTrie(old)) old.deinit();
        }
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
            // P2-6：第一次 HEAD 匹配可能在 param 节点写过 path_params（即使未命中
            // handler）。回退前清空，否则 GET 重试可能叠加上一轮的残留参数。
            ctx.state.path_params.clear();
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

    /// handler 是否已被 `route()` 注册（即由 trie 托管、会由 trie 释放）。
    ///
    /// 判定逻辑必须与 deinit 里的完全一致，所以抽成一处共用：deinit 决定
    /// 「要不要释放 not_found」，notFoundHandler 覆盖旧值时决定「要不要先
    /// 释放旧的」。两处各写一份的话，改了其中一份就会重新长出 double-free。
    fn handlerOwnedByTrie(self: *const Router, h: Handler) bool {
        for (self.trie.registered.items) |r| {
            if (std.meta.eql(r, h)) return true;
        }
        return false;
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

    var state = http_app.RequestState{ .arena = allocator };
    defer state.deinit();
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/hello",
        .path = "/hello",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /hello HTTP/1.1\r\n\r\n",
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

    var state = http_app.RequestState{ .arena = allocator };
    defer state.deinit();
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/nope",
        .path = "/nope",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /nope HTTP/1.1\r\n\r\n",
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

    var state = http_app.RequestState{ .arena = allocator };
    defer state.deinit();
    const cfg = http_app.RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/users/42",
        .path = "/users/42",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET /users/42 HTTP/1.1\r\n\r\n",
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
        fn respond(ptr: *anyopaque, status: http.Status, headers: []const http.Header, body: []const u8, keep_alive: bool) anyerror!void {
            _ = keep_alive;
            const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try w.print("HTTP/1.1 {d}\r\n", .{@backingInt(status)});
            for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            try w.writeAll("\r\n");
            try w.writeAll(body);
        }
        fn startStream(_: *anyopaque, _: http.Status, _: []const http.Header, _: ?u64, _: []u8, _: bool) anyerror!http.BodyWriter {
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

    var state = http_app.RequestState{ .arena = arena };
    defer state.deinit();
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
    var admin = try router.group("/admin");
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
    var api = try router.group("/api");
    try api.use(Middleware.init(MarkerMiddleware, &outer_mw));

    var v1 = try api.group("/v1");
    try v1.route(.GET, "/ping", h);

    // 嵌套前缀：/api/v1/ping 应命中，且继承外组中间件标记
    var buf: [512]u8 = undefined;
    const resp = try dispatchPath(&router, allocator, "/api/v1/ping", &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "outer") != null);
}
/// 回归探针：factory handler 的 FactoryCtx 由 initFactory 分配、Handler.deinit
/// 释放，所以「deinit 了几次」等价于「FactoryCtx 被 free 了几次」。
const ProbeHandler = struct {
    pub fn init(a: std.mem.Allocator) !*@This() {
        const s = try a.create(@This());
        s.* = .{};
        return s;
    }
    pub fn handle(_: *@This(), _: *Context, _: *Response) !void {}
    pub fn deinit(_: *@This()) void {}
};

/// 只统计 free 次数的分配器，内层用 arena 兜底。
///
/// 内层**不能**直接用 std.testing.allocator（SafeAllocator）：它在 free 时
/// 持锁 panic，而 0.17 的 test runner 是多线程的，其它测试线程再分配就会
/// 死锁在那把锁上，整个 `zig build test` 挂住且没有任何失败输出——
/// 用它做 double-free 回归等于把失败信号弄丢了。
/// 这里让「释放了几次」变成一个可以直接断言的数字。
const FreeCounter = struct {
    inner: std.mem.Allocator,
    frees: usize = 0,

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocImpl, .resize = resizeImpl, .remap = remapImpl, .free = freeImpl } };
    }
};

test "Router.deinit: 同一 factory handler 兼作 route 与 notFound 只释放一次" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var router = try Router.init(allocator);
    const h = try Handler.initFactory(ProbeHandler, counter.allocator());
    try router.route(.GET, "/x", h);
    router.notFoundHandler(h);
    router.deinit();

    // 修复前是 2：trie 释放一次 + not_found 再释放一次同一个 FactoryCtx
    // → double free。不写 defer，就是要让 deinit 的结果直接被断言到。
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "Router.deinit: 独立的 notFound factory handler 仍被释放（不泄漏）" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var router = try Router.init(allocator);
    const h = try Handler.initFactory(ProbeHandler, counter.allocator());
    router.notFoundHandler(h);
    router.deinit();

    // 上面的「跳过」逻辑不能误伤这条路径：没有路由共用时必须照常释放。
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "notFoundHandler 重复调用：旧 handler 被释放一次（不再泄漏）" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var router = try Router.init(allocator);
    const h1 = try Handler.initFactory(ProbeHandler, counter.allocator());
    const h2 = try Handler.initFactory(ProbeHandler, counter.allocator());
    router.notFoundHandler(h1);
    // 修复前：直接覆盖 not_found，h1 的 FactoryCtx 再也没人引用 → 泄漏。
    router.notFoundHandler(h2);
    try std.testing.expectEqual(@as(usize, 1), counter.frees);

    // h2 仍由 deinit 释放，总数 2。不写 defer，就是要让 deinit 的结果被断言到。
    router.deinit();
    try std.testing.expectEqual(@as(usize, 2), counter.frees);
}

test "notFoundHandler 覆盖：兼作 route 的旧 handler 不被多释放一次" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var router = try Router.init(allocator);
    const shared = try Handler.initFactory(ProbeHandler, counter.allocator());
    const h2 = try Handler.initFactory(ProbeHandler, counter.allocator());
    try router.route(.GET, "/x", shared);
    router.notFoundHandler(shared);
    // shared 也注册在 trie 里 → trie 才是持有者，此处不能 deinit。
    router.notFoundHandler(h2);
    try std.testing.expectEqual(@as(usize, 0), counter.frees);

    router.deinit();
    // trie 释放 shared（1）+ not_found 释放 h2（1）= 2；多一次就是 double-free。
    try std.testing.expectEqual(@as(usize, 2), counter.frees);
}

test "notFoundHandler 重复设置同一个 handler 只释放一次" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var router = try Router.init(allocator);
    const h = try Handler.initFactory(ProbeHandler, counter.allocator());
    router.notFoundHandler(h);
    // 新旧同值：若先 deinit 再赋同值，deinit 里会对同一指针再放一次。
    router.notFoundHandler(h);
    try std.testing.expectEqual(@as(usize, 0), counter.frees);

    router.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

/// 中间件回归探针：`deinit` 释放一块从计数分配器拿到的内存，于是
/// 「deinit 了几次」= 「free 了几次」。
const ProbeMiddleware = struct {
    alloc: std.mem.Allocator,
    buf: []u8,

    fn init(a: std.mem.Allocator) !@This() {
        return .{ .alloc = a, .buf = try a.alloc(u8, 8) };
    }

    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: http_app.Next) !void {
        return next.call(ctx, res);
    }

    pub fn deinit(self: *@This()) void {
        self.alloc.free(self.buf);
    }
};

test "Router.use 同一中间件两次只 deinit 一次" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var mw = try ProbeMiddleware.init(counter.allocator());
    var router = try Router.init(allocator);
    try router.use(Middleware.init(ProbeMiddleware, &mw));
    try router.use(Middleware.init(ProbeMiddleware, &mw));
    router.deinit();

    // 修复前：global_middleware 两条一模一样的记录各 deinit 一次 → 2。
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "组级中间件由 Router 释放，且不与全局重复释放" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var mw = try ProbeMiddleware.init(counter.allocator());
    var router = try Router.init(allocator);
    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var admin = try router.group("/admin");
    try admin.use(Middleware.init(ProbeMiddleware, &mw));
    try admin.route(.GET, "/x", h);

    // 结论：组级中间件也归 Router 释放（RouteGroup 没有自己的 deinit），
    // 与全局登记进同一套去重逻辑 → 只释放一次。
    router.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "同一中间件同时挂全局与组级只 deinit 一次" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };

    var mw = try ProbeMiddleware.init(counter.allocator());
    var router = try Router.init(allocator);
    try router.use(Middleware.init(ProbeMiddleware, &mw));
    var admin = try router.group("/admin");
    try admin.use(Middleware.init(ProbeMiddleware, &mw));

    router.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "paramDecoded 按 RFC 3986 解码路径段：`+` 保持字面量、`%20` 解成空格" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(ctx: *Context, res: *Response) !void {
            const name = (try ctx.paramDecoded("name")) orelse "(none)";
            try res.text(name);
        }
    }.f);
    try router.route(.GET, "/files/:name", h);

    // /files/a+b.txt → "a+b.txt"（form 语义会错成 "a b.txt"）
    var buf: [512]u8 = undefined;
    const r1 = try dispatchPath(&router, allocator, "/files/a+b.txt", &buf);
    try std.testing.expect(std.mem.indexOf(u8, r1, "a+b.txt") != null);

    // %20 仍按百分号解码
    var buf2: [512]u8 = undefined;
    const r2 = try dispatchPath(&router, allocator, "/files/a%20b.txt", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "a b.txt") != null);
}

test "Router.group 拷贝前缀而非借用调用方切片" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const borrowed = try allocator.dupe(u8, "/admin");
    defer allocator.free(borrowed);
    const g = try router.group(borrowed);
    // 借用的话，borrowed 释放后 g.prefix 就是悬垂指针，而它要等到后面的
    // route()/group() 才被解引用。
    try std.testing.expect(g.prefix.ptr != borrowed.ptr);
    try std.testing.expectEqualStrings("/admin", g.prefix);
}

test {
    std.testing.refAllDecls(@This());
}
