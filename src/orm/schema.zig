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
            .create_table => |s| std.fmt.allocPrintSentinel(std.heap.page_allocator, "create_table_{s}", .{s.table_name}, 0) catch "create_table",
            .add_column => |a| std.fmt.allocPrintSentinel(std.heap.page_allocator, "add_column_{s}_{s}", .{ a.table, a.field.name }, 0) catch "add_column",
            .drop_column => |d| std.fmt.allocPrintSentinel(std.heap.page_allocator, "drop_column_{s}_{s}", .{ d.table, d.column_name }, 0) catch "drop_column",
            .create_index => |c| std.fmt.allocPrintSentinel(std.heap.page_allocator, "create_index_{s}_{s}", .{ c.table, c.index.name }, 0) catch "create_index",
            .drop_index => |d| std.fmt.allocPrintSentinel(std.heap.page_allocator, "drop_index_{s}_{s}", .{ d.table, d.index_name }, 0) catch "drop_index",
            .rename_table => |r| std.fmt.allocPrintSentinel(std.heap.page_allocator, "rename_table_{s}_to_{s}", .{ r.old_name, r.new_name }, 0) catch "rename_table",
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

// ── Tests ───────────────────────────────────────────────────────────────────────

test "FieldType.defaultValue returns zero values for all variants" {
    // integer
    {
        const val = FieldType.integer.defaultValue();
        try std.testing.expectEqual(@as(i64, 0), val.integer);
    }
    // string
    {
        const val = FieldType.string.defaultValue();
        try std.testing.expectEqualStrings("", val.string);
    }
    // float
    {
        const val = FieldType.float.defaultValue();
        try std.testing.expectEqual(@as(f64, 0.0), val.float);
    }
    // boolean
    {
        const val = FieldType.boolean.defaultValue();
        try std.testing.expectEqual(false, val.boolean);
    }
    // datetime (backed by integer)
    {
        const val = FieldType.datetime.defaultValue();
        try std.testing.expectEqual(@as(i64, 0), val.integer);
    }
    // json_text (backed by string)
    {
        const val = FieldType.json_text.defaultValue();
        try std.testing.expectEqualStrings("", val.string);
    }
    // text (backed by string)
    {
        const val = FieldType.text.defaultValue();
        try std.testing.expectEqualStrings("", val.string);
    }
}

test "FieldValue union construction and access" {
    const int_val = FieldValue{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);

    const str_val = FieldValue{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", str_val.string);

    const float_val = FieldValue{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), float_val.float);

    const bool_val = FieldValue{ .boolean = true };
    try std.testing.expectEqual(true, bool_val.boolean);

    const dt_val = FieldValue{ .datetime = 1700000000 };
    try std.testing.expectEqual(@as(i64, 1700000000), dt_val.datetime);

    const json_val = FieldValue{ .json_text = "{\"k\":1}" };
    try std.testing.expectEqualStrings("{\"k\":1}", json_val.json_text);

    const text_val = FieldValue{ .text = "long text" };
    try std.testing.expectEqualStrings("long text", text_val.text);
}

test "FieldConstraints default values" {
    const c = FieldConstraints{};
    try std.testing.expectEqual(false, c.primary_key);
    try std.testing.expectEqual(false, c.auto_increment);
    try std.testing.expectEqual(false, c.unique);
    try std.testing.expectEqual(false, c.not_null);
    try std.testing.expectEqual(@as(?FieldValue, null), c.default_value);
    try std.testing.expectEqual(@as(?usize, null), c.max_length);
}

test "FieldConstraints custom values" {
    const c = FieldConstraints{
        .primary_key = true,
        .auto_increment = true,
        .unique = true,
        .not_null = true,
        .default_value = FieldValue{ .integer = 0 },
        .max_length = 255,
    };
    try std.testing.expectEqual(true, c.primary_key);
    try std.testing.expectEqual(true, c.auto_increment);
    try std.testing.expectEqual(true, c.unique);
    try std.testing.expectEqual(true, c.not_null);
    try std.testing.expect(c.default_value != null);
    try std.testing.expectEqual(@as(i64, 0), c.default_value.?.integer);
    try std.testing.expectEqual(@as(usize, 255), c.max_length.?);
}

test "FieldDef construction with default constraints" {
    const fd = FieldDef{
        .name = "id",
        .field_type = .integer,
    };
    try std.testing.expectEqualStrings("id", fd.name);
    try std.testing.expectEqual(FieldType.integer, fd.field_type);
    try std.testing.expectEqual(false, fd.constraints.primary_key);
    try std.testing.expectEqual(false, fd.constraints.not_null);
}

test "FieldDef construction with custom constraints" {
    const fd = FieldDef{
        .name = "email",
        .field_type = .string,
        .constraints = .{
            .unique = true,
            .not_null = true,
            .max_length = 128,
        },
    };
    try std.testing.expectEqualStrings("email", fd.name);
    try std.testing.expectEqual(FieldType.string, fd.field_type);
    try std.testing.expectEqual(true, fd.constraints.unique);
    try std.testing.expectEqual(true, fd.constraints.not_null);
    try std.testing.expectEqual(@as(usize, 128), fd.constraints.max_length.?);
}

test "IndexDef construction" {
    const idx = IndexDef{
        .name = "idx_user_email",
        .fields = &.{ "email", "username" },
        .unique = true,
    };
    try std.testing.expectEqualStrings("idx_user_email", idx.name);
    try std.testing.expectEqual(@as(usize, 2), idx.fields.len);
    try std.testing.expectEqualStrings("email", idx.fields[0]);
    try std.testing.expectEqualStrings("username", idx.fields[1]);
    try std.testing.expectEqual(true, idx.unique);
}

test "IndexDef defaults to non-unique" {
    const idx = IndexDef{
        .name = "idx_created",
        .fields = &.{"created_at"},
    };
    try std.testing.expectEqual(false, idx.unique);
}

test "TableSchema.primaryKey returns primary key field name" {
    const schema = TableSchema{
        .table_name = "users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "name", .field_type = .string },
        },
    };
    const pk = schema.primaryKey();
    try std.testing.expect(pk != null);
    try std.testing.expectEqualStrings("id", pk.?);
}

test "TableSchema.primaryKey returns null when no primary key" {
    const schema = TableSchema{
        .table_name = "tags",
        .fields = &.{
            .{ .name = "label", .field_type = .string },
            .{ .name = "color", .field_type = .string },
        },
    };
    try std.testing.expectEqual(@as(?[]const u8, null), schema.primaryKey());
}

test "TableSchema.field finds existing field" {
    const schema = TableSchema{
        .table_name = "posts",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true } },
            .{ .name = "title", .field_type = .string, .constraints = .{ .not_null = true, .max_length = 200 } },
            .{ .name = "body", .field_type = .text },
        },
    };
    const title = schema.field("title");
    try std.testing.expect(title != null);
    try std.testing.expectEqualStrings("title", title.?.name);
    try std.testing.expectEqual(FieldType.string, title.?.field_type);
    try std.testing.expectEqual(true, title.?.constraints.not_null);
    try std.testing.expectEqual(@as(usize, 200), title.?.constraints.max_length.?);
}

test "TableSchema.field returns null for missing field" {
    const schema = TableSchema{
        .table_name = "posts",
        .fields = &.{
            .{ .name = "id", .field_type = .integer },
        },
    };
    try std.testing.expectEqual(@as(?FieldDef, null), schema.field("nonexistent"));
}

test "TableSchema with empty indexes defaults" {
    const schema = TableSchema{
        .table_name = "simple",
        .fields = &.{
            .{ .name = "val", .field_type = .integer },
        },
    };
    try std.testing.expectEqual(@as(usize, 0), schema.indexes.len);
}

test "MigrationOp.label for create_table" {
    const op = MigrationOp{
        .create_table = .{
            .table_name = "users",
            .fields = &.{
                .{ .name = "id", .field_type = .integer },
            },
        },
    };
    try std.testing.expectEqualStrings("create_table_users", op.label());
}

test "MigrationOp.label for add_column" {
    const op = MigrationOp{
        .add_column = .{
            .table = "users",
            .field = .{ .name = "email", .field_type = .string },
        },
    };
    try std.testing.expectEqualStrings("add_column_users_email", op.label());
}

test "MigrationOp.label for drop_column" {
    const op = MigrationOp{
        .drop_column = .{
            .table = "users",
            .column_name = "legacy_col",
        },
    };
    try std.testing.expectEqualStrings("drop_column_users_legacy_col", op.label());
}

test "MigrationOp.label for create_index" {
    const op = MigrationOp{
        .create_index = .{
            .table = "orders",
            .index = .{ .name = "idx_status", .fields = &.{"status"} },
        },
    };
    try std.testing.expectEqualStrings("create_index_orders_idx_status", op.label());
}

test "MigrationOp.label for drop_index" {
    const op = MigrationOp{
        .drop_index = .{
            .table = "orders",
            .index_name = "idx_old",
        },
    };
    try std.testing.expectEqualStrings("drop_index_orders_idx_old", op.label());
}

test "MigrationOp.label for rename_table" {
    const op = MigrationOp{
        .rename_table = .{
            .old_name = "users",
            .new_name = "accounts",
        },
    };
    try std.testing.expectEqualStrings("rename_table_users_to_accounts", op.label());
}

test "MigrationOp.label for raw_sql" {
    const op = MigrationOp{ .raw_sql = "ALTER TABLE x DROP COLUMN y" };
    try std.testing.expectEqualStrings("raw_sql", op.label());
}

test "MigrationOp.deinit does not panic" {
    const op = MigrationOp{ .raw_sql = "SELECT 1" };
    op.deinit();
}

test "Migration struct construction" {
    const ops = &[_]MigrationOp{
        .{ .raw_sql = "CREATE INDEX idx_foo ON bar(name)" },
    };
    const m = Migration{
        .version = 1,
        .description = "initial migration",
        .operations = ops,
    };
    try std.testing.expectEqual(@as(u32, 1), m.version);
    try std.testing.expectEqualStrings("initial migration", m.description);
    try std.testing.expectEqual(@as(usize, 1), m.operations.len);
}

test "Migration with multiple operations" {
    const ops = &[_]MigrationOp{
        .{ .create_table = .{
            .table_name = "users",
            .fields = &.{
                .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true } },
                .{ .name = "name", .field_type = .string },
            },
        } },
        .{ .create_index = .{
            .table = "users",
            .index = .{ .name = "idx_name", .fields = &.{"name"}, .unique = true },
        } },
    };
    const m = Migration{
        .version = 2,
        .description = "add users table and index",
        .operations = ops,
    };
    try std.testing.expectEqual(@as(u32, 2), m.version);
    try std.testing.expectEqual(@as(usize, 2), m.operations.len);
    try std.testing.expectEqualStrings("create_table_users", m.operations[0].label());
    try std.testing.expectEqualStrings("create_index_users_idx_name", m.operations[1].label());
}

test "FieldType enum ordinal values" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(FieldType.integer));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(FieldType.string));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(FieldType.float));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(FieldType.boolean));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(FieldType.datetime));
    try std.testing.expectEqual(@as(u3, 5), @intFromEnum(FieldType.json_text));
    try std.testing.expectEqual(@as(u3, 6), @intFromEnum(FieldType.text));
}
