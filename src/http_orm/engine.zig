//! JSON 文件存储引擎
//!
//! 基于 JSON 文件实现的数据持久化层。
//! 每个"表"对应一个 `.json` 文件，每个文件包含一个 JSON 数组。
//!
//! # 线程安全
//! 所有公开方法通过 `std.Io.Mutex` 互斥保护 `rows`/`next_id` 与文件写入，
//! 可被并发请求安全共享。
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
const FieldValue = schema_mod.FieldValue;
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
        /// 主键 id -> rows 下标，提供 O(1) 的 findById
        id_index: std.AutoHashMap(u64, usize) = undefined,
        /// 保护并发读写（rows、next_id、文件 flush）
        mutex: std.Io.Mutex = .init,

        const Self = @This();

        fn lock(self: *Self) !void {
            return self.mutex.lock(self.io);
        }

        fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        /// 打开（或创建）一个数据表
        pub fn open(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const dir_copy = try allocator.dupe(u8, data_dir);
            errdefer allocator.free(dir_copy);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .data_dir = dir_copy,
                .table_name = schema.table_name,
                .next_id = 1,
                .rows = std.ArrayList(T).empty,
                .dirty = false,
                .id_index = std.AutoHashMap(u64, usize).init(allocator),
            };
            errdefer {
                self.rows.deinit(allocator);
                self.id_index.deinit();
            }

            const cwd = std.Io.Dir.cwd();

            // Ensure data directory exists
            try cwd.createDirPath(self.io, data_dir);

            // Try to create the empty file if it doesn't exist
            const file_path = try self.tableFilePath();
            defer allocator.free(file_path);
            _ = cwd.statFile(self.io, file_path, .{}) catch {
                try self.writeFile("[]");
            };

            try self.load();
            return self;
        }

        /// 关闭存储：先持久化未写入的数据，再释放资源。
        /// 若 flush 失败会向上传播错误 — 由调用方决定如何处理。
        pub fn close(self: *Self) !void {
            try self.lock();
            errdefer self.unlock();
            try self.flushUnlocked();
            // 修复 C2：释放所有行的字符串字段。
            for (self.rows.items) |row| {
                freeStringFields(T, self.allocator, row);
            }
            self.rows.deinit(self.allocator);
            self.id_index.deinit();
            self.allocator.free(self.data_dir);
            // mutex 是结构体的一部分，必须先解锁再销毁
            self.unlock();
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
            errdefer {
                // 修复 M3：load 中途失败时释放已加载行的字符串字段，避免汄漏。
                for (self.rows.items) |row| freeStringFields(T, self.allocator, row);
                self.rows.clearRetainingCapacity();
                self.id_index.clearRetainingCapacity();
            }
            for (parsed.value) |jrow| {
                if (jrow != .object) continue;
                const row = try jsonObjectToType(T, self.allocator, jrow.object);
                try self.rows.append(self.allocator, row);
                const rows_len = self.rows.items.len;

                if (jrow.object.get("id")) |id_val| {
                    if (id_val == .integer) {
                        // 修复 H2：负数/越界 id 不直接 @intCast panic，优雅报错。
                        const row_id: u64 = std.math.cast(u64, id_val.integer) orelse return error.CorruptData;
                        if (row_id > max_id) max_id = row_id;
                        try self.id_index.put(row_id, rows_len - 1);
                    }
                }
            }
            self.next_id = max_id + 1;
        }

        /// 持久化未写入的数据（公开入口，加锁）。
        pub fn flush(self: *Self) !void {
            try self.lock();
            defer self.unlock();
            try self.flushUnlocked();
        }

        /// 持久化未写入的数据（调用方必须已持有锁）。
        fn flushUnlocked(self: *Self) !void {
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

            // 修复 H3：tmp 路径加随机 + 地址后缀，避免同进程多实例/多进程并发写
            // 同一 .tmp 互相覆盖；rename 前 fsync 文件内容，避免崩溃后数据丢失。
            var rand_suffix: [8]u8 = undefined;
            self.io.random(&rand_suffix);
            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.{x}.{x}.tmp", .{ file_path, @intFromPtr(self), std.mem.readInt(u64, &rand_suffix, .little) });
            defer self.allocator.free(tmp_path);

            const cwd = std.Io.Dir.cwd();
            const file = try cwd.createFile(self.io, tmp_path, .{ .truncate = true });
            errdefer cwd.deleteFile(self.io, tmp_path) catch {};
            {
                defer file.close(self.io);
                var write_buf: [4096]u8 = undefined;
                var writer = file.writer(self.io, write_buf[0..]);
                try writer.interface.writeAll(content);
                try writer.flush();
                // rename 前落盘，保证 rename 后即使崩溃也不会丢掉内容。
                file.sync(self.io) catch {};
            }
            try std.Io.Dir.rename(cwd, tmp_path, cwd, file_path, self.io);
        }

        // ── CRUD ────────────────────────────────────────

        pub fn insert(self: *Self, row: T) !u64 {
            try self.lock();
            defer self.unlock();

            const id = self.next_id;
            self.next_id += 1;

            var new_row = row;
            applyDefaults(&new_row);
            setFieldByIdentifier(T, &new_row, "id", id);
            // 唯一约束校验（与其它已存在行比较）
            try self.checkUnique(new_row, null);

            // 修复 C1：deep-copy 字符串字段到 self.allocator，与 load 的所有权模型一致。
            try dupStringFields(T, self.allocator, &new_row);
            errdefer freeStringFields(T, self.allocator, new_row);

            try self.rows.append(self.allocator, new_row);
            try self.id_index.put(id, self.rows.items.len - 1);
            self.dirty = true;
            return id;
        }

        pub fn findAll(self: *Self, query: *QueryBuilder(T)) ![]T {
            try self.lock();
            defer self.unlock();

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
            try self.lock();
            defer self.unlock();

            for (self.rows.items) |row| {
                if (query.matches(row)) return row;
            }
            return null;
        }

        pub fn findById(self: *Self, id: u64) !?T {
            try self.lock();
            defer self.unlock();

            const idx = self.id_index.get(id) orelse return null;
            return self.rows.items[idx];
        }

        pub fn update(self: *Self, query: *QueryBuilder(T)) !usize {
            try self.lock();
            errdefer self.unlock();

            if (query.data == null) {
                self.unlock();
                return 0;
            }

            // First pass: collect indices of rows that match the query.
            // We hold the lock via errdefer above, so the early returns below
            // must call self.unlock() explicitly.
            var matched_indices = std.ArrayList(usize).empty;
            defer matched_indices.deinit(self.allocator);
            for (self.rows.items, 0..) |row, idx| {
                if (query.matches(row)) try matched_indices.append(self.allocator, idx);
            }
            if (matched_indices.items.len == 0) {
                self.unlock();
                return 0;
            }

            // For each unique field touched by update_fields, build a set of
            // existing values EXCLUDING the rows being updated, so the conflict
            // check is O(1) per field instead of O(N) per row per field.
            // Keys live in a short-lived arena so we don't have to track them.
            const updating_fields = query.update_fields orelse &[_][]const u8{};
            var key_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer key_arena.deinit();
            const key_alloc = key_arena.allocator();

            var unique_sets = std.ArrayList(std.StringHashMap(void)).empty;
            defer {
                for (unique_sets.items) |*m| m.deinit();
                unique_sets.deinit(self.allocator);
            }
            var unique_field_names = std.ArrayList([]const u8).empty;
            defer unique_field_names.deinit(self.allocator);

            if (query.update_fields != null) {
                for (updating_fields) |field_name| {
                    const fd = schema.field(field_name) orelse continue;
                    if (!fd.constraints.unique) continue;
                    try unique_field_names.append(self.allocator, field_name);
                    var set = std.StringHashMap(void).init(self.allocator);
                    errdefer set.deinit();
                    outer: for (self.rows.items, 0..) |row, idx| {
                        // skip rows that are being updated
                        for (matched_indices.items) |mi| {
                            if (mi == idx) continue :outer;
                        }
                        const fv = query_mod.getFieldValue(T, row, field_name);
                        const key = try fieldValuesKey(key_alloc, fv);
                        try set.put(key, {});
                    }
                    try unique_sets.append(self.allocator, set);
                }
            }

            // Second pass: apply updates to matched rows and check unique conflicts.
            var updated_count: usize = 0;
            for (matched_indices.items) |idx| {
                const row = self.rows.items[idx];
                var updated = row;
                if (query.update_fields) |fields| {
                    for (fields) |field_name| {
                        const val = query_mod.getFieldValue(T, query.data.?, field_name);
                        setFieldByIdentifier(T, &updated, field_name, val);
                    }
                    // Check unique constraints against the pre-built sets.
                    for (unique_field_names.items, 0..) |ufn, ui| {
                        const new_val = query_mod.getFieldValue(T, updated, ufn);
                        const key = try fieldValuesKey(key_alloc, new_val);
                        if (unique_sets.items[ui].contains(key)) {
                            // 不显式 unlock——让 errdefer 处理（避免双重解锁）
                            return error.UniqueViolation;
                        }
                        // Add the new value to the set so subsequent matched
                        // rows can't collide with this row's new value either.
                        try unique_sets.items[ui].put(key, {});
                    }
                } else {
                    updated = query.data.?;
                }
                const orig_id = getFieldId(T, row);
                setFieldByIdentifier(T, &updated, "id", orig_id);
                // 修复 C1/C2：调和字符串字段所有权。对每个发生变化的字符串
                // 字段：释放旧（已 owned）值、dup 新值入 self.allocator，避免旧值泄漏
                // 与新值指向调用方内存而悬空。
                try reconcileStringFields(T, self.allocator, row, &updated);
                self.rows.items[idx] = updated;
                updated_count += 1;
            }

            // 修复 C3：dirty 必须在锁内写（其他地方都在锁内访问），
            // 否则与并发 flush 竞态可能丢失一次持久化。
            if (updated_count > 0) self.dirty = true;
            self.unlock();
            return updated_count;
        }

        pub fn delete(self: *Self, query: *QueryBuilder(T)) !usize {
            try self.lock();
            defer self.unlock();

            // First pass: collect indices to delete (preserving ascending order
            // via a reverse scan so the indices array is sorted ascending).
            var to_delete = std.ArrayList(usize).empty;
            defer to_delete.deinit(self.allocator);
            for (self.rows.items, 0..) |row, idx| {
                if (query.matches(row)) try to_delete.append(self.allocator, idx);
            }
            const deleted_count = to_delete.items.len;
            if (deleted_count == 0) return 0;

            // 修复 C2：释放被删除行的字符串字段。
            for (to_delete.items) |idx| {
                freeStringFields(T, self.allocator, self.rows.items[idx]);
            }

            // Second pass: compact-copy all rows that are NOT being deleted.
            // to_delete is in ascending order, so we can walk it with a cursor.
            var kept = std.ArrayList(T).empty;
            errdefer kept.deinit(self.allocator);
            var di: usize = 0;
            for (self.rows.items, 0..) |row, idx| {
                if (di < to_delete.items.len and to_delete.items[di] == idx) {
                    di += 1;
                    continue;
                }
                try kept.append(self.allocator, row);
            }
            self.rows.deinit(self.allocator);
            self.rows = kept;

            // Rebuild id_index in one O(N) pass instead of decrementing per row.
            self.id_index.clearRetainingCapacity();
            for (self.rows.items, 0..) |row, idx| {
                try self.id_index.put(getFieldId(T, row), idx);
            }

            self.dirty = true;
            return deleted_count;
        }

        pub fn count(self: *Self, query: *QueryBuilder(T)) !usize {
            try self.lock();
            defer self.unlock();

            var c: usize = 0;
            for (self.rows.items) |row| {
                if (query.matches(row)) c += 1;
            }
            return c;
        }

        pub fn all(self: *Self) ![]T {
            try self.lock();
            defer self.unlock();

            const result = try self.allocator.alloc(T, self.rows.items.len);
            @memcpy(result, self.rows.items);
            return result;
        }

        pub fn truncate(self: *Self) !void {
            try self.lock();
            defer self.unlock();

            // 修复 C2：释放所有行的字符串字段。
            for (self.rows.items) |row| {
                freeStringFields(T, self.allocator, row);
            }
            self.rows.clearRetainingCapacity();
            self.id_index.clearRetainingCapacity();
            self.next_id = 1;
            self.dirty = true;
        }

        // ── 易用性增强（新增便捷方法）──────────────────

        /// 按任意字段查找单条（Equals）。字段值自动转换为 FieldValue。
        pub fn findBy(self: *Self, comptime field: []const u8, value: anytype) !?T {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, field, query_mod.toFieldValue(value));
            return self.findOne(&qb);
        }

        /// 按主键更新整行（id 自动保留）。返回是否更新到记录。
        pub fn updateById(self: *Self, id: u64, data: T) !bool {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
            _ = qb.update(data, null);
            const n = try self.update(&qb);
            return n > 0;
        }

        /// 按主键删除。返回是否删除到记录。
        pub fn deleteById(self: *Self, id: u64) !bool {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
            _ = qb.delete();
            const n = try self.delete(&qb);
            return n > 0;
        }

        /// 分页查询（按 id 升序）。page 从 0 开始。
        pub fn paginate(self: *Self, page: usize, per_page: usize) ![]T {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.orderBy("id", .Asc).limit(per_page).offset(page * per_page);
            return self.findAll(&qb);
        }

        // ── 内部辅助 ────────────────────────────────

        /// 判断两个 FieldValue 是否相等（字符串按内容比较）。
        fn fieldValuesEqual(a: FieldValue, b: FieldValue) bool {
            return switch (a) {
                .integer => |x| b == .integer and x == b.integer,
                .string => |x| b == .string and std.mem.eql(u8, x, b.string),
                .float => |x| b == .float and x == b.float,
                .boolean => |x| b == .boolean and x == b.boolean,
                .datetime => |x| b == .datetime and x == b.datetime,
                .json_text => |x| b == .json_text and std.mem.eql(u8, x, b.json_text),
                .text => |x| b == .text and std.mem.eql(u8, x, b.text),
            };
        }

        /// Produce a heap-allocated, comparable key string for a FieldValue,
        /// used to populate unique-constraint hash sets. Caller frees the key.
        fn fieldValuesKey(allocator: std.mem.Allocator, v: FieldValue) ![]u8 {
            switch (v) {
                .integer => |x| return std.fmt.allocPrint(allocator, "i:{d}", .{x}),
                .string => |x| return std.fmt.allocPrint(allocator, "s:{x}", .{x}),
                .float => |x| return std.fmt.allocPrint(allocator, "f:{d}", .{x}),
                .boolean => |x| return std.fmt.allocPrint(allocator, "b:{}", .{x}),
                .datetime => |x| return std.fmt.allocPrint(allocator, "d:{d}", .{x}),
                .json_text => |x| return std.fmt.allocPrint(allocator, "j:{x}", .{x}),
                .text => |x| return std.fmt.allocPrint(allocator, "t:{x}", .{x}),
            }
        }

        /// 校验唯一约束：row 的 unique 字段不得与（除 except_id 外）其它行冲突。
        fn checkUnique(self: *const Self, row: T, except_id: ?u64) !void {
            for (schema.fields) |f| {
                if (!f.constraints.unique) continue;
                const v = query_mod.getFieldValue(T, row, f.name);
                for (self.rows.items) |other| {
                    if (except_id != null and getFieldId(T, other) == except_id.?) continue;
                    if (fieldValuesEqual(v, query_mod.getFieldValue(T, other, f.name))) {
                        return error.UniqueViolation;
                    }
                }
            }
        }

        /// 插入时：对设置了 default_value 且当前为零值的字段填入默认值。
        fn applyDefaults(row: *T) void {
            for (schema.fields) |f| {
                if (f.constraints.default_value) |dv| {
                    const cur = query_mod.getFieldValue(T, row.*, f.name);
                    if (isZeroValue(cur)) {
                        query_mod.setFieldFromValue(T, row, f.name, dv);
                    }
                }
            }
        }

        fn isZeroValue(v: FieldValue) bool {
            return switch (v) {
                .integer => |x| x == 0,
                .string => |x| x.len == 0,
                .float => |x| x == 0.0,
                .boolean => |x| !x,
                .datetime => |x| x == 0,
                .json_text => |x| x.len == 0,
                .text => |x| x.len == 0,
            };
        }
    };
}

// ── 序列化辅助 ──────────────────────────────────────

fn jsonObjectToType(comptime T: type, allocator: std.mem.Allocator, obj: std.json.ObjectMap) !T {
    var result: T = undefined;
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (struct_info.field_names, struct_info.field_types) |name, typ| {
        const default_val = getDefaultForType(typ);
        if (obj.get(name)) |jval| {
            @field(result, name) = try jsonValueToField(typ, allocator, jval);
        } else {
            @field(result, name) = default_val;
        }
    }
    return result;
}

fn typeToJsonString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    var buf = std.ArrayList(u8).empty;

    try buf.append(allocator, '{');
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (struct_info.field_names, 0..) |name, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\": ");
        try appendJsonField(allocator, &buf, @field(value, name));
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
                return @fromBackingInt(@intCast(@as(std.meta.Tag(T), @intCast(value.integer))));
            }
            return @fromBackingInt(@intCast(@as(std.meta.Tag(T), 0)));
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
        .@"enum" => @fromBackingInt(@intCast(@as(std.meta.Tag(T), 0))),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

fn setFieldByIdentifier(comptime T: type, instance: *T, field_name: []const u8, value: anytype) void {
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (struct_info.field_names, struct_info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, fname, field_name)) {
            const ValueT = @TypeOf(value);
            switch (@typeInfo(ValueT)) {
                .int, .comptime_int => {
                    switch (@typeInfo(ftype)) {
                        .int, .comptime_int => @field(instance, fname) = @intCast(value),
                        .float, .comptime_float => @field(instance, fname) = @floatFromInt(value),
                        else => {},
                    }
                },
                else => {
                    // FieldValue union
                    switch (value) {
                        .integer => |v| {
                            switch (@typeInfo(ftype)) {
                                .int, .comptime_int => @field(instance, fname) = @intCast(v),
                                .float, .comptime_float => @field(instance, fname) = @floatFromInt(v),
                                else => {},
                            }
                        },
                        .string => |v| {
                            if (@typeInfo(ftype) == .pointer) {
                                @field(instance, fname) = v;
                            }
                        },
                        .boolean => |v| {
                            if (ftype == bool) @field(instance, fname) = v;
                        },
                        .float => |v| {
                            switch (@typeInfo(ftype)) {
                                .float, .comptime_float => @field(instance, fname) = @floatCast(v),
                                .int, .comptime_int => @field(instance, fname) = @intFromFloat(v),
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

/// dup 行中所有字符串字段（`[]const u8` 与 `?[]const u8`）到 allocator（修复 C1：insert 不能存储
/// 调用方内存的切片，否则调用方 arena 回收后悬空 / flush 写出损坏 JSON）。
/// 与 load 的所有权模型（逐字段 dup）一致，便于 delete/truncate/close 统一释放。
fn dupStringFields(comptime T: type, allocator: std.mem.Allocator, row: *T) !void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isConstU8Slice(ftype)) {
            @field(row.*, fname) = try allocator.dupe(u8, @field(row.*, fname));
        } else if (comptime isOptionalConstU8Slice(ftype)) {
            if (@field(row.*, fname)) |s| {
                @field(row.*, fname) = try allocator.dupe(u8, s);
            }
        }
    }
}

/// 释放行中所有字符串字段（`[]const u8` 与 `?[]const u8`）（修复 C2：字符串在
/// delete/truncate/close 时汄漏；optional 字段之前被漏掉）。
fn freeStringFields(comptime T: type, allocator: std.mem.Allocator, row: T) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isConstU8Slice(ftype)) {
            allocator.free(@field(row, fname));
        } else if (comptime isOptionalConstU8Slice(ftype)) {
            if (@field(row, fname)) |s| allocator.free(s);
        }
    }
}

fn isConstU8Slice(comptime FT: type) bool {
    return switch (@typeInfo(FT)) {
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };
}

/// 识别 `?[]const u8` / `?[]u8`（修复 C2：之前 isConstU8Slice 不认 optional，
/// 导致可选字符串字段 insert 悬空、close/delete 汄漏、update 不调和）。
fn isOptionalConstU8Slice(comptime FT: type) bool {
    return switch (@typeInfo(FT)) {
        .optional => |opt| isConstU8Slice(opt.child),
        else => false,
    };
}

/// 调和 update 时的字符串所有权（修复 C1/C2）。
/// 对每个字符串字段（含 optional）：若 updated 的指针与 original 不同（即被覆写为
/// 调用方内存），则释放 original（已 owned）、把新值 dup 入 allocator。
/// 未变的字段保留 original 的 owned 指针（updated 与 original 共享）。
fn reconcileStringFields(comptime T: type, allocator: std.mem.Allocator, original: T, updated: *T) !void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isConstU8Slice(ftype)) {
            const orig_slice = @field(original, fname);
            const new_slice = @field(updated.*, fname);
            if (orig_slice.ptr != new_slice.ptr) {
                const dup = try allocator.dupe(u8, new_slice);
                allocator.free(orig_slice);
                @field(updated.*, fname) = dup;
            }
        } else if (comptime isOptionalConstU8Slice(ftype)) {
            const orig_opt = @field(original, fname);
            const new_opt = @field(updated.*, fname);
            // 四种情况：null→null(不动)、null→值(dup 新)、值→null(释放旧)、值→值(指针不同则释旧 dup 新)。
            if (orig_opt) |orig_slice| {
                if (new_opt) |new_slice| {
                    if (orig_slice.ptr != new_slice.ptr) {
                        const dup = try allocator.dupe(u8, new_slice);
                        allocator.free(orig_slice);
                        @field(updated.*, fname) = dup;
                    }
                } else {
                    allocator.free(orig_slice);
                }
            } else if (new_opt) |new_slice| {
                @field(updated.*, fname) = try allocator.dupe(u8, new_slice);
            }
        }
    }
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
        store.close() catch {};
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
        store.close() catch {};
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

// ── Comprehensive tests ─────────────────────────────

const TestUser = struct {
    id: u64 = 0,
    name: []const u8,
    email: []const u8,
};

const test_schema = TableSchema{
    .table_name = "test_engine_users",
    .fields = &.{
        .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
        .{ .name = "name", .field_type = .string },
        .{ .name = "email", .field_type = .string },
    },
};

test "findAll with no conditions returns all rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    // All three users should be present
    var found_alice = false;
    var found_bob = false;
    var found_charlie = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.name, "Alice")) found_alice = true;
        if (std.mem.eql(u8, r.name, "Bob")) found_bob = true;
        if (std.mem.eql(u8, r.name, "Charlie")) found_charlie = true;
    }
    try std.testing.expect(found_alice);
    try std.testing.expect(found_bob);
    try std.testing.expect(found_charlie);
    _ = arena_alloc; // suppress unused warning
}

test "findAll with where conditions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "Bob" });

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("Bob", results[0].name);
    try std.testing.expectEqualStrings("bob@test.com", results[0].email);
}

test "findAll with Neq condition" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Neq, "name", .{ .string = "Alice" });

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("Bob", results[0].name);
}

test "findOne found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "Alice" });

    const result = try store.findOne(&qb);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Alice", result.?.name);
    try std.testing.expectEqualStrings("alice@test.com", result.?.email);
}

test "findOne not found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "NonExistent" });

    const result = try store.findOne(&qb);
    try std.testing.expect(result == null);
}

test "findById found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id1 = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    const found = try store.findById(id1);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice", found.?.name);
}

test "findById not found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    const found = try store.findById(9999);
    try std.testing.expect(found == null);
}

test "count with no conditions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();

    const c = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, 2), c);
}

test "count with where conditions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Alice2", .email = "alice2@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "Alice" });

    const c = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, 1), c);
}

test "count returns 0 when no matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "NonExistent" });

    const c = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, 0), c);
}

test "all returns copy of all rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    const all_rows = try store.all();
    defer allocator.free(all_rows);

    try std.testing.expectEqual(@as(usize, 2), all_rows.len);
    try std.testing.expectEqualStrings("Alice", all_rows[0].name);
    try std.testing.expectEqualStrings("Bob", all_rows[1].name);
}

test "truncate clears all data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    try store.truncate();

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    const c = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, 0), c);
}

test "truncate resets auto-increment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    try store.truncate();

    // After truncate, next insert should get id=1 again
    const id = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });
    try std.testing.expectEqual(@as(u64, 1), id);
}

test "insert auto-incrementing ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id1 = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    const id2 = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    const id3 = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "update with update_fields partial update" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
    _ = qb.update(.{ .id = id, .name = "Alice Updated", .email = "alice@test.com" }, &.{"name"});

    const updated = try store.update(&qb);
    try std.testing.expectEqual(@as(usize, 1), updated);

    const found = try store.findById(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Alice Updated", found.?.name);
    try std.testing.expectEqualStrings("alice@test.com", found.?.email);
}

test "update multiple rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    // Update all rows with id > 0 (all of them)
    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Gt, "id", .{ .integer = 0 });
    _ = qb.update(.{ .id = 0, .name = "Updated", .email = "updated@test.com" }, &.{"email"});

    const updated = try store.update(&qb);
    try std.testing.expectEqual(@as(usize, 3), updated);

    const all_rows = try store.all();
    defer allocator.free(all_rows);
    for (all_rows) |row| {
        try std.testing.expectEqualStrings("updated@test.com", row.email);
    }
}

test "delete removes matching rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    const id2 = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = @intCast(id2) });

    const deleted = try store.delete(&qb);
    try std.testing.expectEqual(@as(usize, 1), deleted);

    var count_qb = QueryBuilder(TestUser).init(allocator);
    defer count_qb.deinit();
    const remaining = try store.count(&count_qb);
    try std.testing.expectEqual(@as(usize, 2), remaining);

    const gone = try store.findById(id2);
    try std.testing.expect(gone == null);
}

test "delete no match returns 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = 9999 });

    const deleted = try store.delete(&qb);
    try std.testing.expectEqual(@as(usize, 0), deleted);
}

test "findAll with sorting ascending" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("name", .Asc);

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("Alice", results[0].name);
    try std.testing.expectEqualStrings("Bob", results[1].name);
    try std.testing.expectEqualStrings("Charlie", results[2].name);
}

test "findAll with sorting descending" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("name", .Desc);

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("Charlie", results[0].name);
    try std.testing.expectEqualStrings("Bob", results[1].name);
    try std.testing.expectEqualStrings("Alice", results[2].name);
}

test "empty store findAll returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "empty store count returns 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();

    const c = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, 0), c);
}

test "empty store all returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const all_rows = try store.all();
    defer allocator.free(all_rows);

    try std.testing.expectEqual(@as(usize, 0), all_rows.len);
}

test "empty store findById returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const found = try store.findById(1);
    try std.testing.expect(found == null);
}

test "empty store findOne returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "name", .{ .string = "Nobody" });

    const result = try store.findOne(&qb);
    try std.testing.expect(result == null);
}

test "update with no match returns 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Eq, "id", .{ .integer = 9999 });
    _ = qb.update(.{ .id = 0, .name = "Ghost", .email = "ghost@test.com" }, &.{"name"});

    const updated = try store.update(&qb);
    try std.testing.expectEqual(@as(usize, 0), updated);
}

test "all returns independent copy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    const all_rows1 = try store.all();
    defer allocator.free(all_rows1);

    const all_rows2 = try store.all();
    defer allocator.free(all_rows2);

    // Both should have the same content but be independent allocations
    try std.testing.expectEqual(all_rows1.len, all_rows2.len);
    try std.testing.expectEqualStrings(all_rows1[0].name, all_rows2[0].name);
    // Pointer addresses should differ (independent copy)
    try std.testing.expect(all_rows1.ptr != all_rows2.ptr);
}

test "flush persists data to disk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    // Explicit flush (already done by insert, but test the API)
    try store.flush();

    // Re-open with arena to avoid tracking string allocs from json deserialization
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var store2 = try Store.open(arena.allocator(), io, ".test_data");
    defer {
        store2.truncate() catch {};
        store2.close() catch {};
    }

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    const c = try store2.count(&qb);
    try std.testing.expectEqual(@as(usize, 2), c);
}

test "multiple inserts and findAll with limit and offset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Dave", .email = "dave@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Eve", .email = "eve@test.com" });

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.orderBy("name", .Asc).limit(2).offset(1);

    const results = try store.findAll(&qb);
    defer allocator.free(results);

    // Sorted: Alice, Bob, Charlie, Dave, Eve
    // offset=1 skips Alice, limit=2 gives Bob and Charlie
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Bob", results[0].name);
    try std.testing.expectEqualStrings("Charlie", results[1].name);
}

test "delete all rows with no conditions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });

    // No where conditions matches all rows
    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.delete();

    const deleted = try store.delete(&qb);
    try std.testing.expectEqual(@as(usize, 2), deleted);

    var count_qb = QueryBuilder(TestUser).init(allocator);
    defer count_qb.deinit();
    const c = try store.count(&count_qb);
    try std.testing.expectEqual(@as(usize, 0), c);
}

test "insert preserves field values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });

    const found = try store.findById(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, id), found.?.id);
    try std.testing.expectEqualStrings("Alice", found.?.name);
    try std.testing.expectEqualStrings("alice@test.com", found.?.email);
}

test "Gte and Lte operators" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Bob", .email = "bob@test.com" });
    _ = try store.insert(.{ .id = 0, .name = "Charlie", .email = "charlie@test.com" });

    // id >= 2 should match Bob (id=2) and Charlie (id=3)
    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Gte, "id", .{ .integer = 2 });

    const results = try store.findAll(&qb);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // id <= 1 should match Alice (id=1)
    var qb2 = QueryBuilder(TestUser).init(allocator);
    defer qb2.deinit();
    _ = qb2.where(.Lte, "id", .{ .integer = 1 });

    const results2 = try store.findAll(&qb2);
    defer allocator.free(results2);
    try std.testing.expectEqual(@as(usize, 1), results2.len);
    try std.testing.expectEqualStrings("Alice", results2[0].name);
}

test "concurrent inserts are thread-safe" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const num_threads: usize = 4;
    const per_thread: usize = 25;

    const ThreadCtx = struct {
        store: *Store,
    };

    var ctx = ThreadCtx{ .store = store };
    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |t| {
        threads[t] = try std.Thread.spawn(.{}, struct {
            fn run(c: *ThreadCtx) void {
                for (0..per_thread) |_| {
                    _ = c.store.insert(.{ .id = 0, .name = "t", .email = "e@t.com" }) catch return;
                }
            }
        }.run, .{&ctx});
    }
    for (threads) |th| th.join();

    var qb = QueryBuilder(TestUser).init(allocator);
    defer qb.deinit();
    const total = try store.count(&qb);
    try std.testing.expectEqual(@as(usize, num_threads * per_thread), total);

    // 所有 id 应唯一且连续（1..N），证明 next_id 自增在并发下无竞争
    const all_rows = try store.all();
    defer allocator.free(all_rows);
    for (all_rows, 0..) |row, i| {
        try std.testing.expectEqual(@as(u64, i + 1), row.id);
    }
}

test "findById uses index and survives deletions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const a = try store.insert(.{ .id = 0, .name = "A", .email = "a@x.com" });
    const b = try store.insert(.{ .id = 0, .name = "B", .email = "b@x.com" });
    const c = try store.insert(.{ .id = 0, .name = "C", .email = "c@x.com" });

    try std.testing.expectEqualStrings("A", (try store.findById(a)).?.name);
    try std.testing.expectEqualStrings("B", (try store.findById(b)).?.name);
    try std.testing.expectEqualStrings("C", (try store.findById(c)).?.name);

    // 删除中间行后，主键索引必须保持一致
    try std.testing.expect((try store.deleteById(b)));
    try std.testing.expect((try store.findById(b)) == null);
    try std.testing.expectEqualStrings("A", (try store.findById(a)).?.name);
    try std.testing.expectEqualStrings("C", (try store.findById(c)).?.name);
}

test "updateById replaces row and preserves id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id = try store.insert(.{ .id = 0, .name = "A", .email = "a@x.com" });
    try std.testing.expect((try store.updateById(id, .{ .id = id, .name = "A2", .email = "a2@x.com" })));
    const f = try store.findById(id);
    try std.testing.expectEqualStrings("A2", f.?.name);
    try std.testing.expectEqualStrings("a2@x.com", f.?.email);
    try std.testing.expectEqual(@as(u64, id), f.?.id);

    try std.testing.expect(!(try store.updateById(9999, .{ .id = 9999, .name = "x", .email = "x@x.com" })));
}

test "findBy finds by arbitrary field" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "Alice", .email = "alice@x.com" });
    const f = try store.findBy("email", "alice@x.com");
    try std.testing.expect(f != null);
    try std.testing.expectEqualStrings("Alice", f.?.name);
    const none = try store.findBy("email", "nobody@x.com");
    try std.testing.expect(none == null);
}

test "paginate returns id-ordered pages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    var i: u64 = 0;
    while (i < 10) : (i += 1) _ = try store.insert(.{ .id = 0, .name = "u", .email = "e@x.com" });

    const p0 = try store.paginate(0, 4);
    defer allocator.free(p0);
    try std.testing.expectEqual(@as(usize, 4), p0.len);
    try std.testing.expectEqual(@as(u64, 1), p0[0].id);

    const p1 = try store.paginate(1, 4);
    defer allocator.free(p1);
    try std.testing.expectEqual(@as(u64, 5), p1[0].id);

    const p2 = try store.paginate(2, 4);
    defer allocator.free(p2);
    try std.testing.expectEqual(@as(usize, 2), p2.len);
    try std.testing.expectEqual(@as(u64, 9), p2[0].id);
}

test "unique constraint enforced on insert" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, email: []const u8 };
    const sch = TableSchema{
        .table_name = "uniq_users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "email", .field_type = .string, .constraints = .{ .unique = true } },
        },
    };
    const Store = JsonStore(U, sch);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .email = "dup@x.com" });
    try std.testing.expectError(error.UniqueViolation, store.insert(.{ .id = 0, .email = "dup@x.com" }));
}

test "default_value applied on insert" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, role: []const u8 };
    const sch = TableSchema{
        .table_name = "def_users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "role", .field_type = .string, .constraints = .{ .default_value = FieldValue{ .string = "user" } } },
        },
    };
    const Store = JsonStore(U, sch);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    const id = try store.insert(.{ .id = 0, .role = "" });
    const f = try store.findById(id);
    try std.testing.expectEqualStrings("user", f.?.role);
}
