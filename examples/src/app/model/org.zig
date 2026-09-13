//! 组织：树形结构（parent_id，0 表示根）。

const std = @import("std");
const framework = @import("http_framework");

pub const ROOT_PARENT: u64 = 0;

pub const Row = struct {
    id: u64 = 0,
    name: []const u8,
    code: []const u8,
    parent_id: u64 = 0,
    leader: []const u8,
    sort_order: u64 = 0,
    created_at: u64 = 0,
    updated_at: u64 = 0,
};

/// 组织编码唯一（理由同 user.Table：唯一性是数据层的职责，不该靠 service 预查）。
pub const Table = framework.orm.ModelWith(Row, "orgs", .{
    .unique = &.{ &.{"code"} },
});
pub const Store = Table.Store;

pub const View = struct {
    id: u64,
    name: []const u8,
    code: []const u8,
    parent_id: u64,
    leader: []const u8,
    sort_order: u64,
    member_count: u64 = 0,
    created_at: u64,
    updated_at: u64,
};

/// 树节点（GET /orgs/tree 的返回结构）。
pub const TreeNode = struct {
    id: u64,
    name: []const u8,
    code: []const u8,
    parent_id: u64,
    leader: []const u8,
    sort_order: u64,
    member_count: u64,
    children: []const TreeNode,
};

pub const diff_ignore = [_][]const u8{ "id", "updated_at", "created_at" };

/// 从扁平列表构建树。`rows` 需已按 sort_order/id 排好序。
/// 返回森林（parent_id 找不到父节点的、以及 parent_id==0 的节点都是根）。
pub fn buildTree(allocator: std.mem.Allocator, rows: []const View) ![]TreeNode {
    var out = std.ArrayList(TreeNode).empty;
    // 出错时只递归释放已构造节点的子树，缓冲区用 ArrayList.deinit 释放
    // （直接 free(items) 会因「长度 ≠ 容量」被 DebugAllocator 判为非法释放）。
    errdefer {
        for (out.items) |n| freeTree(allocator, n.children);
        out.deinit(allocator);
    }
    for (rows) |r| {
        const is_root = r.parent_id == ROOT_PARENT or !hasParent(rows, r.parent_id);
        if (is_root) try out.append(allocator, try materialize(allocator, rows, r.id, 0));
    }
    return out.toOwnedSlice(allocator);
}

fn materialize(allocator: std.mem.Allocator, rows: []const View, id: u64, depth: usize) !TreeNode {
    // 脏数据（父指针成环）不能让递归打穿栈。
    if (depth > rows.len) return error.CycleDetected;
    const self = for (rows) |r| {
        if (r.id == id) break r;
    } else return error.NotFound;

    var list = std.ArrayList(TreeNode).empty;
    errdefer {
        for (list.items) |n| freeTree(allocator, n.children);
        list.deinit(allocator);
    }
    for (rows) |r| {
        if (r.parent_id == id and r.id != id) {
            try list.append(allocator, try materialize(allocator, rows, r.id, depth + 1));
        }
    }
    // 不能用 `list.items`：ArrayList 的容量通常大于长度，而 `allocator.free`
    // 要求释放的字节数与当初分配的一致（DebugAllocator 会直接 panic）。
    const children = try list.toOwnedSlice(allocator);
    return .{
        .id = self.id,
        .name = self.name,
        .code = self.code,
        .parent_id = self.parent_id,
        .leader = self.leader,
        .sort_order = self.sort_order,
        .member_count = self.member_count,
        .children = children,
    };
}

fn hasParent(rows: []const View, parent_id: u64) bool {
    for (rows) |r| if (r.id == parent_id) return true;
    return false;
}

pub fn freeTree(allocator: std.mem.Allocator, nodes: []const TreeNode) void {
    for (nodes) |n| freeTree(allocator, n.children);
    if (nodes.len == 0) return;
    allocator.free(@constCast(nodes));
}

/// 判断 `ancestor_id` 是否是 `node_id` 的祖先（含自身）。
/// 移动组织时用它防止把父节点挂到自己的子孙下面形成环。
pub fn isAncestor(rows: []const Row, ancestor_id: u64, node_id: u64) bool {
    var cursor: u64 = node_id;
    var guard: usize = 0;
    while (cursor != ROOT_PARENT and guard <= rows.len) : (guard += 1) {
        if (cursor == ancestor_id) return true;
        const parent = for (rows) |r| {
            if (r.id == cursor) break r.parent_id;
        } else ROOT_PARENT;
        cursor = parent;
    }
    return false;
}

/// 收集 `id` 的整棵子树（含自身）的 id 列表。
pub fn subtreeIds(allocator: std.mem.Allocator, rows: []const Row, id: u64) ![]u64 {
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, id);
    var changed = true;
    while (changed) {
        changed = false;
        for (rows) |r| {
            if (contains(out.items, r.id)) continue;
            if (contains(out.items, r.parent_id)) {
                try out.append(allocator, r.id);
                changed = true;
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn contains(ids: []const u64, id: u64) bool {
    for (ids) |i| if (i == id) return true;
    return false;
}

// ── 测试 ────────────────────────────────────────────────────────────────

fn v(id: u64, parent_id: u64, name: []const u8) View {
    return .{
        .id = id,
        .name = name,
        .code = name,
        .parent_id = parent_id,
        .leader = "",
        .sort_order = id,
        .member_count = 0,
        .created_at = 0,
        .updated_at = 0,
    };
}

fn mkRow(id: u64, parent_id: u64) Row {
    return .{
        .id = id,
        .name = "n",
        .code = "c",
        .parent_id = parent_id,
        .leader = "",
        .sort_order = id,
        .created_at = 0,
        .updated_at = 0,
    };
}

test "buildTree 组装多层树" {
    const rows = [_]View{ v(1, 0, "root"), v(2, 1, "a"), v(3, 1, "b"), v(4, 2, "c") };
    const tree = try buildTree(std.testing.allocator, &rows);
    defer freeTree(std.testing.allocator, tree);

    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqual(@as(u64, 1), tree[0].id);
    try std.testing.expectEqual(@as(usize, 2), tree[0].children.len);
    try std.testing.expectEqual(@as(u64, 2), tree[0].children[0].id);
    try std.testing.expectEqual(@as(usize, 1), tree[0].children[0].children.len);
    try std.testing.expectEqual(@as(u64, 4), tree[0].children[0].children[0].id);
}

test "buildTree 支持多根（森林）" {
    const rows = [_]View{ v(1, 0, "r1"), v(2, 0, "r2"), v(3, 1, "a") };
    const tree = try buildTree(std.testing.allocator, &rows);
    defer freeTree(std.testing.allocator, tree);
    try std.testing.expectEqual(@as(usize, 2), tree.len);
}

test "buildTree 父节点缺失时该节点升级为根" {
    const rows = [_]View{v(1, 99, "orphan")};
    const tree = try buildTree(std.testing.allocator, &rows);
    defer freeTree(std.testing.allocator, tree);
    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqual(@as(u64, 1), tree[0].id);
}

test "isAncestor 检测环" {
    const rows = [_]Row{ mkRow(1, 0), mkRow(2, 1), mkRow(3, 2) };
    try std.testing.expect(isAncestor(&rows, 1, 3));
    try std.testing.expect(isAncestor(&rows, 2, 3));
    try std.testing.expect(isAncestor(&rows, 3, 3)); // 自身
    try std.testing.expect(!isAncestor(&rows, 3, 1));
    try std.testing.expect(!isAncestor(&rows, 2, 1));
}

test "isAncestor 在有环的脏数据上也能终止" {
    const rows = [_]Row{ mkRow(1, 2), mkRow(2, 1) };
    try std.testing.expect(isAncestor(&rows, 1, 1));
    try std.testing.expect(isAncestor(&rows, 2, 1));
}

test "subtreeIds 收集整棵子树" {
    const rows = [_]Row{ mkRow(1, 0), mkRow(2, 1), mkRow(3, 1), mkRow(4, 2), mkRow(9, 0) };
    const ids = try subtreeIds(std.testing.allocator, &rows, 1);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 4), ids.len);
    try std.testing.expect(contains(ids, 1));
    try std.testing.expect(contains(ids, 4));
    try std.testing.expect(!contains(ids, 9));
}

test {
    std.testing.refAllDecls(@This());
}
