//! 字段级 diff —— 审计日志的"变更前后"数据。
//!
//! ORM 只支持 int/float/bool/string，所以可以用编译期反射把任意一行结构体
//! 的每个字段格式化成字符串后逐字段比较，天然适用于所有实体。

const std = @import("std");

pub const FieldChange = struct {
    field: []const u8,
    before: []const u8,
    after: []const u8,
};

/// 逐字段比较两个同类型结构体，返回发生变化的字段列表。
///
/// `ignore` 里的字段不参与比较（updated_at / password_hash 这类每次都变、
/// 或不应出现在审计日志里的字段）。
pub fn diffStruct(
    comptime T: type,
    allocator: std.mem.Allocator,
    before: T,
    after: T,
    comptime ignore: []const []const u8,
) ![]FieldChange {
    var out = std.ArrayList(FieldChange).empty;
    errdefer out.deinit(allocator);

    // 本版本 `@typeInfo(T).@"struct"` 是 std.lang.Type.Struct（只有
    // field_names / field_types，没有 .fields），用 std.meta.fieldNames 更稳。
    inline for (comptime std.meta.fieldNames(T)) |name| {
        if (comptime isIgnored(name, ignore)) continue;
        const b = try formatField(allocator, @field(before, name));
        const a = try formatField(allocator, @field(after, name));
        if (!std.mem.eql(u8, b, a)) {
            try out.append(allocator, .{ .field = name, .before = b, .after = a });
        } else {
            allocator.free(b);
            allocator.free(a);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeChanges(allocator: std.mem.Allocator, changes: []FieldChange) void {
    for (changes) |c| {
        allocator.free(c.before);
        allocator.free(c.after);
    }
    allocator.free(changes);
}

/// `ignore` 是 comptime 参数：反射需要它编译期已知。
fn isIgnored(comptime name: []const u8, comptime ignore: []const []const u8) bool {
    inline for (ignore) |i| {
        if (comptime std.mem.eql(u8, name, i)) return true;
    }
    return false;
}

/// 把 int / float / bool / 字符串字段格式化成可比较、可展示的字符串。
fn formatField(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const V = @TypeOf(value);
    return switch (@typeInfo(V)) {
        .bool => std.fmt.allocPrint(allocator, "{}", .{value}),
        .int, .comptime_int => std.fmt.allocPrint(allocator, "{d}", .{value}),
        .float, .comptime_float => std.fmt.allocPrint(allocator, "{d}", .{value}),
        .pointer => allocator.dupe(u8, value),
        .optional => if (value) |v| formatField(allocator, v) else allocator.dupe(u8, ""),
        .@"enum" => allocator.dupe(u8, @tagName(value)),
        else => @compileError("diff: unsupported field type " ++ @typeName(V)),
    };
}

/// 把 diff 结果序列化成审计日志里存的 JSON 文本。
pub fn changesToJson(allocator: std.mem.Allocator, changes: []const FieldChange) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(changes);
    return allocator.dupe(u8, out.written());
}

pub const empty_json: []const u8 = "[]";

const Sample = struct {
    id: u64,
    name: []const u8,
    score: i64,
    active: bool,
    updated_at: u64,
};

test "diffStruct 只报告变化的字段" {
    const before = Sample{ .id = 1, .name = "a", .score = 10, .active = true, .updated_at = 1 };
    const after = Sample{ .id = 1, .name = "b", .score = 10, .active = false, .updated_at = 2 };
    const changes = try diffStruct(Sample, std.testing.allocator, before, after, &.{"updated_at"});
    defer freeChanges(std.testing.allocator, changes);

    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqualStrings("name", changes[0].field);
    try std.testing.expectEqualStrings("a", changes[0].before);
    try std.testing.expectEqualStrings("b", changes[0].after);
    try std.testing.expectEqualStrings("active", changes[1].field);
    try std.testing.expectEqualStrings("true", changes[1].before);
    try std.testing.expectEqualStrings("false", changes[1].after);
}

test "diffStruct 无变化时返回空" {
    const s = Sample{ .id = 1, .name = "a", .score = 1, .active = true, .updated_at = 1 };
    const changes = try diffStruct(Sample, std.testing.allocator, s, s, &.{});
    defer freeChanges(std.testing.allocator, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "diffStruct 忽略列表生效" {
    const before = Sample{ .id = 1, .name = "a", .score = 1, .active = true, .updated_at = 1 };
    var after = before;
    after.updated_at = 99;
    const changes = try diffStruct(Sample, std.testing.allocator, before, after, &.{"updated_at"});
    defer freeChanges(std.testing.allocator, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "changesToJson 输出字段数组" {
    const changes = [_]FieldChange{
        .{ .field = "email", .before = "a@x.com", .after = "b@x.com" },
    };
    const json = try changesToJson(std.testing.allocator, &changes);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "[{\"field\":\"email\",\"before\":\"a@x.com\",\"after\":\"b@x.com\"}]",
        json,
    );
}

test {
    std.testing.refAllDecls(@This());
}
