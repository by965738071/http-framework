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
/// ## `use` 是顺序无关的（F-11）
///
/// `use` 对**整个组**生效，与它和 `route()` 的先后无关：先注册路由再 `use`，
/// 中间件照样生效。旧实现在 `route()` 时把 `middleware` 切片快照进 trie，
/// 于是「先 use 后 route」是唯一正确写法——想给不同路由配不同中间件就只能
/// 每条路由开一个子组，30 条路由 = 30 个子组 + 30 个中间件实例。
///
/// 现在 trie 里只存分组 id（`Route.group`），中间件链推迟到 dispatch 时按
/// 「祖先链」解析，注册顺序因此不再进入语义。
///
/// ## 执行顺序（判定顺序）
///
/// ```text
/// 全局 use()  →  外层组 use()  →  内层组 use()  →  handler
/// ```
///
/// 同组内多次 `use` 仍按调用先后执行（这是唯一保留的顺序语义：一个组内
/// 「先鉴权还是先记日志」得有确定答案）。路由级中间件当前没有 API——
/// 需要 per-route 语义时开一个 `group("")` 子组即可（F-09/F-11）。
///
/// 因为解析发生在 dispatch 时，对父组 `use` 也会影响**已经创建**的子组，
/// 这与文档里「作用于本组及其子组」一致；想要隔离就别嵌套，另开一个平级组。
///
/// `RouteGroup` 是借用视图（无 deinit）；中间件**实例**的所有权归 Router
/// （`use` 时登记进 `Router.group_middleware`，deinit 去重释放）。
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    /// 本组在 `Router.groups` 中的下标。
    id: trie_mod.GroupId,

    /// 给本组追加一个中间件。对本组（含子组）所有路由生效，**与注册顺序无关**。
    pub fn use(self: *RouteGroup, mw: Middleware) !void {
        try self.router.groups.items[self.id].middleware.append(self.router.allocator, mw);
        // 同时登记进 Router 的组级中间件列表，让 Router 成为它的释放者。
        // RouteGroup 是借用视图（没有 deinit），中间件实例却是调用方的，
        // 不登记就永远没人调 T.deinit()。这里只登记所有权，**不影响 dispatch
        // 顺序**（顺序由上面的 group 链表决定，组级 mw 不会因此变成全局的）。
        try self.router.group_middleware.append(self.router.allocator, mw);
    }

    /// 在本组前缀下注册路由。最终 pattern = 组前缀 + sub_pattern。
    pub fn route(self: *RouteGroup, method: http.Method, sub_pattern: []const u8, handler: Handler) !void {
        const full = try joinPath(self.router.arena.allocator(), self.prefix, sub_pattern);
        try self.router.trie.insert(method, full, .{ .handler = handler, .group = self.id });
    }

    /// 创建嵌套子组。子组前缀 = 本组前缀 + sub_prefix。
    ///
    /// 子组不再拷贝父组中间件，而是在 `Router.groups` 里记住 parent——
    /// 拷贝会把「创建子组的时刻」固化成顺序语义（父组之后再 use 就进不来）。
    pub fn group(self: *RouteGroup, sub_prefix: []const u8) !RouteGroup {
        const full = try joinPath(self.router.arena.allocator(), self.prefix, sub_prefix);
        return self.router.newGroup(self.id, full);
    }
};

/// 一个已注册的路由分组：父组 + 前缀 + 组级中间件。
///
/// 中间件存在 `ArrayList` 而不是切片：`use` 会持续追加，且追加必须对
/// 已注册的路由可见（F-11）。
const Group = struct {
    parent: ?trie_mod.GroupId,
    prefix: []const u8,
    middleware: std.ArrayList(Middleware) = .empty,
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

/// 路径前缀判定，**按 `/` 段对齐**：`/health` 命中 `/health` 与 `/health/live`，
/// 不命中 `/healthz`。纯字节前缀会把一个组的中间件（CORS、统一错误格式）
/// 泄漏到拼写相近但毫无关系的 URL 上。
/// 空前缀 / 仅 `/` 视为匹配一切（对应 `group("")` 的根组写法）。
fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0) return true;
    if (!std.mem.startsWith(u8, path, p)) return false;
    if (path.len == p.len) return true;
    return path[p.len] == '/';
}

pub const Router = struct {
    trie: Trie,
    global_middleware: std.ArrayList(Middleware) = .empty,
    /// 所有路由分组（下标即 `GroupId`）。dispatch 时按 parent 链解析出
    /// 「外层 → 内层」的中间件顺序；404/405 时按这里的 prefix 做最长前缀匹配。
    groups: std.ArrayList(Group) = .empty,
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
        // 组自身只持有中间件**值**的容器，实例已由上面的 deinitAll 释放。
        for (self.groups.items) |*g| g.middleware.deinit(self.allocator);
        self.groups.deinit(self.allocator);
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

    /// 创建一个顶层路由分组（共享前缀 + 组级中间件，修复 #4）。
    /// 组级中间件只作用于该组（及其子组）下注册的路由。
    ///
    /// prefix 拷进 router.arena 而不是借用调用方的切片：分组往往在路由注册
    /// 阶段长期存活，调用方传进来的可能是栈上/临时的缓冲区，借过来就是悬垂
    /// 指针，且要等到几行之后的 route()/group() 才解引用，症状极难定位。
    /// 与 RouteGroup.group 一致，复制可能失败，所以返回 error union。
    pub fn group(self: *Router, prefix: []const u8) !RouteGroup {
        const owned = try self.arena.allocator().dupe(u8, prefix);
        return self.newGroup(null, owned);
    }

    /// 登记一个新分组（parent 为 null 即顶层组），返回它的借用视图。
    fn newGroup(self: *Router, parent: ?trie_mod.GroupId, prefix: []const u8) !RouteGroup {
        try self.groups.append(self.allocator, .{ .parent = parent, .prefix = prefix });
        const id: trie_mod.GroupId = @intCast(self.groups.items.len - 1);
        return .{ .router = self, .prefix = prefix, .id = id };
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
    /// 三种结果（命中 / 405 / 404）都经过中间件管道，保证 404/405 响应也带
    /// X-Request-Id、日志上下文、计时头等（回应 fix.md §三：404 不走中间件）。
    ///
    /// 404 / 405 还会额外走**最长前缀匹配的组**的中间件（F-12），所以挂在组上
    /// 的「统一 JSON 错误体 / CORS」也能生效；规则见 `groupForPath`。
    pub fn dispatch(self: *const Router, ctx: *Context, res: *Response) !bool {
        const method = @as(http.Method, ctx.request.method);

        // 路径段数上限：matchNode 按段递归（非尾递归），超长路径（如 /a/a/.../a
        // 或 //////...）会击穿协程栈 → 远程 DoS。命中上限时按 404 处理（回应审查 C1）。
        const result: Trie.MatchResult = if (tooManyPathSegments(ctx.request.path)) .{} else blk: {
            var r = self.trie.match(method, ctx.request.path, ctx.state, ctx.arena);

            // HEAD 自动回退到 GET（RFC 9110 §9.3.2：HEAD 应在任何提供 GET 的地方可用）。
            // std.http 在 HEAD 请求下会自动抑制 body，所以直接跑 GET handler 即可。
            if (r.route == null and method == .HEAD) {
                // P2-6：第一次 HEAD 匹配可能在 param 节点写过 path_params（即使未命中
                // handler）。回退前清空，否则 GET 重试可能叠加上一轮的残留参数。
                ctx.state.path_params.clear();
                const get_result = self.trie.match(.GET, ctx.request.path, ctx.state, ctx.arena);
                if (get_result.route != null) r = get_result;
            }
            break :blk r;
        };

        // 决定最终要执行的 handler，以及「这条请求归哪个组管」。
        var route_group: trie_mod.GroupId = trie_mod.NO_GROUP;
        const handler: Handler = if (result.route) |r| blk: {
            route_group = r.group;
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

        // 404 / 405（F-12）：没有具体路由可参照，退化为「最长前缀匹配的组」。
        // 规则见 groupForPath 的注释。命中路由时不走这里——路由自己的组已经明确。
        if (result.route == null and route_group == trie_mod.NO_GROUP) {
            route_group = self.groupForPath(ctx.request.path);
        }

        ctx.state.route_pattern = result.pattern;

        // 组级中间件链 = 该组及其所有祖先的 use()，按「外层 → 内层」排列。
        // 分配在请求 arena 上，随请求一起回收。
        const chain = try self.groupChain(ctx.arena, route_group);
        var group_total: usize = 0;
        for (chain) |gid| group_total += self.groups.items[gid].middleware.items.len;

        // 管道顺序：全局中间件 → 外层组 → 内层组 → handler（修复 #4）。
        // 无组级中间件时直接用全局切片，避免分配（热路径，也是最常见的情形）。
        if (group_total == 0) {
            const next = http_app.Next.root(self.global_middleware.items, handler);
            try next.call(ctx, res);
        } else {
            // 拼接全局 + 组级中间件到请求 arena。
            const total = self.global_middleware.items.len + group_total;
            var combined = try ctx.arena.alloc(Middleware, total);
            @memcpy(combined[0..self.global_middleware.items.len], self.global_middleware.items);
            var w = self.global_middleware.items.len;
            for (chain) |gid| {
                const mws = self.groups.items[gid].middleware.items;
                @memcpy(combined[w..][0..mws.len], mws);
                w += mws.len;
            }
            const next = http_app.Next.root(combined, handler);
            try next.call(ctx, res);
        }
        return true;
    }

    /// 从 `group` 向上走到根，返回「外层在前」的分组 id 链（分配在 `alloc` 上）。
    ///
    /// 为什么要先自底向上收集再反向：中间件必须是外层先执行——鉴权要在业务
    /// 守卫之前、CORS 要在鉴权之前。若按下游顺序直接追加，鉴权类中间件会
    /// 跑到 CORS 之后，预检请求直接被 401 挡掉。
    fn groupChain(self: *const Router, alloc: std.mem.Allocator, leaf: trie_mod.GroupId) ![]trie_mod.GroupId {
        if (leaf == trie_mod.NO_GROUP) return &.{};
        var depth: usize = 0;
        var cur: trie_mod.GroupId = leaf;
        while (cur != trie_mod.NO_GROUP) : (depth += 1) {
            cur = self.groups.items[cur].parent orelse trie_mod.NO_GROUP;
        }
        const chain = try alloc.alloc(trie_mod.GroupId, depth);
        cur = leaf;
        var i: usize = depth;
        while (cur != trie_mod.NO_GROUP) {
            i -= 1;
            chain[i] = cur;
            cur = self.groups.items[cur].parent orelse trie_mod.NO_GROUP;
        }
        return chain;
    }

    /// 404 / 405 时决定「哪个组的中间件算数」：**路径前缀最长匹配的组**。
    ///
    /// 为什么是这条规则：
    /// - **405**：URL 已经在 trie 里匹配到了节点（只是 method 不对），请求
    ///   确实落在这个 URL 空间里，用同一前缀的组最贴近用户预期。
    /// - **404**：请求落进了某个组的 URL 空间但没命中任何路由，同理。
    /// - 前缀**段对齐**（`/health` 不匹配 `/healthz`）：否则一个组的中间件会
    ///   泄漏到拼写相近但完全无关的 URL 上。
    ///
    /// 平局（同长度前缀，典型场景是 `group("")` 造出的同前缀子组）取
    /// **最先注册**的那个：`group("")` 子组是「为单条路由挂守卫」的写法，
    /// 让 404 也去跑它的守卫会得到 401/403 而不是 404——而最先注册的往往是
    /// 承载「统一错误格式 / CORS」这类全组语义的父组。
    ///
    /// 一个都没匹配上就返回 NO_GROUP，此时只跑全局中间件（框架默认格式）。
    fn groupForPath(self: *const Router, path: []const u8) trie_mod.GroupId {
        var best: trie_mod.GroupId = trie_mod.NO_GROUP;
        var best_len: usize = 0;
        for (self.groups.items, 0..) |g, i| {
            // 严格长于当前最优 → 平局时保留先注册者（下标更小）。
            if (g.prefix.len <= best_len) continue;
            if (!pathHasPrefix(path, g.prefix)) continue;
            best = @intCast(i);
            best_len = g.prefix.len;
        }
        return best;
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
    return dispatchRequest(router, allocator, .GET, path, buf);
}

fn dispatchRequest(router: *Router, allocator: std.mem.Allocator, method: http.Method, path: []const u8, buf: []u8) ![]const u8 {
    // 用临时 arena 作为请求级分配器（dispatch 会在 ctx.arena 上拼接中间件切片）。
    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();
    const arena = req_arena.allocator();

    var state = http_app.RequestState{ .arena = arena };
    defer state.deinit();
    const cfg = http_app.RequestConfig{};
    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "{s} {s} HTTP/1.1\r\n\r\n", .{ @tagName(method), path });
    var req = @import("http_protocol").Request{
        .method = method,
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

// ── F-11：组级 use 与注册顺序无关 ──────────────────────────────────────

/// 执行轨迹记录器：固定容量、无分配（中间件里用 ctx.arena 记录的话，
/// 释放方就得是 arena，与测试的 allocator 对不上）。
const Trace = struct {
    items: [16]u8 = @splat(0),
    len: usize = 0,

    fn push(self: *@This(), tag: u8) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = tag;
        self.len += 1;
    }

    fn slice(self: *const @This()) []const u8 {
        return self.items[0..self.len];
    }
};

const TraceMiddleware = struct {
    tag: u8,
    trace: *Trace,

    pub fn process(self: *@This(), ctx: *Context, res: *Response, next: http_app.Next) !void {
        self.trace.push(self.tag);
        return next.call(ctx, res);
    }
};

test "F-11: 先 route 后 use，中间件仍然生效（顺序无关）" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var g = try router.group("/api");
    // 修复前：use 在 route 之后 → 中间件被永久漏掉（route 时已快照切片）。
    try g.route(.GET, "/ping", h);
    var late = MarkerMiddleware{ .value = "late" };
    try g.use(Middleware.init(MarkerMiddleware, &late));

    var buf: [512]u8 = undefined;
    const resp = try dispatchPath(&router, allocator, "/api/ping", &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Group: late") != null);
}

test "F-11: 先建子组后给父组 use，子组路由也生效" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var api = try router.group("/api");
    var v1 = try api.group("/v1");
    try v1.route(.GET, "/ping", h);
    // 父组的 use 晚于子组创建、晚于路由注册
    var late = MarkerMiddleware{ .value = "parent" };
    try api.use(Middleware.init(MarkerMiddleware, &late));

    var buf: [512]u8 = undefined;
    const resp = try dispatchPath(&router, allocator, "/api/v1/ping", &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Group: parent") != null);
}

test "F-11: 中间件执行顺序 = 全局 → 外层组 → 内层组" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            _ = res;
        }
    }.f);

    var trace = Trace{};
    var g_mw = TraceMiddleware{ .tag = 'G', .trace = &trace };
    var o_mw = TraceMiddleware{ .tag = 'O', .trace = &trace };
    var i_mw = TraceMiddleware{ .tag = 'I', .trace = &trace };

    try router.use(Middleware.init(TraceMiddleware, &g_mw));
    var api = try router.group("/api");
    try api.use(Middleware.init(TraceMiddleware, &o_mw));
    var v1 = try api.group("/v1");
    try v1.use(Middleware.init(TraceMiddleware, &i_mw));
    try v1.route(.GET, "/ping", h);

    var buf: [512]u8 = undefined;
    _ = try dispatchPath(&router, allocator, "/api/v1/ping", &buf);
    try std.testing.expectEqualStrings("GOI", trace.slice());
}

test "F-11: 同组内多次 use 保持调用先后" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            _ = res;
        }
    }.f);

    var trace = Trace{};
    var a_mw = TraceMiddleware{ .tag = 'A', .trace = &trace };
    var b_mw = TraceMiddleware{ .tag = 'B', .trace = &trace };

    var g = try router.group("/api");
    try g.use(Middleware.init(TraceMiddleware, &a_mw));
    try g.use(Middleware.init(TraceMiddleware, &b_mw));
    try g.route(.GET, "/ping", h);

    var buf: [512]u8 = undefined;
    _ = try dispatchPath(&router, allocator, "/api/ping", &buf);
    try std.testing.expectEqualStrings("AB", trace.slice());
}

// ── F-12：404 / 405 走组级中间件 ──────────────────────────────────────

test "F-12: 404 走最长前缀匹配组的中间件" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var api_mw = MarkerMiddleware{ .value = "api" };
    var api = try router.group("/api");
    try api.use(Middleware.init(MarkerMiddleware, &api_mw));

    var v1_mw = MarkerMiddleware{ .value = "v1" };
    var v1 = try api.group("/v1");
    try v1.use(Middleware.init(MarkerMiddleware, &v1_mw));
    try v1.route(.GET, "/ping", h);

    // /api/v1/nope → 最长前缀是 /api/v1。选中它的同时也带上祖先 /api：
    // 404 与命中路由走同一套「外层 → 内层」链，否则会漏掉挂在外层组的 CORS。
    var buf: [512]u8 = undefined;
    const r1 = try dispatchPath(&router, allocator, "/api/v1/nope", &buf);
    try std.testing.expect(std.mem.indexOf(u8, r1, "404") != null);
    const i_api = std.mem.indexOf(u8, r1, "X-Group: api").?;
    const i_v1 = std.mem.indexOf(u8, r1, "X-Group: v1").?;
    try std.testing.expect(i_api < i_v1);

    // /api/nope → 最长前缀是 /api → 带 api 标记
    var buf2: [512]u8 = undefined;
    const r2 = try dispatchPath(&router, allocator, "/api/nope", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "X-Group: api") != null);

    // /other → 不属于任何组 → 只有全局中间件（无标记），仍是框架默认 404
    var buf3: [512]u8 = undefined;
    const r3 = try dispatchPath(&router, allocator, "/other", &buf3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "X-Group") == null);
}

test "F-12: 404 的组前缀按段对齐（/health 不匹配 /healthz）" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var mw = MarkerMiddleware{ .value = "health" };
    var g = try router.group("/health");
    try g.use(Middleware.init(MarkerMiddleware, &mw));
    try g.route(.GET, "/", h);

    var buf: [512]u8 = undefined;
    const r = try dispatchPath(&router, allocator, "/healthz", &buf);
    // 段不对齐的话 /healthz 会继承 /health 的中间件，把无关 URL 拉进组语义
    try std.testing.expect(std.mem.indexOf(u8, r, "X-Group") == null);
}

test "F-12: 405 走最长前缀匹配组的中间件" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    var mw = MarkerMiddleware{ .value = "v1" };
    var g = try router.group("/api/v1");
    try g.use(Middleware.init(MarkerMiddleware, &mw));
    try g.route(.GET, "/ping", h);

    var buf: [512]u8 = undefined;
    const resp = try dispatchRequest(&router, allocator, .POST, "/api/v1/ping", &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "405") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Group: v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Allow") != null);
}

test "F-12: 同前缀平局取最先注册的组（group(\"\") 子组不抢 404）" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    const h = Handler.fromFn(struct {
        fn f(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.f);

    // 父组：全组语义（统一错误格式）
    var parent_mw = MarkerMiddleware{ .value = "parent" };
    var api = try router.group("/api/v1");
    try api.use(Middleware.init(MarkerMiddleware, &parent_mw));

    // 子组：为单条路由挂的守卫（examples 的 App.route 就是这个写法）
    var guard_mw = MarkerMiddleware{ .value = "guard" };
    var sub = try api.group("");
    try sub.use(Middleware.init(MarkerMiddleware, &guard_mw));
    try sub.route(.GET, "/users", h);

    // 命中 /api/v1/users → 父子都跑（parent 先）
    var buf: [512]u8 = undefined;
    const hit = try dispatchPath(&router, allocator, "/api/v1/users", &buf);
    try std.testing.expect(std.mem.indexOf(u8, hit, "X-Group: parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "X-Group: guard") != null);

    // 404 在 /api/v1 下：若选中 guard 子组，404 会被守卫改成 401/403。
    // 平局取先注册者 = 父组 → 只有 parent。
    var buf2: [512]u8 = undefined;
    const miss = try dispatchPath(&router, allocator, "/api/v1/nope", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, miss, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss, "X-Group: parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss, "X-Group: guard") == null);
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
