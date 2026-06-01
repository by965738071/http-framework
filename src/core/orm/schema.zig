//! 数据库模式（Schema）定义
//!
//! 定义字段类型、约束和表结构元数据。
//! 所有类型信息在编译期可用，零运行时开销。

const std = @import("std");

/// 支持的字段数据类型
pub const FieldType = enum {
    integer,
    string,
    float,
    boolean,
    datetime,
    json_text,
    text,

    /// 返回类型的默认零值
    pub fn defaultValue(self: FieldType) FieldValue {
        return switch (self) {
            .integer => FieldValue{ .integer = 0 },
            .string => FieldValue{ .string = "" },
            .float => FieldValue{ .float = 0.0 },
            .boolean => FieldValue{ .boolean = false },
            .datetime => FieldValue{ .integer = 0 },
            .json_text => FieldValue{ .string = "" },
            .text => FieldValue{ .string = "" },
        };
    }
};

/// 字段值（支持所有字段类型的联合）
pub const FieldValue = union(FieldType) {
    integer: i64,
    string: []const u8,
    float: f64,
    boolean: bool,
    datetime: i64,
    json_text: []const u8,
    text: []const u8,
};

/// 字段约束
pub const FieldConstraints = struct {
    /// 是否为主键（自动递增整数）
    primary_key: bool = false,
    /// 是否自动递增
    auto_increment: bool = false,
    /// 是否唯一
    unique: bool = false,
    /// 是否不可为空
    not_null: bool = false,
    /// 默认值
    default_value: ?FieldValue = null,
    /// 最大长度（字符串类型）
    max_length: ?usize = null,
};

/// 单个字段的定义
pub const FieldDef = struct {
    name: []const u8,
    field_type: FieldType,
    constraints: FieldConstraints = .{},
};

/// 索引定义
pub const IndexDef = struct {
    name: []const u8,
    fields: []const []const u8,
    unique: bool = false,
};

/// 表模式定义
pub const TableSchema = struct {
    table_name: []const u8,
    fields: []const FieldDef,
    indexes: []const IndexDef = &.{},

    /// 从模式中获取主键字段名
    pub fn primaryKey(self: TableSchema) ?[]const u8 {
        for (self.fields) |f| {
            if (f.constraints.primary_key) return f.name;
        }
        return null;
    }

    /// 查找字段定义
    pub fn field(self: TableSchema, name: []const u8) ?FieldDef {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// 迁移操作类型
pub const MigrationOp = union(enum) {
    create_table: TableSchema,
    add_column: struct {
        table: []const u8,
        field: FieldDef,
    },
    drop_column: struct {
        table: []const u8,
        column_name: []const u8,
    },
    create_index: struct {
        table: []const u8,
        index: IndexDef,
    },
    drop_index: struct {
        table: []const u8,
        index_name: []const u8,
    },
    rename_table: struct {
        old_name: []const u8,
        new_name: []const u8,
    },
    raw_sql: []const u8,

    /// 获取迁移的描述标签
    pub fn label(self: MigrationOp) []const u8 {
        return switch (self) {
            .create_table => |s| std.fmt.allocPrintZ(std.heap.page_allocator, "create_table_{s}", .{s.table_name}) catch "create_table",
            .add_column => |a| std.fmt.allocPrintZ(std.heap.page_allocator, "add_column_{s}_{s}", .{ a.table, a.field.name }) catch "add_column",
            .drop_column => |d| std.fmt.allocPrintZ(std.heap.page_allocator, "drop_column_{s}_{s}", .{ d.table, d.column_name }) catch "drop_column",
            .create_index => |c| std.fmt.allocPrintZ(std.heap.page_allocator, "create_index_{s}_{s}", .{ c.table, c.index.name }) catch "create_index",
            .drop_index => |d| std.fmt.allocPrintZ(std.heap.page_allocator, "drop_index_{s}_{s}", .{ d.table, d.index_name }) catch "drop_index",
            .rename_table => |r| std.fmt.allocPrintZ(std.heap.page_allocator, "rename_table_{s}_to_{s}", .{ r.old_name, r.new_name }) catch "rename_table",
            .raw_sql => "raw_sql",
        };
    }

    pub fn deinit(self: MigrationOp) void {
        _ = self;
    }
};

/// 迁移批次
pub const Migration = struct {
    version: u32,
    description: []const u8,
    operations: []const MigrationOp,
};
