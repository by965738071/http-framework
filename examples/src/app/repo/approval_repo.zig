//! 审批单仓储。

const std = @import("std");
const model = @import("../model/mod.zig");
const repo_mod = @import("mod.zig");

const Database = repo_mod.Database;
const Row = model.approval.Row;
const Status = model.approval.Status;

pub const ApprovalFilter = struct {
    status: []const u8 = "",
    applicant_id: ?u64 = null,
    target_user_id: ?u64 = null,
    keyword: []const u8 = "",
};

pub const ApprovalRepository = struct {
    db: *Database,

    pub fn findById(self: ApprovalRepository, alloc: std.mem.Allocator, id: u64) !?Row {
        return self.db.approvals.findById(alloc, id);
    }

    pub fn insert(self: ApprovalRepository, row: Row) !u64 {
        const id = try self.db.approvals.insert(row);
        try self.db.approvals.flush();
        return id;
    }

    pub fn update(self: ApprovalRepository, row: Row) !bool {
        const ok = try self.db.approvals.updateById(row.id, row);
        if (ok) try self.db.approvals.flush();
        return ok;
    }

    pub fn all(self: ApprovalRepository, alloc: std.mem.Allocator) ![]Row {
        return self.db.approvals.all(alloc);
    }

    pub fn search(
        self: ApprovalRepository,
        alloc: std.mem.Allocator,
        filter: ApprovalFilter,
        page: usize,
        page_size: usize,
    ) !repo_mod.SearchResult(Row) {
        const rows = try self.db.approvals.all(alloc);
        var matched = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (!matches(r, filter)) continue;
            try matched.append(alloc, r);
        }
        std.mem.reverse(Row, matched.items);
        const total = matched.items.len;
        const start = @min(page * page_size, total);
        const end = @min(start + page_size, total);
        return .{ .items = matched.items[start..end], .total = total };
    }

    /// 不分页，返回全部命中（按 id 倒序）。
    pub fn searchAll(self: ApprovalRepository, alloc: std.mem.Allocator, filter: ApprovalFilter) ![]Row {
        const rows = try self.db.approvals.all(alloc);
        var matched = std.ArrayList(Row).empty;
        for (rows) |r| {
            if (!matches(r, filter)) continue;
            try matched.append(alloc, r);
        }
        std.mem.reverse(Row, matched.items);
        return matched.toOwnedSlice(alloc);
    }

    pub fn countPending(self: ApprovalRepository) !usize {
        const rows = try self.db.approvals.all(self.db.allocator);
        defer self.db.approvals.freeRows(self.db.allocator, rows);
        var n: usize = 0;
        for (rows) |r| {
            if (std.meta.stringToEnum(Status, r.status)) |s| {
                if (s == .pending) n += 1;
            }
        }
        return n;
    }
};

fn matches(row: Row, f: ApprovalFilter) bool {
    if (f.status.len > 0 and !std.mem.eql(u8, row.status, f.status)) return false;
    if (f.applicant_id) |id| {
        if (row.applicant_id != id) return false;
    }
    if (f.target_user_id) |id| {
        if (row.target_user_id != id) return false;
    }
    if (f.keyword.len > 0) {
        const util = @import("../core/util.zig");
        const hit = util.containsIgnoreCase(row.applicant_name, f.keyword) or
            util.containsIgnoreCase(row.target_user_name, f.keyword) or
            util.containsIgnoreCase(row.role_name, f.keyword) or
            util.containsIgnoreCase(row.reason, f.keyword);
        if (!hit) return false;
    }
    return true;
}

test "approval matches 按状态与申请人过滤" {
    const row: Row = .{
        .id = 1,
        .kind = "role_change",
        .applicant_id = 3,
        .applicant_name = "bob",
        .target_user_id = 4,
        .target_user_name = "alice",
        .role_id = 2,
        .role_name = " auditor",
        .reason = "需要审计权限",
        .status = "pending",
        .reviewer_id = 0,
        .reviewer_name = "",
        .review_comment = "",
        .created_at = 1,
        .updated_at = 1,
    };
    try std.testing.expect(matches(row, .{}));
    try std.testing.expect(matches(row, .{ .status = "pending" }));
    try std.testing.expect(!matches(row, .{ .status = "approved" }));
    try std.testing.expect(matches(row, .{ .applicant_id = 3 }));
    try std.testing.expect(!matches(row, .{ .applicant_id = 9 }));
    try std.testing.expect(matches(row, .{ .target_user_id = 4 }));
    try std.testing.expect(matches(row, .{ .keyword = "audit" }));
    try std.testing.expect(!matches(row, .{ .keyword = "nope" }));
}

test {
    std.testing.refAllDecls(@This());
}
