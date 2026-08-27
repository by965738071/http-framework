//! Radix trie 路由（回应 bug.md §5）
//!
//! 原来用 `ArrayList(Route)` 线性扫描，每请求 2 次 matchPattern，
//! HEAD 还要再扫一遍。路由数量成为性能硬约束。
//!
//! 现在用 radix trie：O(路径段数) 匹配、前缀共享、注册时静态冲突检测。

const std = @import("std");
const http = std.http;
const Handler = @import("http_app").Handler;
const Middleware = @import("http_app").Middleware;
const RequestState = @import("http_app").RequestState;

/// 一条已注册的路由：handler + 该路由专属的中间件切片（来自 RouteGroup）。
/// middleware 切片在注册时拷贝到 trie arena，生命周期与 trie 绑定，dispatch
/// 只读，无需每请求重建。
pub const Route = struct {
    handler: Handler,
    middleware: []const Middleware = &.{},
};

const Node = struct {
    segment: []const u8 = "",
    param_name: ?[]const u8 = null,
    catch_all_name: ?[]const u8 = null,
    children: std.ArrayList(*Node) = .empty,
    // 按 method 索引的 route 映射
    handlers: std.enums.EnumMap(http.Method, Route) = .{},
    has_any_handler: bool = false,
    // 完整路由 pattern（插入时记录，匹配时直接复制）
    pattern: []const u8 = "",
    arena: std.mem.Allocator,

    fn init(arena: std.mem.Allocator) !*Node {
        const node = try arena.create(Node);
        node.* = .{ .arena = arena };
        return node;
    }
};

pub const Trie = struct {
    root: *Node,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Trie {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const root = try Node.init(arena.allocator());
        return .{
            .root = root,
            .arena = arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Trie) void {
        self.arena.deinit();
    }

    /// 注册路由。pattern 用 `:param` / `*catch_all` 语法。
    /// route.middleware 会被拷贝到 trie arena（生命周期与 trie 绑定）。
    pub fn insert(self: *Trie, method: http.Method, pattern: []const u8, route: Route) !void {
        const alloc = self.arena.allocator();
        var node = self.root;
        var it = std.mem.splitScalar(u8, pattern, '/');
        var first = true;
        var saw_catch_all = false;
        while (it.next()) |seg| {
            if (first) {
                first = false;
                if (seg.len == 0) continue; // leading /
            }
            if (seg.len == 0) continue;

            // catch-all 必须是最后一段，否则后续段永远不可达（回应审查 H3）。
            if (saw_catch_all) return error.InvalidRoute;
            if (seg[0] == '*') saw_catch_all = true;

            const child = try Trie.findOrCreateChild(node, seg, alloc);
            node = child;
        }
        if (node.handlers.get(method) != null) return error.RouteConflict;
        // 拷贝中间件切片到 trie arena，避免悬空（调用方的切片可能是栈上临时的）。
        const mw_copy = if (route.middleware.len > 0)
            try alloc.dupe(Middleware, route.middleware)
        else
            &[_]Middleware{};
        node.handlers.put(method, .{ .handler = route.handler, .middleware = mw_copy });
        node.has_any_handler = true;
        // P2-3：只在首次记录 pattern。同一节点上不同方法共享相同路径结构，
        // 但 :param 命名可能写法不同（/users/:id vs /users/:uid）。固定用首次，
        // 避免后续 insert 覆盖导致日志/指标聚合的 route_pattern 串台，并省一次 dupe。
        if (node.pattern.len == 0) {
            node.pattern = try alloc.dupe(u8, pattern);
        }
    }

    fn findOrCreateChild(parent: *Node, seg: []const u8, alloc: std.mem.Allocator) !*Node {
        // 检查是否已有匹配的子节点
        for (parent.children.items) |child| {
            if (seg.len > 0 and seg[0] == ':') {
                if (child.param_name != null) {
                    if (std.mem.eql(u8, child.param_name.?, seg[1..])) return child;
                    // 同层已有不同名的 :param → 路由歧义，匹配结果依赖注册顺序（回应审查 H2）。
                    return error.RouteConflict;
                }
                continue;
            }
            if (seg.len > 0 and seg[0] == '*') {
                if (child.catch_all_name != null) {
                    if (std.mem.eql(u8, child.catch_all_name.?, seg[1..])) return child;
                    // 同层已有不同名的 *catch_all → 歧义。
                    return error.RouteConflict;
                }
                continue;
            }
            if (std.mem.eql(u8, child.segment, seg)) return child;
        }

        // 若要新建 param/catch-all，但同层已存在另一个（不同名，上面已返回冲突的除外），
        // 也要拒绝：同层至多一个 param、至多一个 catch-all。
        if (seg.len > 0 and seg[0] == ':') {
            for (parent.children.items) |child| {
                if (child.param_name != null) return error.RouteConflict;
            }
        } else if (seg.len > 0 and seg[0] == '*') {
            for (parent.children.items) |child| {
                if (child.catch_all_name != null) return error.RouteConflict;
            }
        }

        // 创建新子节点
        const child = try Node.init(alloc);
        if (seg.len > 0 and seg[0] == ':') {
            child.param_name = try alloc.dupe(u8, seg[1..]);
        } else if (seg.len > 0 and seg[0] == '*') {
            child.catch_all_name = try alloc.dupe(u8, seg[1..]);
        } else {
            child.segment = try alloc.dupe(u8, seg);
        }
        try parent.children.append(alloc, child);
        return child;
    }

    /// 匹配路径。命中时提取 path_params 到 state，返回 route（handler + 中间件）。
    pub const MatchResult = struct {
        route: ?Route = null,
        pattern_matched: bool = false,
        pattern: []const u8 = "",
        allowed_methods: [16]?http.Method = @splat(null),
        allowed_count: u8 = 0,
    };

    pub fn match(self: *const Trie, method: http.Method, path: []const u8, state: *RequestState, alloc: std.mem.Allocator) MatchResult {
        var result = MatchResult{};
        self.matchNode(self.root, path, method, state, alloc, &result);
        return result;
    }

    fn matchNode(
        self: *const Trie,
        node: *Node,
        remaining: []const u8,
        method: http.Method,
        state: *RequestState,
        alloc: std.mem.Allocator,
        result: *MatchResult,
    ) void {
        // 到达路径末尾
        if (remaining.len == 0) {
            if (node.has_any_handler) {
                result.pattern_matched = true;
                result.pattern = node.pattern;
                if (node.handlers.get(method)) |r| {
                    result.route = r;
                } else {
                    // 收集 Allow 头
                    self.collectAllowed(node, result);
                }
            }
            return;
        }

        // 跳过前导 /
        const path = if (remaining[0] == '/') remaining[1..] else remaining;
        const seg_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        const seg = path[0..seg_end];

        if (seg.len == 0) {
            // 双斜杠或尾部斜杠
            self.matchNode(node, path[seg_end..], method, state, alloc, result);
            return;
        }

        // 先匹配静态子节点
        for (node.children.items) |child| {
            if (child.param_name == null and child.catch_all_name == null) {
                if (std.mem.eql(u8, child.segment, seg)) {
                    self.matchNode(child, path[seg_end..], method, state, alloc, result);
                    if (result.route != null) return;
                }
            }
        }

        // 再匹配 :param 子节点
        for (node.children.items) |child| {
            if (child.param_name != null) {
                state.path_params.put(alloc, child.param_name.?, seg) catch {};
                self.matchNode(child, path[seg_end..], method, state, alloc, result);
                if (result.route != null) return;
                _ = state.path_params.remove(child.param_name.?);
            }
        }

        // 最后匹配 *catch_all
        for (node.children.items) |child| {
            if (child.catch_all_name != null) {
                state.path_params.put(alloc, child.catch_all_name.?, path) catch {};
                self.matchNode(child, "", method, state, alloc, result);
                if (result.route != null) return;
                _ = state.path_params.remove(child.catch_all_name.?);
            }
        }
    }

    fn collectAllowed(self: *const Trie, node: *Node, result: *MatchResult) void {
        _ = self;
        var it = node.handlers.iterator();
        var has_get = false;
        while (it.next()) |entry| {
            if (entry.key == .GET) has_get = true;
            if (result.allowed_count < 16) {
                result.allowed_methods[result.allowed_count] = entry.key;
                result.allowed_count += 1;
            }
        }
        // P2-5：dispatch 实现了 HEAD→GET 回退，所以只要有 GET 就支持 HEAD。
        // 不把 HEAD 算进 Allow 会让 Allow 头与实际行为矛盾（RFC 9110 §10.2.1）。
        if (has_get and result.allowed_count < 16) {
            var already = false;
            var i: u8 = 0;
            while (i < result.allowed_count) : (i += 1) {
                if (result.allowed_methods[i] == .HEAD) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                result.allowed_methods[result.allowed_count] = .HEAD;
                result.allowed_count += 1;
            }
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Trie matches static route" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/hello", .{ .handler = handler });

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/hello", &state, allocator);
    try std.testing.expect(result.route != null);
}

test "Trie extracts path params" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/users/:id", .{ .handler = handler });

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/users/42", &state, allocator);
    try std.testing.expect(result.route != null);
    try std.testing.expectEqualStrings("42", state.path_params.get("id").?);
}

test "Trie returns 405 when pattern matches but method doesn't" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/items", .{ .handler = handler });

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.POST, "/items", &state, allocator);
    try std.testing.expect(result.pattern_matched);
    try std.testing.expect(result.route == null);
    try std.testing.expect(result.allowed_count > 0);
    try std.testing.expectEqual(http.Method.GET, result.allowed_methods[0].?);
}

test "Trie catch_all matches remaining path" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/static/*filepath", .{ .handler = handler });

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/static/css/app.css", &state, allocator);
    try std.testing.expect(result.route != null);
    try std.testing.expectEqualStrings("css/app.css", state.path_params.get("filepath").?);
}

test "Trie detects route conflicts" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/users/:id", .{ .handler = handler });
    try std.testing.expectError(error.RouteConflict, trie.insert(.GET, "/users/:id", .{ .handler = handler }));
}
test {
    std.testing.refAllDecls(@This());
}
