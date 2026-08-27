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
pub const toFieldValue = @import("query.zig").toFieldValue;
pub const getFieldValue = @import("query.zig").getFieldValue;

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
