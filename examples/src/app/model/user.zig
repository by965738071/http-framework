//! 用户：ORM 行结构 + 状态机 + 对外视图。

const std = @import("std");
const framework = @import("http_framework");

pub const Status = enum { active, disabled, locked };

pub fn statusName(s: Status) []const u8 {
    return @tagName(s);
}

pub fn parseStatus(s: []const u8) ?Status {
    return std.meta.stringToEnum(Status, s);
}

/// 状态机：非法流转一律拒绝，返回原因。
///   active --禁用--> disabled --启用--> active
///   active --锁定--> locked   --解锁--> active
///   disabled <--> locked 不允许（必须先回到 active）
pub fn transitionAllowed(from: Status, to: Status) bool {
    return switch (from) {
        .active => to == .disabled or to == .locked,
        .disabled => to == .active,
        .locked => to == .active,
    };
}

pub const Row = struct {
    id: u64 = 0,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    password_hash: []const u8,
    org_id: u64 = 0,
    status: []const u8,
    failed_attempts: u64 = 0,
    /// 锁定到期时间（epoch ms），0 表示未锁定
    locked_until: u64 = 0,
    last_login_at: u64 = 0,
    created_at: u64 = 0,
    updated_at: u64 = 0,

    pub fn statusEnum(self: Row) Status {
        return parseStatus(self.status) orelse .active;
    }
};

/// 唯一性交给 ORM（`orm.ModelWith`），不再由 service 层「先查一遍再插入」——
/// 那种写法在 check 与 insert 之间有个窗口，两个并发请求能同时通过检查。
/// 冲突时 `insert` / `update` 返回 `error.UniqueViolation`，由 service 还原成
/// 契约里的 `USERNAME_TAKEN` / `EMAIL_TAKEN`（见 service/user_service.zig）。
pub const Table = framework.orm.ModelWith(Row, "users", .{
    .unique = &.{ &.{"username"}, &.{"email"} },
});
pub const Store = Table.Store;

/// 对外视图：永远不含 password_hash。
pub const View = struct {
    id: u64,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    org_id: u64,
    org_name: []const u8,
    status: []const u8,
    failed_attempts: u64,
    locked_until: u64,
    last_login_at: u64,
    created_at: u64,
    updated_at: u64,
    roles: []const RoleRef,
};

pub const RoleRef = struct {
    id: u64,
    code: []const u8,
    name: []const u8,
};

/// 参与审计 diff 的字段（`updated_at` / `password_hash` / `failed_attempts`
/// 由专门的行为记录，不进字段 diff）。
pub const diff_ignore = [_][]const u8{ "id", "password_hash", "failed_attempts", "locked_until", "updated_at", "last_login_at", "created_at" };

test "parseStatus / statusName 往返" {
    try std.testing.expectEqual(Status.active, parseStatus("active").?);
    try std.testing.expectEqual(Status.disabled, parseStatus("disabled").?);
    try std.testing.expectEqual(Status.locked, parseStatus("locked").?);
    try std.testing.expect(parseStatus("nope") == null);
    try std.testing.expectEqualStrings("locked", statusName(.locked));
}

test "用户状态机：合法流转" {
    try std.testing.expect(transitionAllowed(.active, .disabled));
    try std.testing.expect(transitionAllowed(.active, .locked));
    try std.testing.expect(transitionAllowed(.disabled, .active));
    try std.testing.expect(transitionAllowed(.locked, .active));
}

test "用户状态机：非法流转被拒" {
    try std.testing.expect(!transitionAllowed(.disabled, .locked));
    try std.testing.expect(!transitionAllowed(.locked, .disabled));
    try std.testing.expect(!transitionAllowed(.active, .active));
    try std.testing.expect(!transitionAllowed(.disabled, .disabled));
    try std.testing.expect(!transitionAllowed(.locked, .locked));
}

test {
    std.testing.refAllDecls(@This());
}
