//! Deserialization module
//!
//! Auto-map HTTP request body (JSON / form-urlencoded) to user structs
//! using Zig comptime reflection.
//!
//! Usage:
//! ```zig
//! const CreateUser = struct { name: []const u8, age: u32, email: []const u8 };
//! fn handler(ctx: *RequestContext, res: *Response) !void {
//!     var parsed = try ctx.bodyAs(CreateUser);
//!     defer parsed.deinit();
//!     const user = parsed.value;
//! }
//! ```

const std = @import("std");
const mem = std.mem;

/// Wraps a deserialized value with an ArenaAllocator for unified cleanup.
pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: *Self) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

pub const DeserializeError = error{
    EmptyBody,
    UnsupportedContentType,
    NoContentType,
    InvalidJson,
    InvalidForm,
    MissingField,
    TypeMismatch,
};

// ===========================================================================
// JSON Deserialization
// ===========================================================================

/// Parse a JSON request body into type T.
/// Uses an ArenaAllocator to manage all heap memory.
pub fn parseJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) DeserializeError!Parsed(T) {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.EmptyBody;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(T, arena_alloc, body, .{}) catch {
        arena.deinit();
        allocator.destroy(arena);
        return error.InvalidJson;
    };

    return Parsed(T){
        .value = parsed.value,
        .arena = arena,
    };
}

// ===========================================================================
// Form Deserialization (comptime reflection)
// ===========================================================================

/// Parse a form-urlencoded body into type T using comptime reflection.
///
/// Supported field types:
/// - []const u8, [:0]const u8, []u8 — URL-decoded copy
/// - Integers (i8..i64, u8..u64) — parsed from string
/// - Floats (f32, f64) — parsed from string
/// - bool — "true"/"1" = true, else false
/// - ?T — optional, null if missing
pub fn parseForm(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) DeserializeError!Parsed(T) {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.EmptyBody;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const arena_alloc = arena.allocator();

    var pairs = FormPairs.init(body);

    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("bodyAs only supports struct types, got: " ++ @typeName(T));
    }

    var result: T = undefined;
    const fields = info.@"struct".fields;

    var set_fields: [fields.len]bool = ([_]bool{false})**fields.len;

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

    inline for (fields, 0..) |field, i| {
        if (!set_fields[i]) {
            const field_info = @typeInfo(field.type);
            if (field_info == .optional) {
                @field(result, field.name) = null;
            } else if (field.default_value) |default| {
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
            } else {
                return error.MissingField;
            }
        }
    }

    return Parsed(T){ .value = result, .arena = arena };
}

/// Parse a single form field value to the given type.
fn parseFormField(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: []const u8,
) DeserializeError!T {
    const info = @typeInfo(T);

    if (info == .optional) {
        const inner = info.optional.child;
        if (value.len == 0) return null;
        return try parseFormField(inner, allocator, value);
    }

    if (T == []const u8 or T == [:0]const u8) {
        return urlDecode(allocator, value) catch return error.TypeMismatch;
    }
    if (T == []u8) {
        return urlDecode(allocator, value) catch return error.TypeMismatch;
    }

    if (T == bool) {
        if (mem.eql(u8, value, "true") or mem.eql(u8, value, "1")) return true;
        return false;
    }

    if (info == .int) {
        const trimmed = mem.trim(u8, value, " ");
        return std.fmt.parseInt(T, trimmed, 10) catch return error.TypeMismatch;
    }

    if (info == .float) {
        const trimmed = mem.trim(u8, value, " ");
        return std.fmt.parseFloat(T, trimmed) catch return error.TypeMismatch;
    }

    @compileError("Unsupported field type for form deserialization: " ++ @typeName(T));
}

// ===========================================================================
// URL Decode
// ===========================================================================

/// Percent-decode a URL-encoded string. Caller owns the returned memory.
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (mem.indexOfAny(u8, input, "%+") == null) {
        return allocator.dupe(u8, input);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 64);
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
// Form Key-Value Pair Iterator
// ===========================================================================

const FormPairs = struct {
    input: []const u8,
    pos: usize,

    const Pair = struct {
        key: []const u8,
        value: []const u8,
    };

    fn init(input: []const u8) FormPairs {
        return .{ .input = input, .pos = 0 };
    }

    fn next(self: *FormPairs) ?Pair {
        if (self.pos >= self.input.len) return null;

        const end = mem.indexOfAny(u8, self.input[self.pos..], "&;") orelse self.input.len - self.pos;
        const segment = self.input[self.pos .. self.pos + end];
        self.pos += end + 1;

        if (mem.indexOfScalar(u8, segment, '=')) |eq_idx| {
            return .{
                .key = segment[0..eq_idx],
                .value = if (eq_idx + 1 < segment.len) segment[eq_idx + 1 ..] else "",
            };
        }

        return .{ .key = segment, .value = "true" };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Parsed lifecycle" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32 };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\",\"age\":30}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age);
}

test "parseForm basic" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32 };

    var parsed = try parseForm(T, allocator, "name=Alice&age=30");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age);
}

test "parseForm optional field" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, nickname: ?[]const u8 };

    var parsed = try parseForm(T, allocator, "name=Alice");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expect(parsed.value.nickname == null);
}

test "parseForm with default value" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, role: []const u8 = "user" };

    var parsed = try parseForm(T, allocator, "name=Alice");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("user", parsed.value.role);
}

test "parseForm with URL encoding" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8 };

    var parsed = try parseForm(T, allocator, "name=Hello+World%21");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello World!", parsed.value.name);
}

test "parseForm bool field" {
    const allocator = std.testing.allocator;
    const T = struct { active: bool, deleted: bool };

    var parsed = try parseForm(T, allocator, "active=true&deleted=false");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.active);
    try std.testing.expect(!parsed.value.deleted);
}

test "parseForm missing required field" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32 };

    const result = parseForm(T, allocator, "name=Alice");
    try std.testing.expectError(error.MissingField, result);
}
