//! 查询构建器（Query Builder）
//!
//! 提供类似 SQL 的链式 API 来构建查询：
//! ```zig
//! var q = Query(User).init(gpa);
//! try q.where(.Eq, "status", .{ .string = "active" })
//!     .orderBy("created_at", .Desc)
//!     .limit(10)
//!     .offset(0);
//! ```

const std = @import("std");
const schema_mod = @import("schema.zig");

const FieldType = schema_mod.FieldType;
const FieldValue = schema_mod.FieldValue;

/// 比较运算符
pub const Operator = enum {
    Eq,
    Neq,
    Gt,
    Gte,
    Lt,
    Lte,
    Like,
    In,
    NotIn,
    IsNull,
    IsNotNull,

    pub fn symbol(self: Operator) []const u8 {
        return switch (self) {
            .Eq => "=",
            .Neq => "!=",
            .Gt => ">",
            .Gte => ">=",
            .Lt => "<",
            .Lte => "<=",
            .Like => "LIKE",
            .In => "IN",
            .NotIn => "NOT IN",
            .IsNull => "IS NULL",
            .IsNotNull => "IS NOT NULL",
        };
    }
};

/// 排序方向
pub const SortDirection = enum {
    Asc,
    Desc,
};

/// 查询类型
pub const QueryType = enum {
    select,
    insert,
    update,
    delete,
    count,
};

/// WHERE 条件
pub const WhereCondition = struct {
    field: []const u8,
    operator: Operator,
    value: FieldValue,
    logic: Logic = .And,
};

pub const Logic = enum {
    And,
    Or,
};

/// 排序子句
pub const OrderClause = struct {
    field: []const u8,
    direction: SortDirection,
};

/// 泛型查询构建器
pub fn QueryBuilder(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        query_type: QueryType = .select,
        conditions: std.ArrayList(WhereCondition),
        order_clauses: std.ArrayList(OrderClause),
        limit_value: ?usize = null,
        offset_value: ?usize = null,
        selected_fields: ?[]const []const u8 = null,
        data: ?T = null, // 用于 INSERT/UPDATE 的数据
        /// 更新时只更新指定字段
        update_fields: ?[]const []const u8 = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .conditions = std.ArrayList(WhereCondition).empty,
                .order_clauses = std.ArrayList(OrderClause).empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.conditions.deinit(self.allocator);
            self.order_clauses.deinit(self.allocator);
        }

        /// 设置查询类型为 SELECT
        pub fn select(self: *Self) *Self {
            self.query_type = .select;
            return self;
        }

        /// 设置查询类型为 SELECT，指定字段
        pub fn selectFields(self: *Self, fields: []const []const u8) *Self {
            self.query_type = .select;
            self.selected_fields = fields;
            return self;
        }

        /// 设置查询类型为 COUNT
        pub fn count(self: *Self) *Self {
            self.query_type = .count;
            return self;
        }

        /// 设置数据用于 INSERT
        pub fn insert(self: *Self, data: T) *Self {
            self.query_type = .insert;
            self.data = data;
            return self;
        }

        /// 设置数据用于 UPDATE
        pub fn update(self: *Self, data: T, fields: []const []const u8) *Self {
            self.query_type = .update;
            self.data = data;
            self.update_fields = fields;
            return self;
        }

        /// 设置查询类型为 DELETE
        pub fn delete(self: *Self) *Self {
            self.query_type = .delete;
            return self;
        }

        /// 添加 WHERE 条件
        pub fn where(self: *Self, op: Operator, field: []const u8, value: FieldValue) *Self {
            self.conditions.append(self.allocator, .{
                .field = field,
                .operator = op,
                .value = value,
                .logic = .And,
            }) catch @panic("OOM");
            return self;
        }

        /// 添加 AND WHERE 条件（显式 AND 语法糖）
        pub fn andWhere(self: *Self, op: Operator, field: []const u8, value: FieldValue) *Self {
            return self.where(op, field, value);
        }

        /// 添加 OR WHERE 条件
        pub fn orWhere(self: *Self, op: Operator, field: []const u8, value: FieldValue) *Self {
            self.conditions.append(self.allocator, .{
                .field = field,
                .operator = op,
                .value = value,
                .logic = .Or,
            }) catch @panic("OOM");
            return self;
        }

        /// 添加排序
        pub fn orderBy(self: *Self, field: []const u8, direction: SortDirection) *Self {
            self.order_clauses.append(self.allocator, .{
                .field = field,
                .direction = direction,
            }) catch @panic("OOM");
            return self;
        }

        /// 设置 LIMIT
        pub fn limit(self: *Self, n: usize) *Self {
            self.limit_value = n;
            return self;
        }

        /// 设置 OFFSET
        pub fn offset(self: *Self, n: usize) *Self {
            self.offset_value = n;
            return self;
        }

        /// 从条件判断当前查询是否为 "查找全部"（无过滤条件）
        pub fn isFindAll(self: *const Self) bool {
            return self.conditions.items.len == 0;
        }

        /// 判断给定行是否匹配当前查询条件
        pub fn matches(self: *const Self, row: T) bool {
            if (self.conditions.items.len == 0) return true;

            var result: ?bool = null;

            for (self.conditions.items) |cond| {
                const field_value = getFieldValue(T, row, cond.field);
                const matches_cond = evaluateCondition(cond, field_value);

                if (result == null) {
                    result = matches_cond;
                } else {
                    result = switch (cond.logic) {
                        .And => result.? and matches_cond,
                        .Or => result.? or matches_cond,
                    };
                }
            }

            return result orelse true;
        }

        /// 对结果集应用排序
        pub fn applySorting(self: *const Self, rows: *std.ArrayList(T)) void {
            if (self.order_clauses.items.len == 0) return;

            const items = rows.items;
            const clauses = self.order_clauses.items;

            std.sort.insertion(T, items, clauses, struct {
                fn compare(ctx: []const OrderClause, a: T, b: T) bool {
                    for (ctx) |clause| {
                        const va = getFieldValue(T, a, clause.field);
                        const vb = getFieldValue(T, b, clause.field);
                        const cmp = compareValues(va, vb);
                        if (cmp == .lt) return clause.direction == .Asc;
                        if (cmp == .gt) return clause.direction == .Desc;
                    }
                    return false;
                }
            }.compare);
        }

        /// 对结果集应用分页
        pub fn applyPagination(self: *const Self, rows: *std.ArrayList(T)) void {
            if (self.offset_value) |off| {
                if (off >= rows.items.len) {
                    rows.clearRetainingCapacity();
                    return;
                }
                // 移除前 off 个元素
                var i: usize = 0;
                while (i < off) : (i += 1) {
                    _ = rows.orderedRemove(0);
                }
            }
            if (self.limit_value) |lim| {
                if (rows.items.len > lim) {
                    rows.shrinkRetainingCapacity(lim);
                }
            }
        }
    };
}

/// 比较两个 FieldValue
fn compareValues(a: FieldValue, b: FieldValue) std.math.Order {
    return switch (a) {
        .integer => |va| switch (b) {
            .integer => |vb| std.math.order(va, vb),
            else => .eq,
        },
        .string => |va| switch (b) {
            .string => |vb| std.mem.order(u8, va, vb),
            else => .eq,
        },
        .float => |va| switch (b) {
            .float => |vb| std.math.order(@as(i64, @intFromFloat(va * 1_000_000.0)), @as(i64, @intFromFloat(vb * 1_000_000.0))),
            else => .eq,
        },
        .boolean => |va| switch (b) {
            .boolean => |vb| std.math.order(@intFromBool(va), @intFromBool(vb)),
            else => .eq,
        },
        else => .eq,
    };
}

/// 评估单个条件
fn evaluateCondition(cond: WhereCondition, field_value: FieldValue) bool {
    if (cond.operator == .IsNull) {
        return isNullValue(field_value);
    }
    if (cond.operator == .IsNotNull) {
        return !isNullValue(field_value);
    }

    return switch (field_value) {
        .integer => |v| switch (cond.value) {
            .integer => |cv| compareInteger(cond.operator, v, cv),
            else => false,
        },
        .string => |v| switch (cond.value) {
            .string => |cv| compareString(cond.operator, v, cv),
            else => false,
        },
        .float => |v| switch (cond.value) {
            .float => |cv| compareFloat(cond.operator, v, cv),
            else => false,
        },
        .boolean => |v| switch (cond.value) {
            .boolean => |cv| compareBool(cond.operator, v, cv),
            else => false,
        },
        else => false,
    };
}

fn isNullValue(v: FieldValue) bool {
    return switch (v) {
        .integer => |x| x == 0,
        .string => |x| x.len == 0,
        .float => |x| x == 0.0,
        .boolean => |x| !x,
        .json_text => |x| x.len == 0,
        .text => |x| x.len == 0,
        .datetime => |x| x == 0,
    };
}

fn compareInteger(op: Operator, a: i64, b: i64) bool {
    return switch (op) {
        .Eq => a == b,
        .Neq => a != b,
        .Gt => a > b,
        .Gte => a >= b,
        .Lt => a < b,
        .Lte => a <= b,
        else => false,
    };
}

fn compareFloat(op: Operator, a: f64, b: f64) bool {
    return switch (op) {
        .Eq => a == b,
        .Neq => a != b,
        .Gt => a > b,
        .Gte => a >= b,
        .Lt => a < b,
        .Lte => a <= b,
        else => false,
    };
}

fn compareString(op: Operator, a: []const u8, b: []const u8) bool {
    return switch (op) {
        .Eq => std.mem.eql(u8, a, b),
        .Neq => !std.mem.eql(u8, a, b),
        .Like => std.mem.indexOf(u8, a, b) != null,
        .In, .NotIn => false,
        else => false,
    };
}

fn compareBool(op: Operator, a: bool, b: bool) bool {
    return switch (op) {
        .Eq => a == b,
        .Neq => a != b,
        else => false,
    };
}

/// 从结构体实例中获取字段值（编译期反射）
pub fn getFieldValue(comptime T: type, instance: T, field_name: []const u8) FieldValue {
    inline for (std.meta.fields(T)) |f| {
        if (std.mem.eql(u8, f.name, field_name)) {
            const val = @field(instance, f.name);
            return toFieldValue(val);
        }
    }
    @panic("Field not found in " ++ @typeName(T));
}

/// 将任意值转换为 FieldValue
pub fn toFieldValue(value: anytype) FieldValue {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => FieldValue{ .integer = @intCast(value) },
        .float, .comptime_float => FieldValue{ .float = @floatCast(value) },
        .bool => FieldValue{ .boolean = value },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return FieldValue{ .string = value };
            }
            if (ptr.size == .one) {
                const info = @typeInfo(ptr.child);
                if (info == .array and info.array.child == u8) {
                    return FieldValue{ .string = value };
                }
            }
            @compileError("Unsupported pointer type for FieldValue: " ++ @typeName(T));
        },
        .optional => {
            if (value) |v| {
                return toFieldValue(v);
            }
            return switch (@typeInfo(std.meta.Child(T))) {
                .int, .comptime_int => FieldValue{ .integer = 0 },
                .float, .comptime_float => FieldValue{ .float = 0.0 },
                .bool => FieldValue{ .boolean = false },
                else => FieldValue{ .string = "" },
            };
        },
        else => @compileError("Unsupported type for FieldValue: " ++ @typeName(T)),
    };
}

/// 从 FieldValue 设置结构体字段
pub fn setFieldFromValue(comptime T: type, instance: *T, field_name: []const u8, value: FieldValue) void {
    inline for (std.meta.fields(T)) |f| {
        if (std.mem.eql(u8, f.name, field_name)) {
            switch (@typeInfo(f.type)) {
                .int, .comptime_int => {
                    @field(instance, f.name) = @intCast(value.integer);
                },
                .float, .comptime_float => {
                    @field(instance, f.name) = @floatCast(value.float);
                },
                .bool => {
                    @field(instance, f.name) = value.boolean;
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        @field(instance, f.name) = value.string;
                    }
                },
                .optional => {
                    const Child = std.meta.Child(f.type);
                    switch (@typeInfo(Child)) {
                        .int, .comptime_int => {
                            @field(instance, f.name) = @as(Child, @intCast(value.integer));
                        },
                        .float, .comptime_float => {
                            @field(instance, f.name) = @as(Child, @floatCast(value.float));
                        },
                        .bool => {
                            @field(instance, f.name) = value.boolean;
                        },
                        else => {},
                    }
                },
                else => {},
            }
            return;
        }
    }
}

// =========================================================================
// 测试
// =========================================================================

test "QueryBuilder basic select" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
    };

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    try std.testing.expect(qb.isFindAll());
}

test "QueryBuilder where condition" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        name: []const u8,
        age: u32,
    };

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "age", .{ .integer = 25 });
    try std.testing.expect(!qb.isFindAll());
    try std.testing.expectEqual(@as(usize, 1), qb.conditions.items.len);

    const user = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user));

    const user2 = User{ .id = 2, .name = "Bob", .age = 30 };
    try std.testing.expect(!qb.matches(user2));
}

test "QueryBuilder sorting" {
    const allocator = std.testing.allocator;
    const User = struct {
        id: u64,
        age: u32,
    };

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    try list.append(allocator, .{ .id = 1, .age = 30 });
    try list.append(allocator, .{ .id = 2, .age = 20 });
    try list.append(allocator, .{ .id = 3, .age = 25 });

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("age", .Asc);
    _ = qb.applySorting(&list);

    try std.testing.expectEqual(@as(u32, 20), list.items[0].age);
    try std.testing.expectEqual(@as(u32, 25), list.items[1].age);
    try std.testing.expectEqual(@as(u32, 30), list.items[2].age);
}

test "QueryBuilder pagination" {
    const allocator = std.testing.allocator;
    const User = struct { id: u64 };

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try list.append(allocator, .{ .id = i });
    }

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.offset(3).limit(3);
    _ = qb.applyPagination(&list);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(u64, 3), list.items[0].id);
    try std.testing.expectEqual(@as(u64, 5), list.items[2].id);
}

test "toFieldValue integer" {
    const v = toFieldValue(@as(i32, 42));
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "toFieldValue string" {
    const v = toFieldValue("hello");
    try std.testing.expectEqualStrings("hello", v.string);
}
