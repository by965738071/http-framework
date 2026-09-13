//! 审批流：以"用户角色变更申请"为例的状态机。
//!
//! pending --approve--> approved
//! pending --reject---> rejected
//! pending --cancel---> cancelled
//! 三个终态之间不可互转，也不可回到 pending。

const std = @import("std");
const framework = @import("http_framework");

pub const Status = enum { pending, approved, rejected, cancelled };

pub fn parseStatus(s: []const u8) ?Status {
    return std.meta.stringToEnum(Status, s);
}

pub fn isTerminal(s: Status) bool {
    return s != .pending;
}

/// 合法的审批动作。
pub const Action = enum { approve, reject, cancel };

pub fn parseAction(s: []const u8) ?Action {
    return std.meta.stringToEnum(Action, s);
}

/// 流转校验：返回目标状态，非法流转返回 null。
pub fn applyAction(current: Status, action: Action) ?Status {
    if (current != .pending) return null;
    return switch (action) {
        .approve => .approved,
        .reject => .rejected,
        .cancel => .cancelled,
    };
}

pub const Kind = enum { role_change };

pub const Row = struct {
    id: u64 = 0,
    kind: []const u8,
    applicant_id: u64,
    applicant_name: []const u8,
    target_user_id: u64,
    target_user_name: []const u8,
    role_id: u64,
    role_name: []const u8,
    reason: []const u8,
    status: []const u8,
    reviewer_id: u64 = 0,
    reviewer_name: []const u8,
    review_comment: []const u8,
    created_at: u64 = 0,
    updated_at: u64 = 0,
};

pub const Table = framework.orm.Model(Row, "approvals");
pub const Store = Table.Store;

pub const View = struct {
    id: u64,
    kind: []const u8,
    applicant_id: u64,
    applicant_name: []const u8,
    target_user_id: u64,
    target_user_name: []const u8,
    role_id: u64,
    role_name: []const u8,
    reason: []const u8,
    status: []const u8,
    reviewer_id: u64,
    reviewer_name: []const u8,
    review_comment: []const u8,
    created_at: u64,
    updated_at: u64,
};

test "审批状态机：pending 可流转到三个终态" {
    try std.testing.expectEqual(Status.approved, applyAction(.pending, .approve).?);
    try std.testing.expectEqual(Status.rejected, applyAction(.pending, .reject).?);
    try std.testing.expectEqual(Status.cancelled, applyAction(.pending, .cancel).?);
}

test "审批状态机：终态不可再流转" {
    try std.testing.expect(applyAction(.approved, .approve) == null);
    try std.testing.expect(applyAction(.approved, .reject) == null);
    try std.testing.expect(applyAction(.rejected, .approve) == null);
    try std.testing.expect(applyAction(.cancelled, .cancel) == null);
}

test "isTerminal 判定" {
    try std.testing.expect(!isTerminal(.pending));
    try std.testing.expect(isTerminal(.approved));
    try std.testing.expect(isTerminal(.rejected));
    try std.testing.expect(isTerminal(.cancelled));
}

test "parseStatus / parseAction" {
    try std.testing.expectEqual(Status.pending, parseStatus("pending").?);
    try std.testing.expect(parseStatus("nope") == null);
    try std.testing.expectEqual(Action.approve, parseAction("approve").?);
    try std.testing.expect(parseAction("nope") == null);
}

test {
    std.testing.refAllDecls(@This());
}
