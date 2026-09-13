
const std = @import("std");
const model = @import("../model/mod.zig");
const repo_mod = @import("mod.zig");

const Row = model.user.Row;
const Database = repo_mod.Database;

pub const Filter = struct {
    org_id: ?u64 = null,
    status: ?[]const u8 = null,
    keyword: []const u8 = "",
    /// 只返回该组织及其子孙组织下的用户
    include_sub_orgs: bool = false,
    org_ids: []const u64 = &.{},
};

pub const UserRepository = struct {
    db: *Database,

    pub fn findById(self: UserRepository, alloc: std.mem.Allocator, id: u64) !?Row {
        return self.db.users.findById(alloc, id);
    }

    pub fn findByUsername(self: UserRepository, alloc: std.mem.Allocator, username: []const u8) !?Row {
        return self.db.users.findBy(alloc, "username", username);
    }

    pub fn findByEmail(self: UserRepository, alloc: std.mem.Allocator, email: []const u8) !?Row {
        return self.db.users.findBy(alloc, "email", email);
    }

    pub fn all(self: UserRepository, alloc: std.mem.Allocator) ![]Row {
        return self.db.users.all(alloc);
    }

    /// 按 org_id（含子树）检索成员。
    pub fn listByOrgIds(self: UserRepository, alloc: std.mem.Allocator, org_ids: []const u64) ![]Row {
        const rows = try self.db.users.all(alloc);
        var out = std.ArrayList(Row).empty;
        for (rows) |r| {
            for (org_ids) |oid| {
                if (r.org_id == oid) {
                    try out.append(alloc, r);
                    break;
                }
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// 分页检索。ORM 没有可组合的 LIKE / 多条件计数 API，这里先按等值条件
    /// 取出候选集，再在内存里做关键字过滤与切片（数据量在 demo 规模内）。
    pub fn search(
        self: UserRepository,
        alloc: std.mem.Allocator,
        filter: Filter,
        page: usize,
        page_size: usize,
    ) !repo_mod.SearchResult(Row) {
        const rows = try self.db.users.all(alloc);
        var matched = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (filter.org_id) |oid| {
                if (filter.include_sub_orgs) {
                    if (!contains(filter.org_ids, r.org_id)) continue;
                } else if (r.org_id != oid) continue;
            }
            if (filter.status) |st| {
                if (!std.mem.eql(u8, r.status, st)) continue;
            }
            if (filter.keyword.len > 0 and !matchesKeyword(r, filter.keyword)) continue;
            try matched.append(alloc, r);
        }
        const total = matched.items.len;
        const start = @min(page * page_size, total);
        const end = @min(start + page_size, total);
        return .{ .items = matched.items[start..end], .total = total };
    }

    pub fn countByOrg(self: UserRepository, org_id: u64) !usize {
        const rows = try self.db.users.all(self.db.allocator);
        defer self.db.users.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| { if (r.org_id == org_id) n += 1; }
        return n;
    }

    pub fn countAll(self: UserRepository) !usize {
        const rows = try self.db.users.all(self.db.allocator);
        defer self.db.users.freeRows(self.db.allocator, rows);
        return rows.len;
    }

    pub fn insert(self: UserRepository, row: Row) !u64 {
        const id = try self.db.users.insert(row);
        try self.db.users.flush();
        return id;
    }

    pub fn update(self: UserRepository, row: Row) !bool {
        const ok = try self.db.users.updateById(row.id, row);
        if (ok) try self.db.users.flush();
        return ok;
    }

    pub fn delete(self: UserRepository, id: u64) !bool {
        const ok = try self.db.users.deleteById(id);
        if (ok) try self.db.users.flush();
        return ok;
    }
};

fn contains(ids: []const u64, v: u64) bool {
    for (ids) |i| if (i == v) return true;
    return false;
}

/// 关键字命中用户名 / 显示名 / 邮箱（大小写不敏感子串）。
fn matchesKeyword(row: Row, keyword: []const u8) bool {
    const util = @import("../core/util.zig");
    return util.containsIgnoreCase(row.username, keyword) or
        util.containsIgnoreCase(row.display_name, keyword) or
        util.containsIgnoreCase(row.email, keyword);
}
