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
    const struct_info = @typeInfo(T).@"struct";
    const fields = blk: {
        var arr: [struct_info.field_names.len]FieldDef = undefined;
        inline for (struct_info.field_names, struct_info.field_types, 0..) |name, field_type, i| {
            const is_id = std.mem.eql(u8, name, "id");
            arr[i] = .{
                .name = name,
                .field_type = fieldTypeOf(field_type),
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
    const struct_info = @typeInfo(T).@"struct";
    const engine = @import("engine.zig");

    return struct {
        const _fields: [struct_info.field_names.len]FieldDef = blk: {
            var arr: [struct_info.field_names.len]FieldDef = undefined;
            for (struct_info.field_names, struct_info.field_types, 0..) |name, field_type, i| {
                const is_id = std.mem.eql(u8, name, "id");
                arr[i] = .{
                    .name = name,
                    .field_type = fieldTypeOf(field_type),
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
