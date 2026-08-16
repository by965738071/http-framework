//! ORM 模型定义辅助
//!
//! 提供编译期反射工具，用于从 Zig 结构体定义自动推导字段元数据。

const std = @import("std");
const schema_mod = @import("schema.zig");

const TableSchema = schema_mod.TableSchema;
const FieldDef = schema_mod.FieldDef;
const FieldType = schema_mod.FieldType;

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

/// 自动从 Zig 结构体生成 TableSchema
pub fn modelSchema(comptime T: type, comptime table_name: []const u8) TableSchema {
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct type"),
    };
    const field_names = struct_info.field_names;
    const field_types = struct_info.field_types;
    const fields = blk: {
        var arr: [field_names.len]FieldDef = undefined;
        inline for (field_names, field_types, 0..) |name, typ, i| {
            const is_id = std.mem.eql(u8, name, "id");
            arr[i] = .{
                .name = name,
                .field_type = fieldTypeOf(typ),
                .constraints = .{
                    .primary_key = is_id,
                    .auto_increment = is_id,
                    .not_null = is_id,
                },
            };
        }
        break :blk arr;
    };

    return .{
        .table_name = table_name,
        .fields = &fields,
    };
}

/// 模型辅助函数：生成模型的 Store 类型别名
pub fn Model(comptime T: type, comptime table_name: []const u8) type {
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct type"),
    };
    const field_names = struct_info.field_names;
    const field_types = struct_info.field_types;
    const engine = @import("engine.zig");

    return struct {
        const _fields: [field_names.len]FieldDef = blk: {
            var arr: [field_names.len]FieldDef = undefined;
            for (field_names, field_types, 0..) |name, typ, i| {
                const is_id = std.mem.eql(u8, name, "id");
                arr[i] = .{
                    .name = name,
                    .field_type = fieldTypeOf(typ),
                    .constraints = .{
                        .primary_key = is_id,
                        .auto_increment = is_id,
                        .not_null = is_id,
                    },
                };
            }
            break :blk arr;
        };

        pub const Schema = TableSchema{
            .table_name = table_name,
            .fields = &_fields,
        };

        pub const Store = engine.JsonStore(T, Schema);
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────────

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
