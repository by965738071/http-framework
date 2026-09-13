//! 组织仓储。

const std = @import("std");
const model = @import("../model/mod.zig");
const repo_mod = @import("mod.zig");

const Row = model.org.Row;
const Database = repo_mod.Database;

pub const OrgRepository = struct {
    db: *Database,

    pub fn findById(self: OrgRepository, alloc: std.mem.Allocator, id: u64) !?Row {
        return self.db.orgs.findById(alloc, id);
    }

    pub fn findByCode(self: OrgRepository, alloc: std.mem.Allocator, code: []const u8) !?Row {
        return self.db.orgs.findBy(alloc, "code", code);
    }

    pub fn all(self: OrgRepository, alloc: std.mem.Allocator) ![]Row {
        return self.db.orgs.all(alloc);
    }

    pub fn childrenOf(self: OrgRepository, alloc: std.mem.Allocator, parent_id: u64) ![]Row {
        const rows = try self.db.orgs.all(alloc);
        var out = std.ArrayList(Row).empty;
        for (rows) |r| if (r.parent_id == parent_id) try out.append(alloc, r);
        return out.toOwnedSlice(alloc);
    }

    pub fn countChildren(self: OrgRepository, parent_id: u64) !usize {
        const rows = try self.db.orgs.all(self.db.allocator);
        defer self.db.orgs.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| { if (r.parent_id == parent_id) n += 1; }
        return n;
    }

    pub fn countAll(self: OrgRepository) !usize {
        const rows = try self.db.orgs.all(self.db.allocator);
        defer self.db.orgs.freeRows(self.db.allocator, rows);
        return rows.len;
    }

    pub fn countMembers(self: OrgRepository, org_id: u64) !usize {
        const rows = try self.db.users.all(self.db.allocator);
        defer self.db.users.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| { if (r.org_id == org_id) n += 1; }
        return n;
    }

    /// 关键字检索（名称 / 编码）。
    pub fn search(self: OrgRepository, alloc: std.mem.Allocator, keyword: []const u8) ![]Row {
        const rows = try self.db.orgs.all(alloc);
        if (keyword.len == 0) return rows;
        const util = @import("../core/util.zig");
        var out = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (util.containsIgnoreCase(r.name, keyword) or util.containsIgnoreCase(r.code, keyword)) {
                try out.append(alloc, r);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn insert(self: OrgRepository, row: Row) !u64 {
        const id = try self.db.orgs.insert(row);
        try self.db.orgs.flush();
        return id;
    }

    pub fn update(self: OrgRepository, row: Row) !bool {
        const ok = try self.db.orgs.updateById(row.id, row);
        if (ok) try self.db.orgs.flush();
        return ok;
    }

    /// 删除单个组织（调用方负责先确认没有子节点/成员）。
    pub fn delete(self: OrgRepository, id: u64) !bool {
        const ok = try self.db.orgs.deleteById(id);
        if (ok) try self.db.orgs.flush();
        return ok;
    }
};
