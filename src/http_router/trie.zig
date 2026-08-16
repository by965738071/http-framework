//! Radix trie 路由（回应 bug.md §5）
//!
//! 原来用 `ArrayList(Route)` 线性扫描，每请求 2 次 matchPattern，
//! HEAD 还要再扫一遍。路由数量成为性能硬约束。
//!
//! 现在用 radix trie：O(路径段数) 匹配、前缀共享、注册时静态冲突检测。

const std = @import("std");
const http = std.http;
const Handler = @import("http_app").Handler;
const RequestState = @import("http_app").RequestState;

const Node = struct {
    segment: []const u8 = "",
    param_name: ?[]const u8 = null,
    catch_all_name: ?[]const u8 = null,
    children: std.ArrayList(*Node) = .empty,
    // 按 method 索引的 handler 映射
    handlers: std.enums.EnumMap(http.Method, Handler) = .{},
    has_any_handler: bool = false,
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
    pub fn insert(self: *Trie, method: http.Method, pattern: []const u8, handler: Handler) !void {
        const alloc = self.arena.allocator();
        var node = self.root;
        var it = std.mem.splitScalar(u8, pattern, '/');
        var first = true;
        while (it.next()) |seg| {
            if (first) {
                first = false;
                if (seg.len == 0) continue; // leading /
            }
            if (seg.len == 0) continue;

            const child = try Trie.findOrCreateChild(node, seg, alloc);
            node = child;
        }
        if (node.handlers.get(method) != null) return error.RouteConflict;
        node.handlers.put(method, handler);
        node.has_any_handler = true;
    }

    fn findOrCreateChild(parent: *Node, seg: []const u8, alloc: std.mem.Allocator) !*Node {
        // 检查是否已有匹配的子节点
        for (parent.children.items) |child| {
            if (seg.len > 0 and seg[0] == ':') {
                if (child.param_name != null) {
                    if (std.mem.eql(u8, child.param_name.?, seg[1..])) return child;
                }
                continue;
            }
            if (seg.len > 0 and seg[0] == '*') {
                if (child.catch_all_name != null) {
                    if (std.mem.eql(u8, child.catch_all_name.?, seg[1..])) return child;
                }
                continue;
            }
            if (std.mem.eql(u8, child.segment, seg)) return child;
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

    /// 匹配路径。命中时提取 path_params 到 state，返回 handler。
    /// 返回 null 表示无匹配。
    pub const MatchResult = struct {
        handler: ?Handler = null,
        pattern_matched: bool = false,
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
                if (node.handlers.get(method)) |h| {
                    result.handler = h;
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
                    if (result.handler != null) return;
                }
            }
        }

        // 再匹配 :param 子节点
        for (node.children.items) |child| {
            if (child.param_name != null) {
                state.path_params.put(alloc, child.param_name.?, seg) catch {};
                self.matchNode(child, path[seg_end..], method, state, alloc, result);
                if (result.handler != null) return;
                _ = state.path_params.remove(child.param_name.?);
            }
        }

        // 最后匹配 *catch_all
        for (node.children.items) |child| {
            if (child.catch_all_name != null) {
                state.path_params.put(alloc, child.catch_all_name.?, path) catch {};
                self.matchNode(child, "", method, state, alloc, result);
                if (result.handler != null) return;
            }
        }
    }

    fn collectAllowed(self: *const Trie, node: *Node, result: *MatchResult) void {
        _ = self;
        var it = node.handlers.iterator();
        while (it.next()) |entry| {
            if (result.allowed_count < 16) {
                result.allowed_methods[result.allowed_count] = entry.key;
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
    try trie.insert(.GET, "/hello", handler);

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/hello", &state, allocator);
    try std.testing.expect(result.handler != null);
}

test "Trie extracts path params" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/users/:id", handler);

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/users/42", &state, allocator);
    try std.testing.expect(result.handler != null);
    try std.testing.expectEqualStrings("42", state.path_params.get("id").?);
}

test "Trie returns 405 when pattern matches but method doesn't" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/items", handler);

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.POST, "/items", &state, allocator);
    try std.testing.expect(result.pattern_matched);
    try std.testing.expect(result.handler == null);
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
    try trie.insert(.GET, "/static/*filepath", handler);

    var state = RequestState{};
    defer state.deinit(allocator);
    const result = trie.match(.GET, "/static/css/app.css", &state, allocator);
    try std.testing.expect(result.handler != null);
    try std.testing.expectEqualStrings("css/app.css", state.path_params.get("filepath").?);
}

test "Trie detects route conflicts" {
    const allocator = std.testing.allocator;
    var trie = try Trie.init(allocator);
    defer trie.deinit();

    const handler = Handler.fromFn(struct {
        fn h(_: *@import("http_app").Context, _: *@import("http_protocol").Response) !void {}
    }.h);
    try trie.insert(.GET, "/users/:id", handler);
    try std.testing.expectError(error.RouteConflict, trie.insert(.GET, "/users/:id", handler));
}
