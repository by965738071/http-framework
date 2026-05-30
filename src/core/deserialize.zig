//! 通用反序列化模块
//!
//! 利用 Zig comptime 反射，将 HTTP 请求体（JSON / form-urlencoded�?
//! 自动映射到用户定义的结构体类�?T�?
//!
//! # 设计原则
//!
//! 1. **类型安全** �?编译期检�?T 是否为合法的结构体类�?
//! 2. **内存安全** �?使用 Arena 分配器，调用方通过 `Parsed(T).deinit()` 统一释放
//! 3. **零拷�?* �?JSON 解析直接映射�?T，form 解析使用 arena 分配字符�?
//! 4. **扩展�?* �?Content-Type 分发机制，易于添加新格式
//!
//! # 使用示例
//!
//! ```zig
//! const CreateUser = struct {
//!     name: []const u8,
//!     age: u32,
//!     email: []const u8,
//! };
//!
//! fn handler(ctx: *RequestContext, res: *Response) !void {
//!     var parsed = try ctx.bodyAs(CreateUser);
//!     defer parsed.deinit();
//!
//!     const user = parsed.value;
//!     std.log.info("name={s}, age={d}", .{ user.name, user.age });
//! }
//! ```

const std = @import("std");
const mem = std.mem;

/// 反序列化结果包装�?
///
/// 持有反序列化后的值和 Arena 分配器，
/// 调用 `deinit()` 一次性释放所有相关内存�?
pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        arena: *std.heap.ArenaAllocator,

        /// 释放所有反序列化过程中分配的内�?
        pub fn deinit(self: *Self) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// 反序列化错误�?
pub const DeserializeError = error{
    /// 请求体为�?
    EmptyBody,
    /// 不支持的 Content-Type
    UnsupportedContentType,
    /// 缺少 Content-Type �?
    NoContentType,
    /// JSON 解析失败
    InvalidJson,
    /// form-urlencoded 解析失败
    InvalidForm,
    /// 缺少必填字段
    MissingField,
    /// 字段类型不匹�?
    TypeMismatch,
};

// ===========================================================================
// JSON 反序列化
// ===========================================================================

/// �?JSON 请求体反序列化为类型 T
///
/// 使用 `std.json.parseFromSlice` 进行解析�?
/// 通过 Arena 分配器管理所有堆内存�?
pub fn parseJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) DeserializeError!Parsed(T) {
    // 创建 arena 分配�?
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);

    // 使用 arena 的分配器进行 JSON 解析
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(T, arena_alloc, body, .{}) catch {
        arena.deinit();
        allocator.destroy(arena);
        return error.InvalidJson;
    };
    // 注意：不�?deinit parsed，arena 会统一管理内存
    // parsed.value 中的 slice 指向 arena 分配的内�?

    return Parsed(T){
        .value = parsed.value,
        .arena = arena,
    };
}

// ===========================================================================
// form-urlencoded 反序列化（comptime 反射�?
// ===========================================================================

/// �?form-urlencoded 请求体反序列化为类型 T
///
/// 使用 comptime 反射遍历 T 的字段，�?key=value 对中提取值并转换类型�?
///
/// 支持的字段类型：
/// - `[]const u8` �?原样赋值（URL 解码后）
/// - `[]u8` �?同上
/// - 整数类型（i8/i16/i32/i64/u8/u16/u32/u64）�?解析为对应整�?
/// - 浮点类型（f32/f64）�?解析为对应浮点数
/// - `bool` �?"true"/"1" �?true，其余为 false
/// - `?T` �?可选类型，字段缺失时为 null
pub fn parseForm(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) DeserializeError!Parsed(T) {
    // 创建 arena 分配�?
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const arena_alloc = arena.allocator();

    // 解析 form-urlencoded 键值对
    var pairs = FormPairs.init(body);

    // comptime 反射：遍�?T 的所有字�?
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("bodyAs only supports struct types, got: " ++ @typeName(T));
    }

    var result: T = undefined;
    const fields = info.@"struct".fields;

    // 记录哪些字段已被设置（用于检测缺失的必填字段�?
    var set_fields: [fields.len]bool = [_]bool{false}**fields.len;

    // 遍历 form 键值对，匹配结构体字段
    while (pairs.next()) |pair| {
        inline for (fields, 0..) |field, i| {
            if (mem.eql(u8, pair.key, field.name)) {
                @field(result, field.name) = try parseFormField(
                    field.type,
                    arena_alloc,
                    pair.value,
                );
                set_fields[i] = true;
            }
        }
    }

    // 检查缺失的必填字段（非可选类型必须被设置�?
    inline for (fields, 0..) |field, i| {
        if (!set_fields[i]) {
            const field_info = @typeInfo(field.type);
            if (field_info == .optional) {
                // 可选字段默认为 null
                @field(result, field.name) = null;
            } else if (field.default_value) |default| {
                // 有默认值的字段
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
            } else {
                // 必填字段缺失
                return error.MissingField;
            }
        }
    }

    return Parsed(T){
        .value = result,
        .arena = arena,
    };
}

/// 解析单个 form 字段值为指定类型
fn parseFormField(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: []const u8,
) DeserializeError!T {
    const info = @typeInfo(T);

    // 处理可选类�?
    if (info == .optional) {
        const inner = info.optional.child;
        if (value.len == 0) return null;
        return try parseFormField(inner, allocator, value);
    }

    // 处理字符串类�?�?使用 arena 分配一份副�?
    if (T == []const u8 or T == [:0]const u8) {
        const decoded = urlDecode(allocator, value) catch return error.TypeMismatch;
        return decoded;
    }
    if (T == []u8) {
        const decoded = urlDecode(allocator, value) catch return error.TypeMismatch;
        return decoded;
    }

    // 处理布尔类型
    if (T == bool) {
        if (mem.eql(u8, value, "true") or mem.eql(u8, value, "1")) {
            return true;
        }
        return false;
    }

    // 处理整数类型
    if (info == .int) {
        const trimmed = mem.trim(u8, value, " ");
        return std.fmt.parseInt(T, trimmed, 10) catch return error.TypeMismatch;
    }

    // 处理浮点类型
    if (info == .float) {
        const trimmed = mem.trim(u8, value, " ");
        return std.fmt.parseFloat(T, trimmed) catch return error.TypeMismatch;
    }

    // 不支持的类型
    @compileError("Unsupported field type for form deserialization: " ++ @typeName(T));
}

// ===========================================================================
// URL 解码
// ===========================================================================

/// �?URL 编码的字符串进行百分比解�?
///
/// �?`%XX` 序列解码为对应字节，�?`+` 解码为空格�?
/// 返回的内存由 arena 分配器管理�?
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // 快速路径：没有需要解码的字符
    if (mem.indexOfAny(u8, input, "%+") == null) {
        // 直接复制一�?
        return allocator.dupe(u8, input);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ===========================================================================
// Form 键值对解析�?
// ===========================================================================

/// 简单的 form-urlencoded 解析�?
const FormPairs = struct {
    input: []const u8,
    pos: usize,

    const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    fn init(input: []const u8) FormPairs {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    fn next(self: *FormPairs) ?Pair {
        if (self.pos >= self.input.len) return null;

        // 找到下一�?'&' �?';'
        const end = mem.indexOfAny(u8, self.input[self.pos..], "&;") orelse self.input.len - self.pos;
        const segment = self.input[self.pos .. self.pos + end];

        // 推进位置
        self.pos += end + 1;

        // 分割 key=value
        if (mem.indexOfScalar(u8, segment, '=')) |eq_idx| {
            return .{
                .key = segment[0..eq_idx],
                .value = if (eq_idx + 1 < segment.len) segment[eq_idx + 1 ..] else "",
            };
        }

        // 没有 '='，视�?key=true
        return .{
            .key = segment,
            .value = "true",
        };
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "Parsed lifecycle" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
        age: u32,
    };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\",\"age\":30}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age);
}

test "parseForm basic" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
        age: u32,
    };

    var parsed = try parseForm(T, allocator, "name=Alice&age=30");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age);
}

test "parseForm optional field" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
        nickname: ?[]const u8,
    };

    var parsed = try parseForm(T, allocator, "name=Alice");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expect(parsed.value.nickname == null);
}

test "parseForm with default value" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
        role: []const u8 = "user",
    };

    var parsed = try parseForm(T, allocator, "name=Alice");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("user", parsed.value.role);
}

test "parseForm with URL encoding" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
    };

    var parsed = try parseForm(T, allocator, "name=Hello+World%21");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello World!", parsed.value.name);
}

test "parseForm bool field" {
    const allocator = std.testing.allocator;

    const T = struct {
        active: bool,
        deleted: bool,
    };

    var parsed = try parseForm(T, allocator, "active=true&deleted=false");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.active);
    try std.testing.expect(!parsed.value.deleted);
}

test "parseForm missing required field" {
    const allocator = std.testing.allocator;

    const T = struct {
        name: []const u8,
        age: u32,
    };

    const result = parseForm(T, allocator, "name=Alice");
    try std.testing.expectError(error.MissingField, result);
}
