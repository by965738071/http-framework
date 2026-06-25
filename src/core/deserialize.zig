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

pub const DeserializeError = error{
    EmptyBody,
    UnsupportedContentType,
    NoContentType,
    InvalidJson,
    InvalidForm,
    MissingField,
    TypeMismatch,
};

/// &#31867;&#22411;&#21035;&#21517;&#65292;&#26041;&#20415;&#22806;&#37096;&#24341;&#29992;
pub const Parsed = std.json.Parsed;

// ===========================================================================
// JSON Deserialization
// ===========================================================================

/// &#23558; JSON body &#35299;&#26512;&#20026;&#31867;&#22411; T&#12290;
/// &#20869;&#37096;&#20351;&#29992; ArenaAllocator&#65292;&#35843;&#29992;&#32773;&#21482;&#38656; `defer parsed.deinit()`&#12290;
pub fn parseJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    body: []const u8,
) DeserializeError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, body, .{}) catch return error.InvalidJson;
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
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.InvalidForm;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    var pairs = FormPairs.init(body);

    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("bodyAs only supports struct types, got: " ++ @typeName(T));
    }

    var result: T = undefined;
    const field_names = info.@"struct".field_names;
    const field_types = info.@"struct".field_types;
    const field_attrs = info.@"struct".field_attrs;

    inline for (field_names, field_types, field_attrs) |field_name, field_type, field_attr| {
        if (field_attr.defaultValue(field_type)) |default_val| {
            @field(result, field_name) = default_val;
        }
    }

    var set_fields: [field_names.len]bool = undefined;
    for (&set_fields) |*s| s.* = false;

    while (pairs.next()) |pair| {
        inline for (field_names, field_types, 0..) |field_name, field_type, i| {
            if (mem.eql(u8, pair.key, field_name)) {
                @field(result, field_name) = parseFormField(
                    field_type,
                    arena_alloc,
                    pair.value,
                ) catch {
                    arena.deinit();
                    allocator.destroy(arena);
                    return error.TypeMismatch;
                };
                set_fields[i] = true;
            }
        }
    }

    inline for (field_names, field_types, field_attrs, 0..) |field_name, field_type, field_attr, i| {
        if (!set_fields[i]) {
            const field_info = @typeInfo(field_type);
            if (field_info == .optional) {
                @field(result, field_name) = null;
            } else if (field_attr.default_value_ptr == null) {
                arena.deinit();
                allocator.destroy(arena);
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

// ===========================================================================
// JSON deserialization tests
// ===========================================================================

test "parseJson all field types" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32, active: bool };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Bob\",\"age\":25,\"active\":true}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Bob", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 25), parsed.value.age);
    try std.testing.expect(parsed.value.active);
}

test "parseJson invalid returns InvalidJson" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8 };

    const result = parseJson(T, allocator, "{not valid json}");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parseJson empty body returns InvalidJson" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8 };

    const result = parseJson(T, allocator, "");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parseJson nested objects" {
    const allocator = std.testing.allocator;
    const Address = struct { city: []const u8, zip: []const u8 };
    const T = struct { name: []const u8, address: Address };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\",\"address\":{\"city\":\"NYC\",\"zip\":\"10001\"}}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("NYC", parsed.value.address.city);
    try std.testing.expectEqualStrings("10001", parsed.value.address.zip);
}

test "parseJson optional fields present" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, nickname: ?[]const u8 = null, age: ?u32 = null };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\",\"nickname\":\"Al\",\"age\":30}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("Al", parsed.value.nickname.?);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age.?);
}

test "parseJson optional fields absent" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, nickname: ?[]const u8 = null, age: ?u32 = null };

    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\"}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expect(parsed.value.nickname == null);
    try std.testing.expect(parsed.value.age == null);
}

// ===========================================================================
// Form integer / float parsing tests
// ===========================================================================

test "parseForm integer field u32" {
    const allocator = std.testing.allocator;
    const T = struct { count: u32 };

    var parsed = try parseForm(T, allocator, "count=42");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 42), parsed.value.count);
}

test "parseForm integer field i32 negative" {
    const allocator = std.testing.allocator;
    const T = struct { temperature: i32 };

    var parsed = try parseForm(T, allocator, "temperature=-10");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, -10), parsed.value.temperature);
}

test "parseForm integer field u64" {
    const allocator = std.testing.allocator;
    const T = struct { big: u64 };

    var parsed = try parseForm(T, allocator, "big=1000000000000");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 1000000000000), parsed.value.big);
}

test "parseForm integer field i64" {
    const allocator = std.testing.allocator;
    const T = struct { offset: i64 };

    var parsed = try parseForm(T, allocator, "offset=-9999");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, -9999), parsed.value.offset);
}

test "parseForm float field f32" {
    const allocator = std.testing.allocator;
    const T = struct { ratio: f32 };

    var parsed = try parseForm(T, allocator, "ratio=3.14");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(f32, 3.14), parsed.value.ratio);
}

test "parseForm float field f64" {
    const allocator = std.testing.allocator;
    const T = struct { precision: f64 };

    var parsed = try parseForm(T, allocator, "precision=2.718281828");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(f64, 2.718281828), parsed.value.precision);
}

// ===========================================================================
// Form bool edge cases
// ===========================================================================

test "parseForm bool with 1 is true" {
    const allocator = std.testing.allocator;
    const T = struct { flag: bool };

    var parsed = try parseForm(T, allocator, "flag=1");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.flag);
}

test "parseForm bool with 0 is false" {
    const allocator = std.testing.allocator;
    const T = struct { flag: bool };

    var parsed = try parseForm(T, allocator, "flag=0");
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.flag);
}

// ===========================================================================
// Form multi-field and separator tests
// ===========================================================================

test "parseForm multiple fields mixed types" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32, score: f64, active: bool };

    var parsed = try parseForm(T, allocator, "name=Bob&age=25&score=9.5&active=true");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Bob", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 25), parsed.value.age);
    try std.testing.expectEqual(@as(f64, 9.5), parsed.value.score);
    try std.testing.expect(parsed.value.active);
}

test "parseForm semicolon separator" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, age: u32 };

    var parsed = try parseForm(T, allocator, "name=Alice;age=30");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 30), parsed.value.age);
}

// ===========================================================================
// URL decoding tests (via parseForm)
// ===========================================================================

test "parseForm url decode %20 to space" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8 };

    var parsed = try parseForm(T, allocator, "name=Hello%20World");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Hello World", parsed.value.name);
}

test "parseForm url decode %2F to slash" {
    const allocator = std.testing.allocator;
    const T = struct { path: []const u8 };

    var parsed = try parseForm(T, allocator, "path=a%2Fb%2Fc");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("a/b/c", parsed.value.path);
}

test "parseForm url decode plus to space" {
    const allocator = std.testing.allocator;
    const T = struct { q: []const u8 };

    var parsed = try parseForm(T, allocator, "q=hello+world");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello world", parsed.value.q);
}

test "parseForm url decode mixed encoding" {
    const allocator = std.testing.allocator;
    const T = struct { msg: []const u8 };

    var parsed = try parseForm(T, allocator, "msg=foo+bar%21baz");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("foo bar!baz", parsed.value.msg);
}

test "parseForm url decode no encoding needed" {
    const allocator = std.testing.allocator;
    const T = struct { plain: []const u8 };

    var parsed = try parseForm(T, allocator, "plain=hello");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", parsed.value.plain);
}

// ===========================================================================
// Optional field and default value tests
// ===========================================================================

test "parseForm optional empty value is null" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, tag: ?[]const u8 };

    var parsed = try parseForm(T, allocator, "name=Alice&tag=");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expect(parsed.value.tag == null);
}

test "parseForm default value overridden by form" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, role: []const u8 = "user" };

    var parsed = try parseForm(T, allocator, "name=Alice&role=admin");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("admin", parsed.value.role);
}

// ===========================================================================
// FormPairs edge cases (tested indirectly)
// ===========================================================================

test "parseForm key without value defaults to bool true" {
    const allocator = std.testing.allocator;
    const T = struct { active: bool };

    var parsed = try parseForm(T, allocator, "active");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.active);
}

test "parseForm empty body for all-optional struct" {
    const allocator = std.testing.allocator;
    const T = struct { name: ?[]const u8, age: ?u32 };

    var parsed = try parseForm(T, allocator, "");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.name == null);
    try std.testing.expect(parsed.value.age == null);
}

// ===========================================================================
// Parsed lifecycle tests
// ===========================================================================

test "Parsed deinit releases all memory" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8, bio: []const u8 };

    // If arena cleanup is broken, the testing allocator will report a leak.
    var parsed = try parseJson(T, allocator, "{\"name\":\"Alice\",\"bio\":\"A person\"}");
    try std.testing.expectEqualStrings("Alice", parsed.value.name);
    try std.testing.expectEqualStrings("A person", parsed.value.bio);
    parsed.deinit();
}

test "multiple parsed instances do not interfere" {
    const allocator = std.testing.allocator;
    const T = struct { name: []const u8 };

    var a = try parseJson(T, allocator, "{\"name\":\"first\"}");
    var b = try parseForm(T, allocator, "name=second");
    defer a.deinit();
    defer b.deinit();

    try std.testing.expectEqualStrings("first", a.value.name);
    try std.testing.expectEqualStrings("second", b.value.name);
}

// ===========================================================================
// Error case tests
// ===========================================================================

test "parseForm invalid integer returns TypeMismatch" {
    const allocator = std.testing.allocator;
    const T = struct { age: u32 };

    const result = parseForm(T, allocator, "age=notanumber");
    try std.testing.expectError(error.TypeMismatch, result);
}

test "parseForm invalid float returns TypeMismatch" {
    const allocator = std.testing.allocator;
    const T = struct { score: f64 };

    const result = parseForm(T, allocator, "score=abc");
    try std.testing.expectError(error.TypeMismatch, result);
}

test "parseForm negative for unsigned returns TypeMismatch" {
    const allocator = std.testing.allocator;
    const T = struct { count: u32 };

    const result = parseForm(T, allocator, "count=-5");
    try std.testing.expectError(error.TypeMismatch, result);
}
