//! ORM 模型定义辅助
//!
//! 提供编译期反射工具，用于从 Zig 结构体定义自动推导字段元数据。

const std = @import("std");
const schema_mod = @import("schema.zig");

const TableSchema = schema_mod.TableSchema;
const FieldDef = schema_mod.FieldDef;
const FieldType = schema_mod.FieldType;
const IndexDef = schema_mod.IndexDef;

/// 从 Zig 类型推导 ORM 字段类型
pub fn fieldTypeOf(comptime T: type) FieldType {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .integer,
        .float, .comptime_float => .float,
        .bool => .boolean,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return .string;
            @compileError("Unsupported pointer type for field: " ++ @typeName(T));
        },
        .optional => fieldTypeOf(std.meta.Child(T)),
        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    };
}

/// 模型约束声明（传给 `ModelWith` / `modelSchemaWith` 的第三个参数）。
///
/// 设计权衡：约束走「编译期值」而不是字段包装类型（`Unique([]const u8)` 之类）。
/// 包装类型会让行结构体的字段变成另一个类型，`store.insert(.{ .username = "a" })`
/// 的字面量、JSON 反序列化、`@field` 读取全都要跟着改一遍——对一个已经跑着 8 张
/// 表的业务来说代价太大。代价是约束与字段声明分处两地（写在 `ModelWith` 的第三
/// 个参数，而不是贴在字段旁边），换来的是对现有 `Model(T, name)` 用法零侵入。
pub const ModelOptions = struct {
    /// 唯一约束组。每个元素是**一组**字段名，组内字段的**组合值**不得重复：
    /// - `&.{"username"}` → username 单字段唯一
    /// - `&.{ "org_id", "email" }` → (org_id, email) 联合唯一
    ///
    /// 因为类型是切片（不是元组），每层都要写 `&.`；漏写会在编译期被类型检查挡住。
    ///
    /// 单字段组落到 `FieldConstraints.unique`（引擎里既有的单字段校验路径），
    /// 多字段组落到 `IndexDef{ .unique = true }`（即 SQL 的 unique index）。
    /// 之所以分两类表示、而不是统一成 index：引擎已经支持手写 schema 里直接标
    /// `constraints.unique = true`，统一成 index 会让那条既有路径失效。
    unique: []const []const []const u8 = &.{},
};

fn fieldCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names.len,
        else => @compileError("expected struct type"),
    };
}

fn isSingleUniqueField(comptime opts: ModelOptions, comptime name: []const u8) bool {
    for (opts.unique) |group| {
        if (group.len == 1 and std.mem.eql(u8, group[0], name)) return true;
    }
    return false;
}

fn compositeGroupCount(comptime opts: ModelOptions) usize {
    var n: usize = 0;
    for (opts.unique) |group| {
        if (group.len > 1) n += 1;
    }
    return n;
}

/// 生成联合唯一索引名。名字只在 `MigrationOp.label` 里被人读到，没有唯一性要求，
/// 但拼一个可读的名字（`uniq_users_org_id_email`）比 `idx0` 强得多——它是唯一会
/// 泄露给使用者的内部标识，出问题时日志里能直接看懂是哪条约束。
fn uniqueIndexName(comptime table_name: []const u8, comptime fields: []const []const u8) []const u8 {
    const n = comptime blk: {
        var len: usize = "uniq_".len + table_name.len;
        for (fields) |f| len += 1 + f.len;
        break :blk len;
    };
    comptime {
        var buf: [n]u8 = undefined;
        var i: usize = 0;
        @memcpy(buf[i..][0.."uniq_".len], "uniq_");
        i += "uniq_".len;
        @memcpy(buf[i..][0..table_name.len], table_name);
        i += table_name.len;
        for (fields) |f| {
            buf[i] = '_';
            i += 1;
            @memcpy(buf[i..][0..f.len], f);
            i += f.len;
        }
        const out = buf;
        return &out;
    }
}

/// 编译期校验唯一约束声明：字段名必须真实存在于 `T`。
///
/// 为什么必须硬失败：字段名拼错（typo、或重构改了 Row 的字段名）时静默忽略，
/// 会让「以为加了唯一约束、其实一条都没生效」——这正是 F-01 的原始症状，只是把
/// 失效原因从「没有入口」换成了「名字拼错」。静默错误的代价远大于编译失败。
fn validateUniqueGroups(comptime T: type, comptime opts: ModelOptions) void {
    for (opts.unique) |group| {
        if (group.len == 0) @compileError("ModelOptions.unique: 空的唯一约束组");
        for (group) |name| {
            if (!@hasField(T, name)) {
                @compileError("ModelOptions.unique: 字段 '" ++ name ++ "' 不存在");
            }
        }
    }
}

fn buildFields(comptime T: type, comptime opts: ModelOptions) [fieldCount(T)]FieldDef {
    const struct_info = @typeInfo(T).@"struct";
    var arr: [struct_info.field_names.len]FieldDef = undefined;
    for (struct_info.field_names, struct_info.field_types, 0..) |name, typ, i| {
        const is_id = std.mem.eql(u8, name, "id");
        arr[i] = .{
            .name = name,
            .field_type = fieldTypeOf(typ),
            .constraints = .{
                .primary_key = is_id,
                .auto_increment = is_id,
                .not_null = is_id,
                .unique = isSingleUniqueField(opts, name),
            },
        };
    }
    return arr;
}

fn buildUniqueIndexes(comptime table_name: []const u8, comptime opts: ModelOptions) [compositeGroupCount(opts)]IndexDef {
    var arr: [compositeGroupCount(opts)]IndexDef = undefined;
    var i: usize = 0;
    for (opts.unique) |group| {
        if (group.len == 1) continue;
        arr[i] = .{ .name = uniqueIndexName(table_name, group), .fields = group, .unique = true };
        i += 1;
    }
    return arr;
}

/// 承载一个模型的 schema 静态数据。
///
/// 字段数组必须放在**容器级 `const`**：容器级 const 天然是静态存储，`&fields`
/// 的生命周期等于程序生命周期。函数局部的 `const`（哪怕包在 `comptime blk:` 里）
/// 交出去的切片没有这个保证——`modelSchema()` 原先就是这么写的，只能靠
/// 「所有调用点都写 `comptime modelSchema(...)`」侥幸不炸（F-25）。
fn SchemaStorage(comptime T: type, comptime table_name: []const u8, comptime opts: ModelOptions) type {
    comptime validateUniqueGroups(T, opts);
    return struct {
        pub const fields: [fieldCount(T)]FieldDef = buildFields(T, opts);
        pub const indexes: [compositeGroupCount(opts)]IndexDef = buildUniqueIndexes(table_name, opts);
        pub const schema: TableSchema = .{
            .table_name = table_name,
            .fields = &fields,
            .indexes = &indexes,
        };
    };
}

/// 自动从 Zig 结构体生成 TableSchema（不声明任何约束）。
///
/// 返回值的 `fields` / `indexes` 指向 comptime 静态存储，运行期调用同样安全。
pub fn modelSchema(comptime T: type, comptime table_name: []const u8) TableSchema {
    return modelSchemaWith(T, table_name, .{});
}

/// 带约束声明的 schema 生成。`opts.unique` 里的每一组字段会变成一条唯一约束。
pub fn modelSchemaWith(comptime T: type, comptime table_name: []const u8, comptime opts: ModelOptions) TableSchema {
    return SchemaStorage(T, table_name, opts).schema;
}

/// 模型辅助函数：生成模型的 Store 类型别名
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    return ModelWith(T, table_name, .{});
}

/// 带约束声明的模型。用法：
/// ```zig
/// const UserModel = orm.ModelWith(User, "users", .{
///     .unique = &.{ &.{"username"}, &.{ "org_id", "email" } },
/// });
/// ```
/// 冲突时 `insert` / `update` 返回 `error.UniqueViolation`；字段名为 NULL（optional
/// 字段且值为 null）的行不参与比较，与 SQL 的 UNIQUE 语义一致。
pub fn ModelWith(comptime T: type, comptime table_name: []const u8, comptime opts: ModelOptions) type {
    const storage = SchemaStorage(T, table_name, opts);
    const engine = @import("engine.zig");

    return struct {
        pub const Schema = storage.schema;

        pub const Store = engine.JsonStore(T, storage.schema);
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────────

/// 递归把栈写成垃圾。用来暴露「返回了指向已销毁栈帧的切片」：
/// 悬垂指针指向的那段内存在函数返回后会被后续调用覆盖成 0xAB。
noinline fn clobberStack(depth: usize) void {
    if (depth == 0) return;
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0xAB);
    std.mem.doNotOptimizeAway(&buf);
    clobberStack(depth - 1);
}

test "fieldTypeOf maps unsigned integer types to .integer" {
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(u32));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(u8));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(u16));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(u64));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(u128));
}

test "fieldTypeOf maps signed integer types to .integer" {
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(i32));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(i8));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(i16));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(i64));
}

test "fieldTypeOf maps float types to .float" {
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(f32));
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(f64));
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(f16));
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(f128));
}

test "fieldTypeOf maps bool to .boolean" {
    try std.testing.expectEqual(FieldType.boolean, fieldTypeOf(bool));
}

test "fieldTypeOf maps []const u8 to .string" {
    try std.testing.expectEqual(FieldType.string, fieldTypeOf([]const u8));
}

test "fieldTypeOf unwraps optional integer to .integer" {
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(?u32));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(?i64));
    try std.testing.expectEqual(FieldType.integer, fieldTypeOf(?u8));
}

test "fieldTypeOf unwraps optional float to .float" {
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(?f32));
    try std.testing.expectEqual(FieldType.float, fieldTypeOf(?f64));
}

test "fieldTypeOf unwraps optional bool to .boolean" {
    try std.testing.expectEqual(FieldType.boolean, fieldTypeOf(?bool));
}

test "fieldTypeOf unwraps optional string to .string" {
    try std.testing.expectEqual(FieldType.string, fieldTypeOf(?[]const u8));
}

test "modelSchema generates correct table_name" {
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const schema = comptime modelSchema(User, "users");
    try std.testing.expectEqualStrings("users", schema.table_name);
}

test "modelSchema generates correct number of fields" {
    const TwoField = struct {
        id: u64,
        name: []const u8,
    };
    try std.testing.expectEqual(@as(usize, 2), comptime modelSchema(TwoField, "t").fields.len);

    const ThreeField = struct {
        a: u32,
        b: bool,
        c: f64,
    };
    try std.testing.expectEqual(@as(usize, 3), comptime modelSchema(ThreeField, "t").fields.len);

    const SingleField = struct {
        value: u32,
    };
    try std.testing.expectEqual(@as(usize, 1), comptime modelSchema(SingleField, "t").fields.len);
}

test "modelSchema sets id field as primary_key, auto_increment, and not_null" {
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const schema = comptime modelSchema(User, "users");
    const id_field = comptime schema.field("id").?;
    try std.testing.expectEqual(true, id_field.constraints.primary_key);
    try std.testing.expectEqual(true, id_field.constraints.auto_increment);
    try std.testing.expectEqual(true, id_field.constraints.not_null);
}

test "modelSchema sets non-id fields with default constraints" {
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };
    const schema = comptime modelSchema(User, "users");
    const name_field = comptime schema.field("name").?;
    try std.testing.expectEqual(false, name_field.constraints.primary_key);
    try std.testing.expectEqual(false, name_field.constraints.auto_increment);
    try std.testing.expectEqual(false, name_field.constraints.not_null);

    const email_field = comptime schema.field("email").?;
    try std.testing.expectEqual(false, email_field.constraints.primary_key);
}

test "modelSchema infers field types correctly" {
    const Mixed = struct {
        id: u64,
        name: []const u8,
        score: f64,
        active: bool,
    };
    const schema = comptime modelSchema(Mixed, "mixed");
    try std.testing.expectEqual(FieldType.integer, comptime schema.field("id").?.field_type);
    try std.testing.expectEqual(FieldType.string, comptime schema.field("name").?.field_type);
    try std.testing.expectEqual(FieldType.float, comptime schema.field("score").?.field_type);
    try std.testing.expectEqual(FieldType.boolean, comptime schema.field("active").?.field_type);
}

test "modelSchema field names match struct field names" {
    const Record = struct {
        id: u64,
        first_name: []const u8,
        last_name: []const u8,
        is_admin: bool,
    };
    const schema = comptime modelSchema(Record, "records");
    try std.testing.expectEqualStrings("id", comptime schema.fields[0].name);
    try std.testing.expectEqualStrings("first_name", comptime schema.fields[1].name);
    try std.testing.expectEqualStrings("last_name", comptime schema.fields[2].name);
    try std.testing.expectEqualStrings("is_admin", comptime schema.fields[3].name);
}

test "modelSchema without id field has no primary key" {
    const NoId = struct {
        name: []const u8,
        value: u32,
    };
    const schema = comptime modelSchema(NoId, "no_ids");
    inline for (schema.fields) |f| {
        try std.testing.expectEqual(false, f.constraints.primary_key);
        try std.testing.expectEqual(false, f.constraints.auto_increment);
        try std.testing.expectEqual(false, f.constraints.not_null);
    }
}

test "modelSchema with optional field type" {
    const WithOptional = struct {
        id: u64,
        nickname: ?[]const u8,
        age: ?u32,
    };
    const schema = comptime modelSchema(WithOptional, "optional_test");
    try std.testing.expectEqual(FieldType.string, comptime schema.field("nickname").?.field_type);
    try std.testing.expectEqual(FieldType.integer, comptime schema.field("age").?.field_type);
}

test "Model.Schema has correct table_name" {
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const M = Model(User, "users");
    try std.testing.expectEqualStrings("users", M.Schema.table_name);
}

test "Model.Schema has correct number of fields" {
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };
    const M = Model(User, "users");
    try std.testing.expectEqual(@as(usize, 3), M.Schema.fields.len);
}

test "Model.Schema id field has primary key constraints" {
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const M = Model(User, "users");
    const id_field = M.Schema.field("id").?;
    try std.testing.expectEqual(true, id_field.constraints.primary_key);
    try std.testing.expectEqual(true, id_field.constraints.auto_increment);
    try std.testing.expectEqual(true, id_field.constraints.not_null);
}

test "Model.Schema field types are correctly inferred" {
    const Item = struct {
        id: u64,
        label: []const u8,
        price: f64,
        in_stock: bool,
    };
    const M = Model(Item, "items");
    try std.testing.expectEqual(FieldType.integer, M.Schema.field("id").?.field_type);
    try std.testing.expectEqual(FieldType.string, M.Schema.field("label").?.field_type);
    try std.testing.expectEqual(FieldType.float, M.Schema.field("price").?.field_type);
    try std.testing.expectEqual(FieldType.boolean, M.Schema.field("in_stock").?.field_type);
}

test "modelSchema 运行期调用不返回悬垂切片（F-25 回归）" {
    const Rec = struct {
        id: u64,
        name: []const u8,
        score: f64,
        active: bool,
    };

    // 关键：**不加 comptime**。旧实现用函数局部数组，`comptime modelSchema(...)`
    // 会在编译期取值从而绕过栈帧销毁，文件里所有测试都这么写，正好把 bug 掩盖了。
    const schema = modelSchema(Rec, "recs");
    clobberStack(64);

    try std.testing.expectEqual(@as(usize, 4), schema.fields.len);
    try std.testing.expectEqualStrings("id", schema.fields[0].name);
    try std.testing.expectEqualStrings("name", schema.fields[1].name);
    try std.testing.expectEqualStrings("score", schema.fields[2].name);
    try std.testing.expectEqualStrings("active", schema.fields[3].name);
    try std.testing.expectEqual(FieldType.string, schema.fields[1].field_type);
    try std.testing.expectEqual(FieldType.float, schema.fields[2].field_type);
    try std.testing.expectEqual(FieldType.boolean, schema.fields[3].field_type);
    try std.testing.expectEqual(true, schema.fields[0].constraints.primary_key);

    // 静态存储：同一 T 的两次调用必须指向同一块内存（栈数组则必然不同或已失效）
    const again = modelSchema(Rec, "recs");
    try std.testing.expectEqual(schema.fields.ptr, again.fields.ptr);
}

test "modelSchemaWith 运行期调用同样安全" {
    const Rec = struct {
        id: u64,
        username: []const u8,
        org_id: u64,
    };
    const schema = modelSchemaWith(Rec, "recs", .{ .unique = &.{ &.{"username"} } });
    clobberStack(64);
    try std.testing.expectEqual(true, schema.field("username").?.constraints.unique);
    try std.testing.expectEqualStrings("recs", schema.table_name);
}

test "ModelWith 声明单字段唯一" {
    const U = struct {
        id: u64 = 0,
        username: []const u8,
        email: []const u8,
    };
    const M = ModelWith(U, "users", .{ .unique = &.{ &.{"username"} } });
    try std.testing.expectEqual(true, M.Schema.field("username").?.constraints.unique);
    try std.testing.expectEqual(false, M.Schema.field("email").?.constraints.unique);
    // id 仍然照旧是主键
    try std.testing.expectEqual(true, M.Schema.field("id").?.constraints.primary_key);
    // 单字段唯一不额外生成 index（走引擎既有的字段级路径）
    try std.testing.expectEqual(@as(usize, 0), M.Schema.indexes.len);
}

test "ModelWith 声明联合唯一" {
    const U = struct {
        id: u64 = 0,
        org_id: u64 = 0,
        email: []const u8,
    };
    const M = ModelWith(U, "users", .{ .unique = &.{ &.{ "org_id", "email" } } });
    // 联合组**不**标 field-level unique：否则单字段校验会拒掉「同 org 不同 email」
    try std.testing.expectEqual(false, M.Schema.field("org_id").?.constraints.unique);
    try std.testing.expectEqual(false, M.Schema.field("email").?.constraints.unique);

    try std.testing.expectEqual(@as(usize, 1), M.Schema.indexes.len);
    try std.testing.expectEqual(true, M.Schema.indexes[0].unique);
    try std.testing.expectEqualStrings("uniq_users_org_id_email", M.Schema.indexes[0].name);
    try std.testing.expectEqualStrings("org_id", M.Schema.indexes[0].fields[0]);
    try std.testing.expectEqualStrings("email", M.Schema.indexes[0].fields[1]);
}

test "ModelWith 同时声明单字段与联合唯一" {
    const U = struct {
        id: u64 = 0,
        org_id: u64 = 0,
        username: []const u8,
    };
    const M = ModelWith(U, "users", .{ .unique = &.{ &.{"username"}, &.{ "org_id", "username" } } });
    try std.testing.expectEqual(true, M.Schema.field("username").?.constraints.unique);
    try std.testing.expectEqual(@as(usize, 1), M.Schema.indexes.len);
    try std.testing.expectEqualStrings("uniq_users_org_id_username", M.Schema.indexes[0].name);
}

test "Model 与不带约束的 ModelWith 完全等价（向后兼容）" {
    const U = struct {
        id: u64 = 0,
        username: []const u8,
    };
    const A = Model(U, "users");
    const B = ModelWith(U, "users", .{});
    try std.testing.expectEqualStrings(A.Schema.table_name, B.Schema.table_name);
    try std.testing.expectEqual(A.Schema.fields.len, B.Schema.fields.len);
    for (B.Schema.fields) |f| {
        try std.testing.expectEqual(false, f.constraints.unique);
    }
    try std.testing.expectEqual(@as(usize, 0), B.Schema.indexes.len);
}

test "Model.Store type exists and can be instantiated" {
    const User = struct {
        id: u64,
        name: []const u8,
    };
    const M = Model(User, "test_model_store");
    const io = std.testing.io;
    var store = try M.Store.open(std.testing.allocator, io, ".test_model_store_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }
    try std.testing.expectEqualStrings("test_model_store", store.table_name);
}
