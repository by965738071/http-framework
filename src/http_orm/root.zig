//! `http_orm` — JSON 文件存储 ORM addon
//!
//! 零外部依赖的轻量数据持久化层，每个"表"对应一个 JSON 文件。
//! 可作为 `http_framework` 生态的独立 addon 使用，不强制依赖 `http_app`。
//!
//! # 架构
//!
//! ```
//! http_orm
//! ├── schema.zig   — 数据类型、约束、迁移定义
//! ├── query.zig    — 查询构建器（WHERE/ORDER/LIMIT/OFFSET）
//! ├── engine.zig   — JSON 文件存储引擎（CRUD 实现）
//! └── model.zig    — 模型定义辅助（编译期反射推导表结构）
//! ```
//!
//! # Flush 策略（重要）
//!
//! `insert`/`update`/`delete`/`truncate` 只更新内存并标记 `dirty = true`，
//! **不会**每步落盘——批量操作成本是 O(N) 写盘而不是 O(K*N)。
//! 持久化时机由调用方控制：
//!   1. 显式调用 `store.flush()` 做 checkpoint；
//!   2. `store.close()` 退出时自动 flush 一次。
//!
//! 在 HTTP handler 场景下：请求级 store 在 `defer store.close()` 里统一落盘；
//! 长生命周期 store 用 `flush()` 周期性 checkpoint。
//!
//! # 快速开始
//!
//! ```zig
//! const orm = @import("http_orm");
//!
//! // 1. 定义模型
//! const User = struct {
//!     id: u64 = 0,
//!     username: []const u8,
//!     email: []const u8,
//!     role: []const u8 = "user",
//! };
//!
//! // 2. 生成 Store
//! const UserModel = orm.Model(User, "users");
//! const UserStore = UserModel.Store;
//!
//! // 3. 打开数据库（需传入 std.Io）
//! var store = try UserStore.open(allocator, io, "./data");
//! defer store.close() catch |err| std.log.err("store close failed: {}", .{err});
//!
//! // 4. CRUD
//! const id = try store.insert(.{ .id = 0, .username = "alice", .email = "alice@example.com" });
//!
//! var qb = orm.Query(User).init(allocator);
//! defer qb.deinit();
//! const user = try store.findOne(qb.where(.Eq, "username", .{ .string = "alice" }));
//! ```
//!
//! # 声明唯一约束
//!
//! `Model()` 只把 `id` 标成主键，其余字段**没有**唯一约束。要「用户名唯一」用
//! `ModelWith`（`modelSchemaWith` 是它对应的 schema 版本）：
//!
//! ```zig
//! const UserModel = orm.ModelWith(User, "users", .{
//!     .unique = &.{ &.{"username"}, &.{ "org_id", "email" } },
//! });
//! ```
//!
//! 每一组字段的组合值不得重复；单字段组走 `FieldConstraints.unique`，多字段组走
//! `IndexDef{ .unique = true }`（即 SQL 的 unique index）。冲突时 `insert` /
//! `update` 返回 `error.UniqueViolation`。字段名拼错是**编译期错误**，不会静默失效。
//! optional 字段为 `null` 的行不参与比较（SQL 语义：多行 NULL 合法）。

pub const Schema = @import("schema.zig");
pub const Query = @import("query.zig").QueryBuilder;
pub const Engine = @import("engine.zig");
pub const Model = @import("model.zig").Model;

// 重新导出常用类型，方便外部使用
pub const TableSchema = Schema.TableSchema;
pub const FieldDef = Schema.FieldDef;
pub const FieldType = Schema.FieldType;
pub const FieldValue = Schema.FieldValue;
pub const FieldConstraints = Schema.FieldConstraints;
pub const Migration = Schema.Migration;
pub const MigrationOp = Schema.MigrationOp;

pub const Operator = @import("query.zig").Operator;
pub const SortDirection = @import("query.zig").SortDirection;
pub const WhereCondition = @import("query.zig").WhereCondition;

pub const JsonStore = Engine.JsonStore;
pub const modelSchema = @import("model.zig").modelSchema;
pub const modelSchemaWith = @import("model.zig").modelSchemaWith;
pub const ModelWith = @import("model.zig").ModelWith;
pub const ModelOptions = @import("model.zig").ModelOptions;
pub const toFieldValue = @import("query.zig").toFieldValue;
pub const getFieldValue = @import("query.zig").getFieldValue;
pub const isFieldNull = @import("query.zig").isFieldNull;

test {
    @import("std").testing.refAllDecls(@This());
}

// ── 测试 ──────────────────────────────────────────

test "ORM persistence - data survives reopen" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const User = struct {
        id: u64 = 0,
        name: []const u8,
        age: u32,
    };

    const UserModel = Model(User, "orm_persist_test");
    const Store = UserModel.Store;

    // Use arena to avoid tracking string allocs from json deserialization
    var arena = std_testing.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const store_alloc = arena.allocator();

    // Step 1: Open, insert, close
    {
        var store = try Store.open(store_alloc, io, ".test_data");
        defer {
            store.close() catch {};
        }
        _ = try store.insert(.{ .id = 0, .name = "Alice", .age = 30 });
        _ = try store.insert(.{ .id = 0, .name = "Bob", .age = 25 });
    }

    // Step 2: Reopen and verify data survived
    {
        var store = try Store.open(store_alloc, io, ".test_data");
        defer {
            store.truncate() catch {};
            store.close() catch {};
        }

        var qb = Query(User).init(allocator);
        defer qb.deinit();
        const all = try store.findAll(store_alloc, &qb);
        // Arena owns the allocation, no need to free

        try std_testing.testing.expectEqual(@as(usize, 2), all.len);
        if (all.len > 0) {
            try std_testing.testing.expectEqualStrings("Alice", all[0].name);
        }

        const cnt = try store.count(&qb);
        try std_testing.testing.expectEqual(@as(usize, 2), cnt);
    }
}

test "ORM 唯一约束：重复插入被拒 / 不同值可插 / 删后可重插（F-01）" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const User = struct {
        id: u64 = 0,
        username: []const u8,
        email: []const u8,
    };
    const UserModel = ModelWith(User, "orm_uniq_crud", .{ .unique = &.{ &.{"username"} } });
    const Store = UserModel.Store;

    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    // 不同值正常插入
    const alice = try store.insert(.{ .id = 0, .username = "alice", .email = "a@x.com" });
    _ = try store.insert(.{ .id = 0, .username = "bob", .email = "b@x.com" });
    try std_testing.testing.expectEqual(@as(u64, 1), alice);

    // 重复插入被拒，且是专门的、可与其它错误区分的 error
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .username = "alice", .email = "other@x.com" }),
    );
    // 被拒的插入不能推进自增 id，也不能留下半条记录
    var qc = Query(User).init(allocator);
    defer qc.deinit();
    try std_testing.testing.expectEqual(@as(usize, 2), try store.count(&qc));

    // 更新自身（整行替换，username 未改）不应误报重复
    {
        var row = (try store.findById(allocator, alice)).?;
        defer store.freeRow(allocator, row);
        // findById 返回的行字符串由 allocator 拥有，换掉之前必须先释放旧值
        allocator.free(row.email);
        row.email = try allocator.dupe(u8, "changed@x.com");
        try std_testing.testing.expect(try store.updateById(alice, row));
    }
    // 部分更新（只改 email）也不应误报
    {
        var qb = Query(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(alice) });
        _ = qb.update(.{ .id = alice, .username = "alice", .email = "partial@x.com" }, &.{"email"});
        try std_testing.testing.expectEqual(@as(usize, 1), try store.update(&qb));
    }

    // 改成别人的 username → 报重复（且这次更新不生效）
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.updateById(alice, .{ .id = alice, .username = "bob", .email = "b@x.com" }),
    );
    {
        const row = (try store.findById(allocator, alice)).?;
        defer store.freeRow(allocator, row);
        try std_testing.testing.expectEqualStrings("alice", row.username);
        try std_testing.testing.expectEqualStrings("partial@x.com", row.email);
    }

    // 删除后可以重新插入同名
    try std_testing.testing.expect(try store.deleteById(alice));
    const reinserted = try store.insert(.{ .id = 0, .username = "alice", .email = "a@x.com" });
    try std_testing.testing.expect(reinserted > 0);
}

test "ORM 联合唯一：(org_id, email) 组合重复才拒绝（F-01）" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const Member = struct {
        id: u64 = 0,
        org_id: u64 = 0,
        email: []const u8,
    };
    const M = ModelWith(Member, "orm_uniq_composite", .{ .unique = &.{ &.{ "org_id", "email" } } });
    const Store = M.Store;

    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const m1 = try store.insert(.{ .id = 0, .org_id = 1, .email = "a@x.com" });
    // 同 org 不同 email → OK
    _ = try store.insert(.{ .id = 0, .org_id = 1, .email = "b@x.com" });
    // 不同 org 同 email → OK
    _ = try store.insert(.{ .id = 0, .org_id = 2, .email = "a@x.com" });
    // 同 org 同 email → 拒绝
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .org_id = 1, .email = "a@x.com" }),
    );

    // 更新自身（组合未变）不误报
    {
        var qb = Query(Member).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(m1) });
        _ = qb.update(.{ .id = m1, .org_id = 1, .email = "a@x.com" }, &.{"email"});
        try std_testing.testing.expectEqual(@as(usize, 1), try store.update(&qb));
    }
    // 把 (1,a) 改成已存在的 (2,a) 是允许的（组合变了但不冲突）
    {
        var qb = Query(Member).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(m1) });
        _ = qb.update(.{ .id = m1, .org_id = 2, .email = "b@x.com" }, &.{ "org_id", "email" });
        try std_testing.testing.expectEqual(@as(usize, 1), try store.update(&qb));
    }
    // 改成一个已存在的组合 → 拒绝
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.updateById(m1, .{ .id = m1, .org_id = 2, .email = "a@x.com" }),
    );
}

test "ORM 唯一约束：NULL 不参与比较（SQL 语义）" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const Item = struct {
        id: u64 = 0,
        code: ?[]const u8,
    };
    const M = ModelWith(Item, "orm_uniq_null", .{ .unique = &.{ &.{"code"} } });
    const Store = M.Store;

    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    // 多行 NULL 合法
    _ = try store.insert(.{ .id = 0, .code = null });
    _ = try store.insert(.{ .id = 0, .code = null });
    // 非 NULL 重复 → 拒绝
    _ = try store.insert(.{ .id = 0, .code = "X" });
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .code = "X" }),
    );
}

test "ORM 唯一约束：非字符串类型（int / float / bool）" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const Rec = struct {
        id: u64 = 0,
        rank: u32 = 0,
        score: f64 = 0,
        active: bool = false,
    };
    const M = ModelWith(Rec, "orm_uniq_types", .{ .unique = &.{ &.{"rank"}, &.{"score"}, &.{"active"} } });
    const Store = M.Store;

    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .rank = 7, .score = 1.5, .active = true });
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .rank = 7, .score = 9.9, .active = false }),
    );
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .rank = 8, .score = 1.5, .active = false }),
    );
    // bool 只有两个取值，第二行必然与第一行撞
    try std_testing.testing.expectError(
        error.UniqueViolation,
        store.insert(.{ .id = 0, .rank = 8, .score = 9.9, .active = true }),
    );
    // 全部不同 → 通过
    _ = try store.insert(.{ .id = 0, .rank = 8, .score = 9.9, .active = false });
}

test "ORM integration - full CRUD lifecycle" {
    const std_testing = @import("std");
    const allocator = std_testing.testing.allocator;
    const io = std_testing.testing.io;

    const User = struct {
        id: u64 = 0,
        name: []const u8,
        age: u32,
    };

    const UserModel = Model(User, "orm_test_users");
    const Store = UserModel.Store;
    _ = UserModel.Schema;
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    // Insert
    const id1 = try store.insert(.{ .id = 0, .name = "Alice", .age = 30 });
    const id2 = try store.insert(.{ .id = 0, .name = "Bob", .age = 25 });
    try std_testing.testing.expect(id1 != id2);

    // FindAll with sorting
    var qb = Query(User).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("age", .Asc);
    const all = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, all);
    try std_testing.testing.expectEqual(@as(usize, 2), all.len);
    try std_testing.testing.expectEqual(@as(u32, 25), all[0].age);
    try std_testing.testing.expectEqual(@as(u32, 30), all[1].age);

    // Count
    var qc = Query(User).init(allocator);
    defer qc.deinit();
    const cnt = try store.count(&qc);
    try std_testing.testing.expectEqual(@as(usize, 2), cnt);
}
