//! JSON 文件存储引擎
//!
//! 基于 JSON 文件实现的数据持久化层。
//! 每个"表"对应一个 `.json` 文件，每个文件包含一个 JSON 数组。
//!
//! # 线程安全
//! 使用 `std.Thread.Mutex` 保护文件读写操作。
//!
//! # 存储格式
//! 文件内容为 JSON 数组：
//! ```json
//! [
//!   {"id": 1, "name": "Alice", "email": "alice@example.com"},
//!   {"id": 2, "name": "Bob", "email": "bob@example.com"}
//! ]
//! ```

const std = @import("std");
const schema_mod = @import("schema.zig");
const query_mod = @import("query.zig");

const TableSchema = schema_mod.TableSchema;
const QueryBuilder = query_mod.QueryBuilder;

/// JSON 文件存储引擎
pub fn JsonStore(comptime T: type, comptime schema: TableSchema) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        data_dir: []const u8,
        table_name: []const u8,
        next_id: u64,
        rows: std.ArrayList(T),
        dirty: bool,

        const Self = @This();

        /// 打开（或创建）一个数据表
        pub fn open(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .data_dir = try allocator.dupe(u8, data_dir),
                .table_name = schema.table_name,
                .next_id = 1,
                .rows = std.ArrayList(T).empty,
                .dirty = false,
            };

            const cwd = std.Io.Dir.cwd();

            // Ensure data directory exists
            cwd.createDirPath(self.io, data_dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            // Try to create the empty file if it doesn't exist
            const file_path = try self.tableFilePath();
            defer allocator.free(file_path);
            _ = cwd.statFile(self.io, file_path, .{}) catch {
                try self.writeFile("[]");
            };

            try self.load();
            return self;
        }

        pub fn close(self: *Self) void {
            self.flush() catch {};
            self.rows.deinit(self.allocator);
            self.allocator.free(self.data_dir);
            self.allocator.destroy(self);
        }

        fn tableFilePath(self: *const Self) ![]const u8 {
            return std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.data_dir, self.table_name });
        }

        fn load(self: *Self) !void {
            const file_path = try self.tableFilePath();
            defer self.allocator.free(file_path);

            const cwd = std.Io.Dir.cwd();
            const file = cwd.openFile(self.io, file_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    self.next_id = 1;
                    return;
                }
                return err;
            };
            defer file.close(self.io);

            const stat = try file.stat(self.io);
            if (stat.size == 0) {
                self.next_id = 1;
                return;
            }

            const content = try cwd.readFileAlloc(self.io, file_path, self.allocator, .limited(100 * 1024 * 1024));
            defer self.allocator.free(content);

            if (content.len <= 2) {
                self.next_id = 1;
                return;
            }

            const parsed = try std.json.parseFromSlice(
                []std.json.Value,
                self.allocator,
                content,
                .{ .allocate = .alloc_always },
            );
            defer parsed.deinit();

            var max_id: u64 = 0;
            for (parsed.value) |jrow| {
                if (jrow != .object) continue;
                const row = try jsonObjectToType(T, self.allocator, jrow.object);
                try self.rows.append(self.allocator, row);

                if (jrow.object.get("id")) |id_val| {
                    if (id_val == .integer) {
                        const row_id: u64 = @intCast(id_val.integer);
                        if (row_id > max_id) max_id = row_id;
                    }
                }
            }
            self.next_id = max_id + 1;
        }

        pub fn flush(self: *Self) !void {
            if (!self.dirty) return;

            const file_path = try self.tableFilePath();
            defer self.allocator.free(file_path);

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);

            try buf.append(self.allocator, '[');
            for (self.rows.items, 0..) |row, i| {
                if (i > 0) try buf.append(self.allocator, ',');
                try buf.append(self.allocator, '\n');
                try buf.append(self.allocator, ' ');
                try buf.append(self.allocator, ' ');

                const json_str = try typeToJsonString(self.allocator, row);
                defer self.allocator.free(json_str);
                try buf.appendSlice(self.allocator, json_str);
            }
            if (self.rows.items.len > 0) try buf.append(self.allocator, '\n');
            try buf.append(self.allocator, ']');

            try self.writeFile(buf.items);
            self.dirty = false;
        }

        fn writeFile(self: *const Self, content: []const u8) !void {
            const file_path = try self.tableFilePath();
            defer self.allocator.free(file_path);

            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
            defer self.allocator.free(tmp_path);

            const cwd = std.Io.Dir.cwd();
            const file = try cwd.createFile(self.io, tmp_path, .{ .truncate = true });
            defer file.close(self.io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(self.io, write_buf[0..]);
            try writer.interface.writeAll(content);
            try writer.flush();
            try std.Io.Dir.rename(cwd, tmp_path, cwd, file_path, self.io);
        }

        // ── CRUD ────────────────────────────────────────

        pub fn insert(self: *Self, row: T) !u64 {
            const id = self.next_id;
            self.next_id += 1;

            var new_row = row;
            setFieldByIdentifier(T, &new_row, "id", id);
            try self.rows.append(self.allocator, new_row);
            self.dirty = true;
            try self.flush();
            return id;
        }

        pub fn findAll(self: *Self, query: *QueryBuilder(T)) ![]T {
            var results = std.ArrayList(T).empty;
            errdefer results.deinit(self.allocator);

            for (self.rows.items) |row| {
                if (query.matches(row)) try results.append(self.allocator, row);
            }
            query.applySorting(&results);
            query.applyPagination(&results);
            return results.toOwnedSlice(self.allocator);
        }

        pub fn findOne(self: *Self, query: *QueryBuilder(T)) !?T {
            for (self.rows.items) |row| {
                if (query.matches(row)) return row;
            }
            return null;
        }

        pub fn findById(self: *Self, id: u64) !?T {
            for (self.rows.items) |row| {
                if (getFieldId(T, row) == id) return row;
            }
            return null;
        }

        pub fn update(self: *Self, query: *QueryBuilder(T)) !usize {
            if (query.data == null) return 0;
            var updated_count: usize = 0;

            for (self.rows.items, 0..) |row, idx| {
                if (query.matches(row)) {
                    var updated = row;
                    if (query.update_fields) |fields| {
                        for (fields) |field_name| {
                            const val = query_mod.getFieldValue(T, query.data.?, field_name);
                            setFieldByIdentifier(T, &updated, field_name, val);
                        }
                    } else {
                        updated = query.data.?;
                    }
                    const orig_id = getFieldId(T, row);
                    setFieldByIdentifier(T, &updated, "id", orig_id);
                    self.rows.items[idx] = updated;
                    updated_count += 1;
                }
            }
            if (updated_count > 0) {
                self.dirty = true;
                try self.flush();
            }
            return updated_count;
        }

        pub fn delete(self: *Self, query: *QueryBuilder(T)) !usize {
            var deleted_count: usize = 0;
            var i: usize = self.rows.items.len;
            while (i > 0) {
                i -= 1;
                if (query.matches(self.rows.items[i])) {
                    _ = self.rows.orderedRemove(i);
                    deleted_count += 1;
                }
            }
            if (deleted_count > 0) {
                self.dirty = true;
                try self.flush();
            }
            return deleted_count;
        }

        pub fn count(self: *Self, query: *QueryBuilder(T)) !usize {
            var c: usize = 0;
            for (self.rows.items) |row| {
                if (query.matches(row)) c += 1;
            }
            return c;
        }

        pub fn all(self: *Self) ![]T {
            const result = try self.allocator.alloc(T, self.rows.items.len);
            @memcpy(result, self.rows.items);
            return result;
        }

        pub fn truncate(self: *Self) !void {
            self.rows.clearRetainingCapacity();
            self.next_id = 1;
            self.dirty = true;
            try self.flush();
        }
    };
}

// ── 序列化辅助 ──────────────────────────────────────

fn jsonObjectToType(comptime T: type, allocator: std.mem.Allocator, obj: std.json.ObjectMap) !T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const default_val = getDefaultForType(field.type);
        if (obj.get(field.name)) |jval| {
            @field(result, field.name) = try jsonValueToField(field.type, allocator, jval);
        } else {
            @field(result, field.name) = default_val;
        }
    }
    return result;
}

fn typeToJsonString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    var buf = std.ArrayList(u8).empty;

    try buf.append(allocator, '{');
    const fields = std.meta.fields(T);
    var first: bool = true;
    inline for (fields) |field| {
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, field.name);
        try buf.appendSlice(allocator, "\": ");
        try appendJsonField(allocator, &buf, @field(value, field.name));
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn jsonValueToField(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            if (value == .integer) return @intCast(value.integer);
            if (value == .float) return @intFromFloat(value.float);
            if (value == .number_string) return std.fmt.parseInt(T, value.number_string, 10) catch 0;
            return 0;
        },
        .float, .comptime_float => {
            if (value == .float) return @floatCast(value.float);
            if (value == .integer) return @floatFromInt(value.integer);
            if (value == .number_string) return std.fmt.parseFloat(T, value.number_string) catch 0.0;
            return 0.0;
        },
        .bool => {
            if (value == .bool) return value.bool;
            return false;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                if (value == .string) return allocator.dupe(u8, value.string) catch @panic("OOM");
                if (value == .null) return &[_]u8{};
                return allocator.dupe(u8, "") catch @panic("OOM");
            }
            @compileError("Unsupported pointer type: " ++ @typeName(T));
        },
        .optional => {
            if (value == .null) return null;
            const Child = std.meta.Child(T);
            return try jsonValueToField(Child, allocator, value);
        },
        .@"enum" => {
            if (value == .string) {
                if (std.meta.stringToEnum(T, value.string)) |e| return e;
            }
            if (value == .integer) {
                return @enumFromInt(@as(std.meta.Tag(T), @intCast(value.integer)));
            }
            return @enumFromInt(@as(std.meta.Tag(T), 0));
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

fn appendJsonField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            var num_buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
            try buf.appendSlice(allocator, s);
        },
        .float, .comptime_float => {
            var num_buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
            try buf.appendSlice(allocator, s);
        },
        .bool => {
            try buf.appendSlice(allocator, if (value) "true" else "false");
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try buf.append(allocator, '"');
                try appendEscapedJson(allocator, buf, value);
                try buf.append(allocator, '"');
            } else if (ptr.size == .one) {
                // *const [N:0]u8 or *const [N]u8 → string, not array
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    const slice: []const u8 = value;
                    try buf.append(allocator, '"');
                    try appendEscapedJson(allocator, buf, slice);
                    try buf.append(allocator, '"');
                } else {
                    try appendJsonField(allocator, buf, value.*);
                }
            } else {
                try buf.appendSlice(allocator, "null");
            }
        },
        .optional => {
            if (value) |v| {
                try appendJsonField(allocator, buf, v);
            } else {
                try buf.appendSlice(allocator, "null");
            }
        },
        .@"enum" => {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, @tagName(value));
            try buf.append(allocator, '"');
        },
        .array => {
            try buf.append(allocator, '[');
            for (value, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendJsonField(allocator, buf, elem);
            }
            try buf.append(allocator, ']');
        },
        .@"struct" => {
            const json_str = try typeToJsonString(allocator, value);
            defer allocator.free(json_str);
            try buf.appendSlice(allocator, json_str);
        },
        else => {
            try buf.appendSlice(allocator, "null");
        },
    }
}

fn appendEscapedJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...7, 11, 14...31 => {
                var hex_buf: [8]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{X:0>2}", .{c});
                try buf.appendSlice(allocator, hex);
            },
            else => try buf.append(allocator, c),
        }
    }
}

fn getDefaultForType(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => 0,
        .float, .comptime_float => 0.0,
        .bool => false,
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) "" else @compileError("Unsupported"),
        .optional => null,
        .@"enum" => @enumFromInt(@as(std.meta.Tag(T), 0)),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

fn setFieldByIdentifier(comptime T: type, instance: *T, field_name: []const u8, value: anytype) void {
    inline for (std.meta.fields(T)) |f| {
        if (std.mem.eql(u8, f.name, field_name)) {
            const ValueT = @TypeOf(value);
            switch (@typeInfo(ValueT)) {
                .int, .comptime_int => {
                    switch (@typeInfo(f.type)) {
                        .int, .comptime_int => @field(instance, f.name) = @intCast(value),
                        .float, .comptime_float => @field(instance, f.name) = @floatFromInt(value),
                        else => {},
                    }
                },
                else => {
                    // FieldValue union
                    switch (value) {
                        .integer => |v| {
                            switch (@typeInfo(f.type)) {
                                .int, .comptime_int => @field(instance, f.name) = @intCast(v),
                                .float, .comptime_float => @field(instance, f.name) = @floatFromInt(v),
                                else => {},
                            }
                        },
                        .string => |v| {
                            if (@typeInfo(f.type) == .pointer) {
                                @field(instance, f.name) = v;
                            }
                        },
                        .boolean => |v| {
                            if (f.type == bool) @field(instance, f.name) = v;
                        },
                        .float => |v| {
                            switch (@typeInfo(f.type)) {
                                .float, .comptime_float => @field(instance, f.name) = @floatCast(v),
                                .int, .comptime_int => @field(instance, f.name) = @intFromFloat(v),
                                else => {},
                            }
                        },
                        else => {},
                    }
                },
            }
            return;
        }
    }
}

fn getFieldId(comptime T: type, value: T) u64 {
    if (@hasField(T, "id")) {
        return @intCast(@field(value, "id"));
    }
    @compileError("Type has no 'id' field: " ++ @typeName(T));
}

// ── 测试 ──────────────────────────────────────────

test "JsonStore insert and find" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const User = struct {
        id: u64 = 0,
        name: []const u8,
        email: []const u8,
    };

    const schema = TableSchema{
        .table_name = "test_users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "name", .field_type = .string },
            .{ .name = "email", .field_type = .string },
        },
    };

    const Store = JsonStore(User, schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close();
    }

    const id = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    try std.testing.expect(id > 0);

    const found = try store.findById(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice", found.?.name);
}

test "JsonStore update and delete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const User = struct {
        id: u64 = 0,
        name: []const u8,
    };

    const schema = TableSchema{
        .table_name = "test_users2",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true } },
            .{ .name = "name", .field_type = .string },
        },
    };

    const Store = JsonStore(User, schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close();
    }

    const id = try store.insert(.{ .id = 0, .name = "Bob" });
    try std.testing.expectEqual(@as(u64, 1), id);

    var qb = QueryBuilder(User).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
    _ = qb.update(.{ .id = id, .name = "Bobby" }, &.{"name"});

    const updated = try store.update(&qb);
    try std.testing.expectEqual(@as(usize, 1), updated);

    const found = try store.findById(id);
    try std.testing.expectEqualStrings("Bobby", found.?.name);

    // Delete
    var qd = QueryBuilder(User).init(allocator);
    defer qd.deinit();
    _ = qd.where(.Eq, "id", .{ .integer = @intCast(id) });
    const deleted = try store.delete(&qd);
    try std.testing.expectEqual(@as(usize, 1), deleted);

    const gone = try store.findById(id);
    try std.testing.expect(gone == null);
}
