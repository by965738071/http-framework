//! 请求校验模块
//!
//! 提供声明式字段校验，支持从 Query、Form、Path params 中自动提取值。
//! 使用 comptime 反射，在编译期生成校验代码。
//!
//! 用法：
//! ```zig
//! const rules = struct {
//!     name: []const FieldRule = &.{ .required, .{ .min_len = 2 }, .{ .max_len = 50 } },
//!     age:  []const FieldRule = &.{ .required, .{ .min = 0 }, .{ .max = 150 } },
//! };
//! const result = try Validation.validateRequest(allocator, ctx, rules);
//! if (!result.valid) {
//!     try res.statusCode(.bad_request).json(result.errors);
//!     return;
//! }
//! ```

const std = @import("std");
const mem = std.mem;
const RequestContext = @import("request.zig");

/// 校验错误类型
pub const ValidationError = error{
    Required,
    MinLength,
    MaxLength,
    Pattern,
    Range,
    InvalidEnum,
    Custom,
};

/// 字段校验规则
pub const FieldRule = union(enum) {
    /// 字段必填
    required: bool,
    /// 最小长度（字符串）
    min_len: usize,
    /// 最大长度（字符串）
    max_len: usize,
    /// 正则匹配（简单子串匹配，未来可扩展 regex）
    pattern: []const u8,
    /// 最小值（数值）
    min: i64,
    /// 最大值（数值）
    max: i64,
    /// 枚举值列表
    @"enum": []const []const u8,
};

/// 校验结果
pub const ValidationResult = struct {
    valid: bool,
    errors: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        var it = self.errors.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.errors.deinit(allocator);
    }
};

// =========================================================================
// 单个字段校验
// =========================================================================

/// 校验单个字段值，返回 `null` 表示通过，否则返回错误消息。
/// 调用者负责释放返回的错误消息。
pub fn validateField(
    allocator: std.mem.Allocator,
    value: []const u8,
    rules: []const FieldRule,
) !?[]const u8 {
    for (rules) |rule| {
        switch (rule) {
            .required => {
                if (value.len == 0) {
                    return try allocator.dupe(u8, "field is required");
                }
            },
            .min_len => |min| {
                if (value.len < min) {
                    return try std.fmt.allocPrint(allocator, "minimum length is {d}, got {d}", .{ min, value.len });
                }
            },
            .max_len => |max| {
                if (value.len > max) {
                    return try std.fmt.allocPrint(allocator, "maximum length is {d}, got {d}", .{ max, value.len });
                }
            },
            .pattern => |pat| {
                if (mem.indexOf(u8, value, pat) == null) {
                    return try std.fmt.allocPrint(allocator, "must contain '{s}'", .{pat});
                }
            },
            .min => |min| {
                const num = std.fmt.parseInt(i64, value, 10) catch {
                    return try allocator.dupe(u8, "not a valid number");
                };
                if (num < min) {
                    return try std.fmt.allocPrint(allocator, "minimum value is {d}, got {d}", .{ min, num });
                }
            },
            .max => |max| {
                const num = std.fmt.parseInt(i64, value, 10) catch {
                    return try allocator.dupe(u8, "not a valid number");
                };
                if (num > max) {
                    return try std.fmt.allocPrint(allocator, "maximum value is {d}, got {d}", .{ max, num });
                }
            },
            .@"enum" => |values| {
                var found = false;
                for (values) |v| {
                    if (mem.eql(u8, value, v)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Build joined enum values string without ArrayList
                    var buf: [256]u8 = undefined;
                    var pos: usize = 0;
                    for (values, 0..) |v, i| {
                        if (i > 0 and pos + 2 <= buf.len) {
                            buf[pos] = ',';
                            buf[pos + 1] = ' ';
                            pos += 2;
                        }
                        const n = @min(v.len, buf.len - pos);
                        @memcpy(buf[pos..][0..n], v[0..n]);
                        pos += n;
                    }
                    return try std.fmt.allocPrint(allocator, "must be one of: {s}", .{buf[0..pos]});
                }
            },
        }
    }
    return null;
}

// =========================================================================
// 从 RequestContext 校验（comptime 反射）
// =========================================================================

/// 从请求上下文中按规则集校验所有字段。
///
/// `rules` 是一个 struct 类型值，其每个字段的类型必须是 `[]const FieldRule`。
/// 框架会自动从以下来源按顺序查找字段值：
/// 1. 路径参数（`:id`）
/// 2. Query 参数（`?name=...`）
/// 3. Form body（POST 表单）
///
/// 返回的 `ValidationResult.errors` 的 key 是字段名，value 是错误消息。
pub fn validateRequest(
    allocator: std.mem.Allocator,
    ctx: *RequestContext,
    rules: anytype,
) !ValidationResult {
    const RuleType = @TypeOf(rules);
    const info = @typeInfo(RuleType);

    if (info != .@"struct") {
        @compileError("validateRequest expects a struct of field rules, got: " ++ @typeName(RuleType));
    }

    var result = ValidationResult{
        .valid = true,
        .errors = std.StringHashMapUnmanaged([]const u8){},
    };
    errdefer result.deinit(allocator);

    const struct_info = info.@"struct";
    inline for (struct_info.field_names) |name| {
        const field_rules: []const FieldRule = @field(rules, name);

        // 从请求中提取字段值
        const value = getFieldValue(ctx, name);

        // 校验
        const maybe_err = validateField(allocator, value, field_rules) catch null;
        if (maybe_err) |err_msg| {
            result.valid = false;
            const key = try allocator.dupe(u8, name);
            errdefer allocator.free(key);
            try result.errors.put(allocator, key, err_msg);
        }
    }

    return result;
}

/// 从 RequestContext 中按名称获取字段值（按优先级查找）
fn getFieldValue(ctx: *RequestContext, name: []const u8) []const u8 {
    // 1. 路径参数
    if (ctx.getParam(name)) |v| return v;

    // 2. Query 参数
    if (ctx.getQuery(name)) |v| return v;

    // 3. Form body
    if (ctx.getForm(name)) |v| return v;

    return "";
}

// =========================================================================
// Tests
// =========================================================================

test "validateField - required check" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{.{ .required = true }};

    // 空值 → 应失败
    const err = try validateField(allocator, "", &rules);
    try std.testing.expect(err != null);
    defer allocator.free(err.?);
    try std.testing.expect(mem.indexOf(u8, err.?, "required") != null);

    // 非空 → 应通过
    const ok = try validateField(allocator, "hello", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);
}

test "validateField - min_len / max_len" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{ .{ .min_len = 3 }, .{ .max_len = 6 } };

    // 太短
    const err_short = try validateField(allocator, "ab", &rules);
    try std.testing.expect(err_short != null);
    defer allocator.free(err_short.?);

    // 通过
    const ok = try validateField(allocator, "hello", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);

    // 太长
    const err_long = try validateField(allocator, "abcdefg", &rules);
    try std.testing.expect(err_long != null);
    defer allocator.free(err_long.?);
}

test "validateField - min / max (numeric)" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{ .{ .min = 0 }, .{ .max = 100 } };

    // 超出范围
    const err = try validateField(allocator, "150", &rules);
    try std.testing.expect(err != null);
    defer allocator.free(err.?);

    // 通过
    const ok = try validateField(allocator, "50", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);

    // 非数字
    const err_nan = try validateField(allocator, "abc", &rules);
    try std.testing.expect(err_nan != null);
    defer allocator.free(err_nan.?);
}

test "validateField - pattern matching" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{.{ .pattern = "@" }};

    // 不含 @
    const err = try validateField(allocator, "noat", &rules);
    try std.testing.expect(err != null);
    defer allocator.free(err.?);

    // 含 @ — 通过
    const ok = try validateField(allocator, "user@example.com", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);
}

test "validateField - enum" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{.{ .@"enum" = &.{ "admin", "user", "guest" } }};

    const err = try validateField(allocator, "superuser", &rules);
    try std.testing.expect(err != null);
    defer allocator.free(err.?);

    const ok = try validateField(allocator, "admin", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);
}

test "validateField - combined rules" {
    const allocator = std.testing.allocator;
    const rules = [_]FieldRule{
        FieldRule{ .required = true },
        FieldRule{ .min_len = 2 },
        FieldRule{ .max_len = 10 },
    };

    const ok = try validateField(allocator, "hello", &rules);
    try std.testing.expectEqual(@as(?[]const u8, null), ok);
}

test "ValidationResult.deinit" {
    const allocator = std.testing.allocator;
    var result = ValidationResult{
        .valid = false,
        .errors = std.StringHashMapUnmanaged([]const u8){},
    };
    const key = try allocator.dupe(u8, "name");
    const val = try allocator.dupe(u8, "required");
    try result.errors.put(allocator, key, val);
    result.deinit(allocator);
}
