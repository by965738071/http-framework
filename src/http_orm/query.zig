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
        /// 构建期错误。where/orWhere/orderBy 保持 `*Self` 链式返回，
        /// 无法直接返回 error，于是把 OOM / 条件数超限记在这里，由引擎
        /// 执行前（findAll/update/delete/count 调 checkBuildError）统一报出。
        /// 旧实现是 `catch @panic("OOM")` —— filter 数量来自请求时，
        /// 内存压力或攻击者塞大量 filter 会把 OOM 变成远程进程 abort（P0-8）。
        build_error: ?anyerror = null,

        const Self = @This();

        /// 单个查询允许的 WHERE 条件数上限。条件数来自请求时（用户可控），
        /// 无上限会让攻击者用超长 filter 链放大内存与 CPU（P0-8）。
        pub const MAX_CONDITIONS: usize = 256;

        /// 引擎执行前调用：若构建期发生过错误（OOM / 条件超限）则报出。
        pub fn checkBuildError(self: *const Self) !void {
            if (self.build_error) |e| return e;
        }

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
        ///
        /// P2-31：JsonStore 的读接口一律返回完整结构体 `T`，无法按字段裁剪。
        /// 旧实现只把字段名存进 `selected_fields` 却从不读取——`selectFields(&.{"id"})`
        /// 照样返回整行。若有人以为能用它隐藏 `password_hash`，就是静默数据泄漏。
        /// 因此这里记为构建期错误，执行时（checkBuildError）显式报出，不再假装支持。
        pub fn selectFields(self: *Self, fields: []const []const u8) *Self {
            self.query_type = .select;
            self.selected_fields = fields;
            self.build_error = error.SelectFieldsUnsupported;
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

        /// 设置数据用于 UPDATE。
        /// `fields` 为要更新的字段名；传 null 表示整行替换（id 由引擎保留）。
        pub fn update(self: *Self, data: T, fields: ?[]const []const u8) *Self {
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
            self.appendCondition(op, field, value, .And);
            return self;
        }

        /// 内部：追加一个条件，OOM / 超限时记录 build_error（不 panic）。
        fn appendCondition(self: *Self, op: Operator, field: []const u8, value: FieldValue, logic: Logic) void {
            if (self.build_error != null) return;
            // In/NotIn 在 Operator 里公开、有 symbol()，但 FieldValue 根本没有列表变体，
            // compareString 硬编码 `.In, .NotIn => false`，数值/布尔分支落 `else => false`
            // —— 这两个操作符匹配不到任何行，且语义上无法表达（P1-12）。
            // 宁可在构建期报错，也不要静默返回空结果（静默错误比崩溃更危险）。
            if (op == .In or op == .NotIn) {
                self.build_error = error.UnsupportedOperator;
                return;
            }
            if (self.conditions.items.len >= MAX_CONDITIONS) {
                self.build_error = error.TooManyConditions;
                return;
            }
            self.conditions.append(self.allocator, .{
                .field = field,
                .operator = op,
                .value = value,
                .logic = logic,
            }) catch |e| {
                self.build_error = e;
            };
        }

        /// 添加 AND WHERE 条件（显式 AND 语法糖）
        pub fn andWhere(self: *Self, op: Operator, field: []const u8, value: FieldValue) *Self {
            return self.where(op, field, value);
        }

        /// 添加 OR WHERE 条件
        pub fn orWhere(self: *Self, op: Operator, field: []const u8, value: FieldValue) *Self {
            self.appendCondition(op, field, value, .Or);
            return self;
        }

        /// 添加排序
        pub fn orderBy(self: *Self, field: []const u8, direction: SortDirection) *Self {
            if (self.build_error != null) return self;
            self.order_clauses.append(self.allocator, .{
                .field = field,
                .direction = direction,
            }) catch |e| {
                self.build_error = e;
            };
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

        /// 判断给定行是否匹配当前查询条件。
        /// 字段名不存在时该条件视为不匹配（而非 panic）——where 字段名可能来自外部。
        pub fn matches(self: *const Self, row: T) bool {
            if (self.conditions.items.len == 0) return true;

            // 两级折叠：AND 优先级高于 OR（与 SQL 语义一致）。
            // 旧实现是纯左结合（`result = result <op> m`），会把
            // `id=1 OR hash=999 AND created=5` 算成 `((v OR v) AND v)`，
            // 读会漏数据、update/delete 会改错/删错行（不可逆）。
            // 这里按 OR 分组：组内用 AND 折叠，组间用 OR 折叠。
            var or_acc = false;
            var and_acc: ?bool = null;

            for (self.conditions.items) |cond| {
                // 未知字段（where 字段名可能来自外部输入）→ 该条件不匹配。
                const matches_cond = if (getFieldValueOpt(T, row, cond.field)) |fv|
                    evaluateCondition(cond, fv)
                else
                    false;

                switch (cond.logic) {
                    .And => and_acc = if (and_acc) |a| a and matches_cond else matches_cond,
                    .Or => {
                        or_acc = or_acc or (and_acc orelse true);
                        and_acc = matches_cond;
                    },
                }
            }

            return or_acc or (and_acc orelse true);
        }

        /// 对结果集应用排序
        pub fn applySorting(self: *const Self, rows: *std.ArrayList(T)) void {
            if (self.order_clauses.items.len == 0) return;

            const items = rows.items;
            const clauses = self.order_clauses.items;

            // P3-1：用 std.sort.block（O(N log N) 稳定排序）而非插入排序（O(N²)）。
            // 排序在持 store 锁时进行，用户可控的 orderBy + 几万行 = 幈9 CPU 放大 + 全服阻塞。
            // compareValues 已对称（P3-5），可安全用于严格弱序比较器。
            std.sort.block(T, items, clauses, struct {
                fn lessThan(ctx: []const OrderClause, a: T, b: T) bool {
                    for (ctx) |clause| {
                        // 未知字段：跳过该排序子句（不 panic）。
                        const va = getFieldValueOpt(T, a, clause.field) orelse continue;
                        const vb = getFieldValueOpt(T, b, clause.field) orelse continue;
                        const cmp = compareValues(va, vb);
                        if (cmp == .lt) return clause.direction == .Asc;
                        if (cmp == .gt) return clause.direction == .Desc;
                    }
                    return false;
                }
            }.lessThan);
        }

        /// 对结果集应用分页
        pub fn applyPagination(self: *const Self, rows: *std.ArrayList(T)) void {
            if (self.offset_value) |off| {
                if (off >= rows.items.len) {
                    rows.clearRetainingCapacity();
                    return;
                }
                // 单次前向拷贝实现 offset 跳过，避免 O(offset*N) 的逐个移除
                const new_len = rows.items.len - off;
                std.mem.copyForwards(T, rows.items[0..new_len], rows.items[off..]);
                rows.shrinkRetainingCapacity(new_len);
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
/// P3-5：必须对称。旧实现 `.integer` 分支对 `.float` 返 `.eq`，但 `.float` 分支
/// 对 `.integer` 会真比，于是 `cmp(int5,float3)=.eq` 而 `cmp(float3,int5)=.lt`。
/// 现在靠“两边总来自同一字段”掩盖，一旦换成 std.sort.pdq 就是 UB-adjacent。
/// 统一：先 normalize（datetime→int、text/json_text→string），int↔float 混合时都提升为 f64。
fn compareValues(a_raw: FieldValue, b_raw: FieldValue) std.math.Order {
    const a = normalizeFieldValue(a_raw);
    const b = normalizeFieldValue(b_raw);
    return switch (a) {
        .integer => |va| switch (b) {
            .integer => |vb| std.math.order(va, vb),
            .float => |vb| std.math.order(@as(f64, @floatFromInt(va)), vb),
            else => .eq,
        },
        .string => |va| switch (b) {
            .string => |vb| std.mem.order(u8, va, vb),
            else => .eq,
        },
        .float => |va| switch (b) {
            .float => |vb| std.math.order(va, vb),
            // 数值与整数比较时统一为 f64 再比较
            .integer => |vb| std.math.order(va, @as(f64, @floatFromInt(vb))),
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

    // 归一化：字段值与条件值都把 .datetime 视作整数、.text/.json_text 视作字符串。
    // 旧实现要求两边 tag 完全一致，而 toFieldValue 只产出 .integer/.float/.boolean/.string，
    // 于是用 .datetime/.text/.json_text 写的条件永远落到 `else => false`（静默零结果，
    // 比崩溃更危险）。
    const fv = normalizeFieldValue(field_value);
    const cv = normalizeFieldValue(cond.value);

    return switch (fv) {
        .integer => |v| switch (cv) {
            .integer => |c| compareInteger(cond.operator, v, c),
            else => false,
        },
        .string => |v| switch (cv) {
            .string => |c| compareString(cond.operator, v, c),
            else => false,
        },
        .float => |v| switch (cv) {
            .float => |c| compareFloat(cond.operator, v, c),
            // 数值与整数条件比较时统一为 f64。
            .integer => |c| compareFloat(cond.operator, v, @floatFromInt(c)),
            else => false,
        },
        .boolean => |v| switch (cv) {
            .boolean => |c| compareBool(cond.operator, v, c),
            else => false,
        },
        else => false,
    };
}

/// 把 .datetime 归一成 .integer、.text/.json_text 归一成 .string，
/// 便于 evaluateCondition 只需处理 4 种基础 tag。
fn normalizeFieldValue(v: FieldValue) FieldValue {
    return switch (v) {
        .datetime => |x| .{ .integer = x },
        .text, .json_text => |x| .{ .string = x },
        else => v,
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
        // SQL 风格 LIKE：% 匹配任意子串，_ 匹配单个字符（大小写不敏感）
        .Like => likeMatch(a, b),
        .In, .NotIn => false,
        else => false,
    };
}

/// 支持 `%`（任意子串）与 `_`（单个字符）的通配匹配，大小写不敏感。
fn likeMatch(haystack: []const u8, pattern: []const u8) bool {
    // 无通配符时退化为大小写不敏感的子串包含匹配
    if (std.mem.indexOfAny(u8, pattern, "%_") == null) {
        return ciContains(haystack, pattern);
    }
    return likeMatchRecursive(haystack, pattern);
}

/// 大小写不敏感的子串包含判断（不分配内存）。
fn ciContains(haystack: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len > haystack.len) return false;
    var start: usize = 0;
    while (start + pattern.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            if (!asciiCiEq(haystack[start + i], pattern[i])) break;
        } else return true;
    }
    return false;
}

fn likeMatchRecursive(haystack: []const u8, pattern: []const u8) bool {
    var i: usize = 0; // pattern 下标
    var j: usize = 0; // haystack 下标
    var star: usize = 0;
    var has_star = false;
    var mark: usize = 0;

    while (j < haystack.len) {
        if (i < pattern.len and (pattern[i] == '_' or asciiCiEq(pattern[i], haystack[j]))) {
            i += 1;
            j += 1;
            continue;
        }
        if (i < pattern.len and pattern[i] == '%') {
            has_star = true;
            star = i;
            i += 1;
            mark = j;
            continue;
        }
        if (has_star) {
            i = star + 1;
            mark += 1;
            j = mark;
            continue;
        }
        return false;
    }
    // 消费尾部连续的 %（匹配空串）
    while (i < pattern.len and pattern[i] == '%') i += 1;
    return i == pattern.len;
}

fn asciiCiEq(a: u8, b: u8) bool {
    return asciiToLower(a) == asciiToLower(b);
}

fn asciiToLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn compareBool(op: Operator, a: bool, b: bool) bool {
    return switch (op) {
        .Eq => a == b,
        .Neq => a != b,
        else => false,
    };
}

/// 从结构体实例中获取字段值（编译期反射）。找不到字段时 @panic。
/// 仅用于字段名编译期/schema 保证存在的内部调用（checkUnique/applyDefaults）。
/// 对运行时、可能拼错的字段名（where/orderBy）用 getFieldValueOpt。
pub fn getFieldValue(comptime T: type, instance: T, field_name: []const u8) FieldValue {
    return getFieldValueOpt(T, instance, field_name) orelse
        @panic("Field not found in " ++ @typeName(T));
}

/// 从结构体实例中获取字段值，找不到返回 null（不 panic）。
/// 用于字段名来自运行时/外部输入的场景，避免拼错一个字段名就崩溃整个进程。
pub fn getFieldValueOpt(comptime T: type, instance: T, field_name: []const u8) ?FieldValue {
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (struct_info.field_names, struct_info.field_types) |fname, ftype| {
        _ = ftype;
        if (std.mem.eql(u8, fname, field_name)) {
            const val = @field(instance, fname);
            return toFieldValue(val);
        }
    }
    return null;
}

/// 将任意值转换为 FieldValue
pub fn toFieldValue(value: anytype) FieldValue {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        // 超过 i64 范围的整数（如 u64 > 2^63）用 std.math.cast 饱和到边界值，
        // 而不是 @intCast panic：字段值触到 where/orderBy/matches 就不会打死进程。
        // 无法表示的极值退化成 i64 边界，比崩溃安全（真正需要 u64 全域的场景
        // 应在 model.fieldTypeOf 层面拒绝，见该处 @compileError）。
        .int, .comptime_int => FieldValue{
            .integer = std.math.cast(i64, value) orelse
                (if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64)),
        },
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
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (struct_info.field_names, struct_info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, fname, field_name)) {
            setTyped(ftype, &@field(instance, fname), value);
            return;
        }
    }
}

/// 按目标字段类型写入一个 FieldValue。
///
/// **必须先看 value 的 active tag，再按目标类型转换**：旧实现直接写
/// `@field(instance, fname) = @intCast(value.integer)`，完全不管 value 的实际 tag。
/// FieldValue 是 union，读一个非 active 的字段在 safe 构建下 panic
/// （`access of union field 'integer' while field 'datetime' is active`），
/// 在 ReleaseFast 下是静默的 payload 重新解释（类型混淆）。
/// applyDefaults 会把 schema 的 default_value（可能是 .datetime/.text/...）喂进来，
/// 所以这条路径是真实可达的。类型不匹配时静默忽略（保持默认值），越界整数用
/// std.math.cast 饱和而非 panic。
fn setTyped(comptime FieldT: type, field_ptr: anytype, value: FieldValue) void {
    switch (@typeInfo(FieldT)) {
        .int, .comptime_int => switch (value) {
            .integer, .datetime => |x| field_ptr.* = std.math.cast(FieldT, x) orelse return,
            else => {},
        },
        .float, .comptime_float => switch (value) {
            .float => |x| field_ptr.* = @floatCast(x),
            .integer, .datetime => |x| field_ptr.* = @floatFromInt(x),
            else => {},
        },
        .bool => switch (value) {
            .boolean => |x| field_ptr.* = x,
            else => {},
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                switch (value) {
                    .string, .text, .json_text => |x| field_ptr.* = x,
                    else => {},
                }
            }
        },
        .optional => |opt| setTyped(opt.child, field_ptr, value),
        else => {},
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

test "QueryBuilder In/NotIn 记录 build_error（P0-8/P1-12）" {
    const allocator = std.testing.allocator;
    const User = struct { id: u64, name: []const u8 };

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.where(.In, "id", .{ .integer = 1 });
    try std.testing.expectError(error.UnsupportedOperator, qb.checkBuildError());
}

test "QueryBuilder 条件数超上限记录 build_error（P0-8）" {
    const allocator = std.testing.allocator;
    const User = struct { id: u64, name: []const u8 };

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    var i: usize = 0;
    while (i < QueryBuilder(User).MAX_CONDITIONS + 5) : (i += 1) {
        _ = qb.where(.Eq, "id", .{ .integer = 1 });
    }
    try std.testing.expectError(error.TooManyConditions, qb.checkBuildError());
}

test "QueryBuilder AND 优先级高于 OR（P1-11）" {
    const allocator = std.testing.allocator;
    const User = struct { id: u64, hash: u64, created: u64 };

    // id=1 OR hash=999 AND created=5，SQL 语义 = (id=1) OR (hash=999 AND created=5)。
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = 1 });
    _ = qb.orWhere(.Eq, "hash", .{ .integer = 999 });
    _ = qb.where(.Eq, "created", .{ .integer = 5 });

    try std.testing.expect(qb.matches(.{ .id = 1, .hash = 0, .created = 0 }));
    try std.testing.expect(qb.matches(.{ .id = 0, .hash = 999, .created = 5 }));
    try std.testing.expect(!qb.matches(.{ .id = 0, .hash = 999, .created = 4 }));
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

// =========================================================================
// Operator.symbol tests
// =========================================================================

test "Operator.symbol Eq" {
    try std.testing.expectEqualStrings("=", Operator.Eq.symbol());
}

test "Operator.symbol Neq" {
    try std.testing.expectEqualStrings("!=", Operator.Neq.symbol());
}

test "Operator.symbol Gt" {
    try std.testing.expectEqualStrings(">", Operator.Gt.symbol());
}

test "Operator.symbol Gte" {
    try std.testing.expectEqualStrings(">=", Operator.Gte.symbol());
}

test "Operator.symbol Lt" {
    try std.testing.expectEqualStrings("<", Operator.Lt.symbol());
}

test "Operator.symbol Lte" {
    try std.testing.expectEqualStrings("<=", Operator.Lte.symbol());
}

test "Operator.symbol Like" {
    try std.testing.expectEqualStrings("LIKE", Operator.Like.symbol());
}

test "Operator.symbol In" {
    try std.testing.expectEqualStrings("IN", Operator.In.symbol());
}

test "Operator.symbol NotIn" {
    try std.testing.expectEqualStrings("NOT IN", Operator.NotIn.symbol());
}

test "Operator.symbol IsNull" {
    try std.testing.expectEqualStrings("IS NULL", Operator.IsNull.symbol());
}

test "Operator.symbol IsNotNull" {
    try std.testing.expectEqualStrings("IS NOT NULL", Operator.IsNotNull.symbol());
}

// =========================================================================
// QueryBuilder method tests
// =========================================================================

test "QueryBuilder.select sets query type" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.select();
    try std.testing.expectEqual(QueryType.select, qb.query_type);
}

test "QueryBuilder.selectFields sets query type and fields" {
    const User = struct { id: u64, name: []const u8 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.selectFields(&.{ "id", "name" });
    try std.testing.expectEqual(QueryType.select, qb.query_type);
    try std.testing.expect(qb.selected_fields != null);
    try std.testing.expectEqual(@as(usize, 2), qb.selected_fields.?.len);
    try std.testing.expectEqualStrings("id", qb.selected_fields.?[0]);
    try std.testing.expectEqualStrings("name", qb.selected_fields.?[1]);
    // P2-31：selectFields 在 JsonStore 不受支持，应记录构建期错误，执行时报出。
    try std.testing.expectError(error.SelectFieldsUnsupported, qb.checkBuildError());
}

test "QueryBuilder.count sets query type" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.count();
    try std.testing.expectEqual(QueryType.count, qb.query_type);
}

test "QueryBuilder.insert sets query type and data" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.insert(.{ .id = 1, .name = "Alice", .age = 30 });
    try std.testing.expectEqual(QueryType.insert, qb.query_type);
    try std.testing.expect(qb.data != null);
    try std.testing.expectEqual(@as(u64, 1), qb.data.?.id);
    try std.testing.expectEqualStrings("Alice", qb.data.?.name);
    try std.testing.expectEqual(@as(u32, 30), qb.data.?.age);
}

test "QueryBuilder.update sets query type and fields" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.update(.{ .id = 1, .name = "Bob", .age = 25 }, &.{"name"});
    try std.testing.expectEqual(QueryType.update, qb.query_type);
    try std.testing.expect(qb.data != null);
    try std.testing.expectEqualStrings("Bob", qb.data.?.name);
    try std.testing.expect(qb.update_fields != null);
    try std.testing.expectEqual(@as(usize, 1), qb.update_fields.?.len);
    try std.testing.expectEqualStrings("name", qb.update_fields.?[0]);
}

test "QueryBuilder.delete sets query type" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.delete();
    try std.testing.expectEqual(QueryType.delete, qb.query_type);
}

test "QueryBuilder.andWhere adds AND condition" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "id", .{ .integer = 1 })
        .andWhere(.Gt, "age", .{ .integer = 18 });

    try std.testing.expectEqual(@as(usize, 2), qb.conditions.items.len);
    try std.testing.expectEqual(Logic.And, qb.conditions.items[0].logic);
    try std.testing.expectEqual(Logic.And, qb.conditions.items[1].logic);
}

test "QueryBuilder.orWhere adds OR condition" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "id", .{ .integer = 1 })
        .orWhere(.Eq, "name", .{ .string = "Bob" });

    try std.testing.expectEqual(@as(usize, 2), qb.conditions.items.len);
    try std.testing.expectEqual(Logic.And, qb.conditions.items[0].logic);
    try std.testing.expectEqual(Logic.Or, qb.conditions.items[1].logic);
}

test "QueryBuilder.limit sets limit_value" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.limit(10);
    try std.testing.expectEqual(@as(?usize, 10), qb.limit_value);
}

test "QueryBuilder.offset sets offset_value" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.offset(5);
    try std.testing.expectEqual(@as(?usize, 5), qb.offset_value);
}

test "QueryBuilder.isFindAll true when no conditions" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    try std.testing.expect(qb.isFindAll());
}

test "QueryBuilder.isFindAll false when has conditions" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "id", .{ .integer = 1 });
    try std.testing.expect(!qb.isFindAll());
}

// =========================================================================
// matches() with multiple conditions
// =========================================================================

test "QueryBuilder matches with AND conditions" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Gt, "age", .{ .integer = 18 })
        .andWhere(.Eq, "active", .{ .boolean = true });

    const user_match = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user_match));

    const user_fail_age = User{ .id = 2, .name = "Bob", .age = 16 };
    try std.testing.expect(!qb.matches(user_fail_age));

    const user_fail_active = User{ .id = 3, .name = "Charlie", .age = 30, .active = false };
    try std.testing.expect(!qb.matches(user_fail_active));
}

test "QueryBuilder matches with OR conditions" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "name", .{ .string = "Alice" })
        .orWhere(.Eq, "name", .{ .string = "Bob" });

    const user_alice = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user_alice));

    const user_bob = User{ .id = 2, .name = "Bob", .age = 30 };
    try std.testing.expect(qb.matches(user_bob));

    const user_charlie = User{ .id = 3, .name = "Charlie", .age = 20 };
    try std.testing.expect(!qb.matches(user_charlie));
}

test "QueryBuilder matches with Like operator" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Like, "name", .{ .string = "Ali" });

    const user = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user));

    const user2 = User{ .id = 2, .name = "Bob", .age = 30 };
    try std.testing.expect(!qb.matches(user2));
}

test "QueryBuilder matches with Neq operator" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Neq, "age", .{ .integer = 30 });

    const user = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user));

    const user2 = User{ .id = 2, .name = "Bob", .age = 30 };
    try std.testing.expect(!qb.matches(user2));
}

test "QueryBuilder matches with string conditions" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "name", .{ .string = "Alice" });

    const user = User{ .id = 1, .name = "Alice", .age = 25 };
    try std.testing.expect(qb.matches(user));

    const user2 = User{ .id = 2, .name = "Bob", .age = 30 };
    try std.testing.expect(!qb.matches(user2));
}

test "QueryBuilder matches with boolean conditions" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;
    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();

    _ = qb.where(.Eq, "active", .{ .boolean = false });

    const user_active = User{ .id = 1, .name = "Alice", .age = 25, .active = true };
    try std.testing.expect(!qb.matches(user_active));

    const user_inactive = User{ .id = 2, .name = "Bob", .age = 30, .active = false };
    try std.testing.expect(qb.matches(user_inactive));
}

test "QueryBuilder matches with Gt/Lt/Lte/Gte operators" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;

    // Gt
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Gt, "age", .{ .integer = 20 });
        const user = User{ .id = 1, .name = "A", .age = 25 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 2, .name = "B", .age = 20 };
        try std.testing.expect(!qb.matches(user2));
    }
    // Gte
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Gte, "age", .{ .integer = 20 });
        const user = User{ .id = 1, .name = "A", .age = 20 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 2, .name = "B", .age = 19 };
        try std.testing.expect(!qb.matches(user2));
    }
    // Lt
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Lt, "age", .{ .integer = 30 });
        const user = User{ .id = 1, .name = "A", .age = 25 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 2, .name = "B", .age = 30 };
        try std.testing.expect(!qb.matches(user2));
    }
    // Lte
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.Lte, "age", .{ .integer = 30 });
        const user = User{ .id = 1, .name = "A", .age = 30 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 2, .name = "B", .age = 31 };
        try std.testing.expect(!qb.matches(user2));
    }
}

test "QueryBuilder matches with IsNull and IsNotNull" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const allocator = std.testing.allocator;

    // IsNull on integer (0 is null)
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.IsNull, "id", .{ .integer = 0 });
        const user = User{ .id = 0, .name = "A", .age = 25 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 1, .name = "B", .age = 30 };
        try std.testing.expect(!qb.matches(user2));
    }
    // IsNotNull on string (empty is null)
    {
        var qb = QueryBuilder(User).init(allocator);
        defer qb.deinit();
        _ = qb.where(.IsNotNull, "name", .{ .string = "" });
        const user = User{ .id = 1, .name = "Alice", .age = 25 };
        try std.testing.expect(qb.matches(user));
        const user2 = User{ .id = 2, .name = "", .age = 30 };
        try std.testing.expect(!qb.matches(user2));
    }
}

// =========================================================================
// applySorting tests
// =========================================================================

test "QueryBuilder applySorting Desc direction" {
    const User = struct { id: u64, age: u32 };
    const allocator = std.testing.allocator;

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    try list.append(allocator, .{ .id = 1, .age = 20 });
    try list.append(allocator, .{ .id = 2, .age = 30 });
    try list.append(allocator, .{ .id = 3, .age = 25 });

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("age", .Desc);
    _ = qb.applySorting(&list);

    try std.testing.expectEqual(@as(u32, 30), list.items[0].age);
    try std.testing.expectEqual(@as(u32, 25), list.items[1].age);
    try std.testing.expectEqual(@as(u32, 20), list.items[2].age);
}

test "QueryBuilder applySorting multiple sort clauses" {
    const User = struct { id: u64, age: u32 };
    const allocator = std.testing.allocator;

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    try list.append(allocator, .{ .id = 1, .age = 25 });
    try list.append(allocator, .{ .id = 2, .age = 25 });
    try list.append(allocator, .{ .id = 3, .age = 20 });
    try list.append(allocator, .{ .id = 4, .age = 30 });

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("age", .Asc).orderBy("id", .Desc);
    _ = qb.applySorting(&list);

    try std.testing.expectEqual(@as(u32, 20), list.items[0].age);
    // Both have age 25, sorted by id Desc: id=2 before id=1
    try std.testing.expectEqual(@as(u64, 2), list.items[1].id);
    try std.testing.expectEqual(@as(u64, 1), list.items[2].id);
    try std.testing.expectEqual(@as(u32, 30), list.items[3].age);
}

// =========================================================================
// applyPagination edge cases
// =========================================================================

test "QueryBuilder applyPagination offset beyond length" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    try list.append(allocator, .{ .id = 1 });
    try list.append(allocator, .{ .id = 2 });
    try list.append(allocator, .{ .id = 3 });

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.offset(10).limit(5);
    _ = qb.applyPagination(&list);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "QueryBuilder applyPagination limit 0" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    try list.append(allocator, .{ .id = 1 });
    try list.append(allocator, .{ .id = 2 });

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.limit(0);
    _ = qb.applyPagination(&list);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "QueryBuilder applyPagination only offset" {
    const User = struct { id: u64 };
    const allocator = std.testing.allocator;

    var list = std.ArrayList(User).empty;
    defer list.deinit(allocator);
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        try list.append(allocator, .{ .id = i });
    }

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.offset(2);
    _ = qb.applyPagination(&list);

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(u64, 2), list.items[0].id);
}

// =========================================================================
// toFieldValue tests
// =========================================================================

test "toFieldValue float" {
    const v = toFieldValue(@as(f64, 3.14));
    try std.testing.expectEqual(@as(f64, 3.14), v.float);
}

test "toFieldValue bool true" {
    const v = toFieldValue(true);
    try std.testing.expectEqual(true, v.boolean);
}

test "toFieldValue bool false" {
    const v = toFieldValue(false);
    try std.testing.expectEqual(false, v.boolean);
}

test "toFieldValue optional some integer" {
    const val: ?i32 = 42;
    const v = toFieldValue(val);
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "toFieldValue optional none integer" {
    const val: ?i32 = null;
    const v = toFieldValue(val);
    try std.testing.expectEqual(@as(i64, 0), v.integer);
}

test "toFieldValue optional some bool" {
    const val: ?bool = true;
    const v = toFieldValue(val);
    try std.testing.expectEqual(true, v.boolean);
}

test "toFieldValue optional none bool" {
    const val: ?bool = null;
    const v = toFieldValue(val);
    try std.testing.expectEqual(false, v.boolean);
}

test "toFieldValue optional some float" {
    const val: ?f32 = 2.5;
    const v = toFieldValue(val);
    try std.testing.expectEqual(@as(f64, 2.5), v.float);
}

test "toFieldValue optional none float" {
    const val: ?f32 = null;
    const v = toFieldValue(val);
    try std.testing.expectEqual(@as(f64, 0.0), v.float);
}

test "toFieldValue comptime int" {
    const v = toFieldValue(100);
    try std.testing.expectEqual(@as(i64, 100), v.integer);
}

test "toFieldValue comptime float" {
    const v = toFieldValue(1.5);
    try std.testing.expectEqual(@as(f64, 1.5), v.float);
}

// =========================================================================
// getFieldValue tests
// =========================================================================

test "getFieldValue for u64 field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const user = User{ .id = 42, .name = "Alice", .age = 25 };
    const v = getFieldValue(User, user, "id");
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "getFieldValue for string field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const user = User{ .id = 1, .name = "Alice", .age = 25 };
    const v = getFieldValue(User, user, "name");
    try std.testing.expectEqualStrings("Alice", v.string);
}

test "getFieldValue for u32 field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const user = User{ .id = 1, .name = "Alice", .age = 30 };
    const v = getFieldValue(User, user, "age");
    try std.testing.expectEqual(@as(i64, 30), v.integer);
}

test "getFieldValue for bool field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    const user = User{ .id = 1, .name = "Alice", .age = 25, .active = false };
    const v = getFieldValue(User, user, "active");
    try std.testing.expectEqual(false, v.boolean);
}

// =========================================================================
// setFieldFromValue tests
// =========================================================================

test "setFieldFromValue int field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    var user = User{ .id = 0, .name = "", .age = 0 };
    setFieldFromValue(User, &user, "id", .{ .integer = 99 });
    try std.testing.expectEqual(@as(u64, 99), user.id);
}

test "setFieldFromValue string field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    var user = User{ .id = 0, .name = "", .age = 0 };
    setFieldFromValue(User, &user, "name", .{ .string = "Bob" });
    try std.testing.expectEqualStrings("Bob", user.name);
}

test "setFieldFromValue bool field" {
    const User = struct { id: u64, name: []const u8, age: u32, active: bool = true };
    var user = User{ .id = 0, .name = "", .age = 0, .active = false };
    setFieldFromValue(User, &user, "active", .{ .boolean = true });
    try std.testing.expect(user.active);
}

test "setFieldFromValue float field" {
    const Item = struct { id: u64, price: f64 };
    var item = Item{ .id = 1, .price = 0.0 };
    setFieldFromValue(Item, &item, "price", .{ .float = 19.99 });
    try std.testing.expectEqual(@as(f64, 19.99), item.price);
}

// =========================================================================
// compareValues tests
// =========================================================================

test "compareValues integer equal" {
    const result = compareValues(.{ .integer = 5 }, .{ .integer = 5 });
    try std.testing.expectEqual(std.math.Order.eq, result);
}

test "compareValues integer less" {
    const result = compareValues(.{ .integer = 3 }, .{ .integer = 7 });
    try std.testing.expectEqual(std.math.Order.lt, result);
}

test "compareValues integer greater" {
    const result = compareValues(.{ .integer = 10 }, .{ .integer = 2 });
    try std.testing.expectEqual(std.math.Order.gt, result);
}

test "compareValues string equal" {
    const result = compareValues(.{ .string = "abc" }, .{ .string = "abc" });
    try std.testing.expectEqual(std.math.Order.eq, result);
}

test "compareValues string less" {
    const result = compareValues(.{ .string = "aaa" }, .{ .string = "bbb" });
    try std.testing.expectEqual(std.math.Order.lt, result);
}

test "compareValues string greater" {
    const result = compareValues(.{ .string = "zzz" }, .{ .string = "aaa" });
    try std.testing.expectEqual(std.math.Order.gt, result);
}

test "compareValues float equal" {
    const result = compareValues(.{ .float = 1.5 }, .{ .float = 1.5 });
    try std.testing.expectEqual(std.math.Order.eq, result);
}

test "compareValues float less" {
    const result = compareValues(.{ .float = 1.0 }, .{ .float = 2.0 });
    try std.testing.expectEqual(std.math.Order.lt, result);
}

test "compareValues float greater" {
    const result = compareValues(.{ .float = 3.0 }, .{ .float = 1.0 });
    try std.testing.expectEqual(std.math.Order.gt, result);
}

test "compareValues boolean equal" {
    const result = compareValues(.{ .boolean = true }, .{ .boolean = true });
    try std.testing.expectEqual(std.math.Order.eq, result);
}

test "compareValues boolean false less than true" {
    const result = compareValues(.{ .boolean = false }, .{ .boolean = true });
    try std.testing.expectEqual(std.math.Order.lt, result);
}

test "compareValues boolean true greater than false" {
    const result = compareValues(.{ .boolean = true }, .{ .boolean = false });
    try std.testing.expectEqual(std.math.Order.gt, result);
}

test "compareValues mismatched types returns eq" {
    const result = compareValues(.{ .integer = 5 }, .{ .string = "five" });
    try std.testing.expectEqual(std.math.Order.eq, result);
}

// =========================================================================
// evaluateCondition tests
// =========================================================================

test "evaluateCondition Eq integer" {
    const cond = WhereCondition{ .field = "id", .operator = .Eq, .value = .{ .integer = 42 } };
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 42 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 43 }));
}

test "evaluateCondition Neq integer" {
    const cond = WhereCondition{ .field = "id", .operator = .Neq, .value = .{ .integer = 42 } };
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 42 }));
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 43 }));
}

test "evaluateCondition Gt integer" {
    const cond = WhereCondition{ .field = "age", .operator = .Gt, .value = .{ .integer = 18 } };
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 25 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 18 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 10 }));
}

test "evaluateCondition Lt integer" {
    const cond = WhereCondition{ .field = "age", .operator = .Lt, .value = .{ .integer = 30 } };
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 25 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 30 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 35 }));
}

test "evaluateCondition Gte integer" {
    const cond = WhereCondition{ .field = "age", .operator = .Gte, .value = .{ .integer = 18 } };
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 25 }));
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 18 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 17 }));
}

test "evaluateCondition Lte integer" {
    const cond = WhereCondition{ .field = "age", .operator = .Lte, .value = .{ .integer = 30 } };
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 25 }));
    try std.testing.expect(evaluateCondition(cond, .{ .integer = 30 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .integer = 31 }));
}

test "evaluateCondition Like string" {
    const cond = WhereCondition{ .field = "name", .operator = .Like, .value = .{ .string = "Ali" } };
    try std.testing.expect(evaluateCondition(cond, .{ .string = "Alice" }));
    try std.testing.expect(!evaluateCondition(cond, .{ .string = "Bob" }));
}

test "evaluateCondition Eq string" {
    const cond = WhereCondition{ .field = "name", .operator = .Eq, .value = .{ .string = "Alice" } };
    try std.testing.expect(evaluateCondition(cond, .{ .string = "Alice" }));
    try std.testing.expect(!evaluateCondition(cond, .{ .string = "Bob" }));
}

test "evaluateCondition Neq string" {
    const cond = WhereCondition{ .field = "name", .operator = .Neq, .value = .{ .string = "Alice" } };
    try std.testing.expect(!evaluateCondition(cond, .{ .string = "Alice" }));
    try std.testing.expect(evaluateCondition(cond, .{ .string = "Bob" }));
}

test "evaluateCondition IsNull" {
    // integer 0 is null
    try std.testing.expect(evaluateCondition(
        WhereCondition{ .field = "id", .operator = .IsNull, .value = .{ .integer = 0 } },
        .{ .integer = 0 },
    ));
    try std.testing.expect(!evaluateCondition(
        WhereCondition{ .field = "id", .operator = .IsNull, .value = .{ .integer = 0 } },
        .{ .integer = 1 },
    ));
    // empty string is null
    try std.testing.expect(evaluateCondition(
        WhereCondition{ .field = "name", .operator = .IsNull, .value = .{ .string = "" } },
        .{ .string = "" },
    ));
    try std.testing.expect(!evaluateCondition(
        WhereCondition{ .field = "name", .operator = .IsNull, .value = .{ .string = "" } },
        .{ .string = "hello" },
    ));
}

test "evaluateCondition IsNotNull" {
    // integer 0 is null, so IsNotNull should return false
    try std.testing.expect(!evaluateCondition(
        WhereCondition{ .field = "id", .operator = .IsNotNull, .value = .{ .integer = 0 } },
        .{ .integer = 0 },
    ));
    try std.testing.expect(evaluateCondition(
        WhereCondition{ .field = "id", .operator = .IsNotNull, .value = .{ .integer = 0 } },
        .{ .integer = 1 },
    ));
    // empty string is null
    try std.testing.expect(!evaluateCondition(
        WhereCondition{ .field = "name", .operator = .IsNotNull, .value = .{ .string = "" } },
        .{ .string = "" },
    ));
    try std.testing.expect(evaluateCondition(
        WhereCondition{ .field = "name", .operator = .IsNotNull, .value = .{ .string = "" } },
        .{ .string = "hello" },
    ));
}

test "evaluateCondition Eq float" {
    const cond = WhereCondition{ .field = "price", .operator = .Eq, .value = .{ .float = 9.99 } };
    try std.testing.expect(evaluateCondition(cond, .{ .float = 9.99 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .float = 10.0 }));
}

test "evaluateCondition Gt float" {
    const cond = WhereCondition{ .field = "price", .operator = .Gt, .value = .{ .float = 10.0 } };
    try std.testing.expect(evaluateCondition(cond, .{ .float = 15.0 }));
    try std.testing.expect(!evaluateCondition(cond, .{ .float = 5.0 }));
}

test "evaluateCondition Eq bool" {
    const cond = WhereCondition{ .field = "active", .operator = .Eq, .value = .{ .boolean = true } };
    try std.testing.expect(evaluateCondition(cond, .{ .boolean = true }));
    try std.testing.expect(!evaluateCondition(cond, .{ .boolean = false }));
}

test "evaluateCondition Neq bool" {
    const cond = WhereCondition{ .field = "active", .operator = .Neq, .value = .{ .boolean = true } };
    try std.testing.expect(!evaluateCondition(cond, .{ .boolean = true }));
    try std.testing.expect(evaluateCondition(cond, .{ .boolean = false }));
}

test "evaluateCondition mismatched types returns false" {
    const cond = WhereCondition{ .field = "id", .operator = .Eq, .value = .{ .integer = 42 } };
    try std.testing.expect(!evaluateCondition(cond, .{ .string = "42" }));
}

test "evaluateCondition Gt/Lt/Lte/Gte on bool returns false" {
    const gt_cond = WhereCondition{ .field = "active", .operator = .Gt, .value = .{ .boolean = false } };
    try std.testing.expect(!evaluateCondition(gt_cond, .{ .boolean = true }));
    const lt_cond = WhereCondition{ .field = "active", .operator = .Lt, .value = .{ .boolean = false } };
    try std.testing.expect(!evaluateCondition(lt_cond, .{ .boolean = false }));
}

test "Like supports % and _ wildcards (case-insensitive)" {
    const cond = WhereCondition{ .field = "name", .operator = .Like, .value = .{ .string = "ali%" } };
    try std.testing.expect(evaluateCondition(cond, .{ .string = "Alice" }));
    try std.testing.expect(evaluateCondition(cond, .{ .string = "ALISON" }));
    try std.testing.expect(!evaluateCondition(cond, .{ .string = "Bob" }));

    const cond2 = WhereCondition{ .field = "name", .operator = .Like, .value = .{ .string = "A_i%" } };
    try std.testing.expect(evaluateCondition(cond2, .{ .string = "Alice" }));
    try std.testing.expect(!evaluateCondition(cond2, .{ .string = "Alyce" }));

    const cond3 = WhereCondition{ .field = "name", .operator = .Like, .value = .{ .string = "%ice" } };
    try std.testing.expect(evaluateCondition(cond3, .{ .string = "Alice" }));

    const cond4 = WhereCondition{ .field = "name", .operator = .Like, .value = .{ .string = "%li%" } };
    try std.testing.expect(evaluateCondition(cond4, .{ .string = "Alice" }));
    try std.testing.expect(!evaluateCondition(cond4, .{ .string = "Bob" }));
}

test "compareValues float ordering no overflow" {
    // 之前用 *1e6 缩放到 i64，大数值会溢出；直接比较 f64。
    const a = FieldValue{ .float = 1_000_000_000.5 };
    const b = FieldValue{ .float = 2_000_000_000.25 };
    try std.testing.expect(std.math.Order.gt == compareValues(b, a));
    try std.testing.expect(std.math.Order.lt == compareValues(a, b));
    try std.testing.expect(std.math.Order.eq == compareValues(a, a));
}
