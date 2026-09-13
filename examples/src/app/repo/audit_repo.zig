//! 审计日志仓储：写入 + 多条件检索 + 分页 + 导出。

const std = @import("std");
const model = @import("../model/mod.zig");
const repo_mod = @import("mod.zig");
const util = @import("../core/util.zig");

const Database = repo_mod.Database;
const Row = model.audit.Row;

pub const AuditFilter = struct {
    actor_id: ?u64 = null,
    module: []const u8 = "",
    action: []const u8 = "",
    result: []const u8 = "",
    keyword: []const u8 = "",
    /// 时间范围（epoch ms，闭区间）；0 表示不限
    from: u64 = 0,
    to: u64 = 0,
};

pub const AuditRepository = struct {
    db: *Database,

    pub fn insert(self: AuditRepository, row: Row) !u64 {
        const id = try self.db.audit_logs.insert(row);
        try self.db.audit_logs.flush();
        return id;
    }

    pub fn findById(self: AuditRepository, alloc: std.mem.Allocator, id: u64) !?Row {
        return self.db.audit_logs.findById(alloc, id);
    }

    /// 多条件检索 + 分页。结果按 id 倒序（最新在前）。
    ///
    /// ORM 的 QueryBuilder 只能表达等值条件，没有 LIKE / 时间范围比较，
    /// 所以这里全表取回后在内存里过滤（demo 数据量内可接受，见 FRICTION.md）。
    pub fn search(
        self: AuditRepository,
        alloc: std.mem.Allocator,
        filter: AuditFilter,
        page: usize,
        page_size: usize,
    ) !repo_mod.SearchResult(Row) {
        const rows = try self.db.audit_logs.all(alloc);
        var matched = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (!matches(r, filter)) continue;
            try matched.append(alloc, r);
        }
        // 倒序：最新的日志在最前。
        std.mem.reverse(Row, matched.items);
        const total = matched.items.len;
        const start = @min(page * page_size, total);
        const end = @min(start + page_size, total);
        return .{ .items = matched.items[start..end], .total = total };
    }

    /// 导出：忽略分页，返回全部命中（按 id 倒序）。
    pub fn searchAll(self: AuditRepository, alloc: std.mem.Allocator, filter: AuditFilter) ![]Row {
        const rows = try self.db.audit_logs.all(alloc);
        var matched = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (!matches(r, filter)) continue;
            try matched.append(alloc, r);
        }
        std.mem.reverse(Row, matched.items);
        return matched.toOwnedSlice(alloc);
    }

    /// 删除 `before_ms` 之前的日志，返回删除条数。
    pub fn purgeBefore(self: AuditRepository, before_ms: u64) !usize {
        const rows = try self.db.audit_logs.all(self.db.allocator);
        defer self.db.audit_logs.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| {
            if (r.created_at < before_ms) {
                if (try self.db.audit_logs.deleteById(r.id)) n += 1;
            }
        }
        if (n > 0) try self.db.audit_logs.flush();
        return n;
    }

    pub fn countAll(self: AuditRepository) !usize {
        const rows = try self.db.audit_logs.all(self.db.allocator);
        defer self.db.audit_logs.freeRows(self.db.allocator, rows);
        return rows.len;
    }
};

fn matches(row: Row, f: AuditFilter) bool {
    if (f.actor_id) |aid| {
        if (row.actor_id != aid) return false;
    }
    if (f.module.len > 0 and !std.mem.eql(u8, row.module, f.module)) return false;
    if (f.action.len > 0 and !std.mem.eql(u8, row.action, f.action)) return false;
    if (f.result.len > 0 and !std.mem.eql(u8, row.result, f.result)) return false;
    if (f.from > 0 and row.created_at < f.from) return false;
    if (f.to > 0 and row.created_at > f.to) return false;
    if (f.keyword.len > 0) {
        const hit = util.containsIgnoreCase(row.actor_name, f.keyword) or
            util.containsIgnoreCase(row.target_label, f.keyword) or
            util.containsIgnoreCase(row.module, f.keyword) or
            util.containsIgnoreCase(row.action, f.keyword) or
            util.containsIgnoreCase(row.message, f.keyword);
        if (!hit) return false;
    }
    return true;
}

// ── 测试：过滤逻辑是纯函数，直接单测 ───────────────────────────────

fn sample(id: u64, actor_id: u64, actor: []const u8, module: []const u8, action: []const u8, at: u64) Row {
    return .{
        .id = id,
        .actor_id = actor_id,
        .actor_name = actor,
        .module = module,
        .action = action,
        .target_type = "user",
        .target_id = 1,
        .target_label = "alice",
        .result = "success",
        .message = "created user",
        .changes = "[]",
        .ip = "127.0.0.1",
        .request_id = "r1",
        .created_at = at,
    };
}

test "audit matches 按操作人过滤" {
    const row = sample(1, 7, "admin", "user", "user.create", 100);
    try std.testing.expect(matches(row, .{ .actor_id = 7 }));
    try std.testing.expect(!matches(row, .{ .actor_id = 8 }));
}

test "audit matches 按模块与动作过滤" {
    const row = sample(1, 7, "admin", "user", "user.create", 100);
    try std.testing.expect(matches(row, .{ .module = "user" }));
    try std.testing.expect(!matches(row, .{ .module = "org" }));
    try std.testing.expect(matches(row, .{ .action = "user.create" }));
    try std.testing.expect(!matches(row, .{ .action = "user.delete" }));
}

test "audit matches 时间范围为闭区间" {
    const row = sample(1, 7, "admin", "user", "user.create", 100);
    try std.testing.expect(matches(row, .{ .from = 100, .to = 100 }));
    try std.testing.expect(matches(row, .{ .from = 50, .to = 150 }));
    try std.testing.expect(!matches(row, .{ .from = 101 }));
    try std.testing.expect(!matches(row, .{ .to = 99 }));
}

test "audit matches 关键字命中多个字段（大小写不敏感）" {
    const row = sample(1, 7, "admin", "user", "user.create", 100);
    try std.testing.expect(matches(row, .{ .keyword = "ADMIN" }));
    try std.testing.expect(matches(row, .{ .keyword = "alice" }));
    try std.testing.expect(matches(row, .{ .keyword = "created" }));
    try std.testing.expect(!matches(row, .{ .keyword = "zzz" }));
}

test "audit matches 空条件放行全部" {
    const row = sample(1, 7, "admin", "user", "user.create", 100);
    try std.testing.expect(matches(row, .{}));
}

test {
    std.testing.refAllDecls(@This());
}
