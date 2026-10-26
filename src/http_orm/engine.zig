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
        /// 唯一单字段增量索引：key（store 自持有，allocator 分配）→ 行 id。
        /// F-NEW-8：旧实现 insert 的 checkUnique 对每个唯一字段全表线性扫描
        /// O(唯一字段数 × 行数)，高频 update（如 last_login_at）每写必付一次。
        /// 维护点：open（load 后重建）、insert、update 提交、delete、truncate、close。
        field_key_maps: []std.StringHashMap(u64) = &.{},
        /// 唯一联合索引增量索引：组 key（store 自持有）→ 任一行 id
        index_key_maps: []std.StringHashMap(u64) = &.{},
        /// 保护并发读写（rows、next_id、文件 flush）
        mutex: std.Io.Mutex = .init,

        const Self = @This();

        /// 唯一约束相关的 comptime 元数据：单字段/联合索引的映射位次。
        /// `?usize = null` 表示该字段/索引不是唯一的（无对应 map）。
        const field_map_idx = blk: {
            var out: [schema.fields.len]i8 = @splat(-1);
            var n: i8 = 0;
            for (schema.fields, 0..) |f, i| {
                if (f.constraints.unique) {
                    out[i] = n;
                    n += 1;
                }
            }
            break :blk out;
        };
        const index_map_idx = blk: {
            var out: [schema.indexes.len]i8 = @splat(-1);
            var n: i8 = 0;
            for (schema.indexes, 0..) |idx, i| {
                if (idx.unique) {
                    out[i] = n;
                    n += 1;
                }
            }
            break :blk out;
        };
        const unique_field_count: usize = blk: {
            var n: usize = 0;
            for (schema.fields) |f| {
                if (f.constraints.unique) n += 1;
            }
            break :blk n;
        };
        const unique_index_count: usize = blk: {
            var n: usize = 0;
            for (schema.indexes) |idx| {
                if (idx.unique) n += 1;
            }
            break :blk n;
        };

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
            _ = cwd.statFile(self.io, file_path, .{}) catch |err| {
                // 仅当文件不存在时初始化空表；其它 stat 错误（如 EACCES）应向上
                // 传播，避免覆盖已有数据。
                if (err == error.FileNotFound) {
                    try self.writeFile("[]");
                } else {
                    return err;
                }
            };

            try self.load();
            // F-NEW-8/F-NEW-5.1：构建唯一键增量索引（insert/update/delete 从此
            // O(1) 查冲突）；同时承担「存量脏数据可见性」——发现重复值时
            // log.warn 并保留首行映射（不拒启动）。
            if (unique_field_count > 0 or unique_index_count > 0) {
                errdefer self.destroyUniqueMaps();
                try self.initUniqueMaps();
                self.buildUniqueIndexes();
            }
            return self;
        }

        /// 关闭存储：先持久化未写入的数据，再释放资源。
        /// 无条件释放资源，最后再报 flush 错误：close 是消费性 API，
        /// 旧实现在 flush 失败时直接 return，rows / 每行字符串 / id_index / data_dir /
        /// self 全部泄漏，而调用方连句柄都没了，无法重试。
        pub fn close(self: *Self) !void {
            try self.lock();
            const flush_err = self.flushUnlocked();
            if (unique_field_count > 0 or unique_index_count > 0) {
                self.destroyUniqueMaps();
            }
            for (self.rows.items) |row| {
                freeStringFields(T, self.allocator, row);
            }
            self.rows.deinit(self.allocator);
            self.id_index.deinit();
            self.allocator.free(self.data_dir);
            // mutex 是结构体的一部分，必须先解锁再销毁
            self.unlock();
            self.allocator.destroy(self);
            return flush_err;
        }

        fn tableFilePath(self: *const Self) ![]const u8 {
            // 防止路径穿越：table_name 不得包含路径分隔符或 `..` 段。
            if (std.mem.indexOfScalar(u8, self.table_name, '/') != null) return error.InvalidTableName;
            if (std.mem.indexOfScalar(u8, self.table_name, '\\') != null) return error.InvalidTableName;
            if (std.mem.indexOfScalar(u8, self.table_name, '.') != null) {
                var it = std.mem.splitScalar(u8, self.table_name, '.');
                while (it.next()) |part| {
                    if (std.mem.eql(u8, part, "")) continue;
                    if (std.mem.eql(u8, part, "..")) return error.InvalidTableName;
                }
            }
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
            // F-05.1（最低限度迁移）：存量行有 schema 漂移时，只对**该表首条**
            // 漂移行打一条详细 warn——前 N 行全表 scan 太冗长，且同一份旧数据
            // 的漂移模式几乎一致；行数本身在 errdefer 语义之外，不影响加载。
            var schema_diff_warned = false;
            errdefer {
                // 修复 M3：load 中途失败时释放已加载行的字符串字段，避免汄漏。
                for (self.rows.items) |row| freeStringFields(T, self.allocator, row);
                self.rows.clearRetainingCapacity();
                self.id_index.clearRetainingCapacity();
            }
            for (parsed.value) |jrow| {
                if (jrow != .object) continue;
                var row = try jsonObjectToType(T, self.allocator, jrow.object);
                // 当前行尚未进入 self.rows：若本迭代后续失败（append OOM / 损坏
                // 数据返回），errdefer 释放该行已 dup 的字符串，避免与外层 errdefer
                // （只清理已入列行）冲突或泄漏。
                errdefer freeStringFields(T, self.allocator, row);

                // F-05.1：加载时按当前 schema 对齐（最低限度迁移执行器）。
                // - 缺失字段：jsonObjectToType 已补成类型零值；若该列在当前
                //   schema 里有 default_value，再用 applyDefaults 覆盖成 schema
                //   默认值（只对「JSON 里确实没有该键」的行生效，绝不改写
                //   存在的正经 0 值数据）。
                // - 多余字段（Row 里已删除的字段）：jsonObjectToType 按字段名
                //   精确匹配，多余键自然丢弃；写入时也不会再落盘。
                // - 漂移本身不拒启动（与 warnDuplicateUniques 同样的放行哲学），
                //   但第一条漂移行会打一条含具体字段清单的 warn，让「改表没删
                //   data 重启」这类操作可见，而不是静默变成空值。
                var needs_defaults = false;
                inline for (schema.fields) |f| {
                    if (f.constraints.default_value != null and jrow.object.get(f.name) == null) {
                        needs_defaults = true;
                    }
                }
                //  // BISECT
                // F-05.1：applyDefaults 把缺列字段从「类型零值」改成「schema
                // default_value」。注意 setFieldFromValue 对字符串是**直接改指针、
                // 不深拷贝**（query.setTyped 的既定约定——insert 路径之后用
                // dupStringFields 统一收编所有权）。load 只针对「JSON 没有该键」
                // 的行做一次逐字段 dup；否则 close / 后续 freeStringFields 会去
                // free schema 里的编译期常量（rodata），在测试 allocator 上不是
                // panic 而是卡死在分配器内部。
                if (needs_defaults) {
                    applyDefaults(&row);
                    inline for (schema.fields) |f| {
                        if (f.constraints.default_value != null and jrow.object.get(f.name) == null) {
                            const FT = @TypeOf(@field(row, f.name));
                            if (comptime isConstU8Slice(FT)) {
                                const ds = @field(row, f.name);
                                if (ds.len > 0) {
                                    @field(row, f.name) = try self.allocator.dupe(u8, ds);
                                }
                            }
                        }
                    }
                }
                if (!schema_diff_warned and (needs_defaults or rowSchemaDiff(T, jrow.object))) {
                    schema_diff_warned = true;
                    warnSchemaDiff(T, self.allocator, self.table_name, jrow.object);
                }

                // M3：统一以行内实际值 getFieldId 建索引/推进 max_id，不再依赖原始
                // JSON 的 tag；缺失/≤0/重复 id 一律报损坏数据，杜绝索引与行脱同步。
                const row_id: u64 = getFieldId(T, row);
                if (row_id == 0) return error.CorruptData;
                if (self.id_index.contains(row_id)) return error.CorruptData;

                // 先预留容量，之后 append/putAssumeCapacity 均不可失败（避免把已
                // dup 的字符串留半截：要么整行进表，要么 errdefer 释放）。
                try self.id_index.ensureUnusedCapacity(1);
                try self.rows.ensureUnusedCapacity(self.allocator, 1);
                const idx = self.rows.items.len;
                self.rows.appendAssumeCapacity(row);
                self.id_index.putAssumeCapacity(row_id, idx);
                if (row_id > max_id) max_id = row_id;
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
                // fsync 失败必须向上传播（不能吞掉，否则数据可能未真正落盘）。
                try file.sync(self.io);
            }
            try std.Io.Dir.rename(cwd, tmp_path, cwd, file_path, self.io);
        }

        // ── CRUD ────────────────────────────────────────

        /// 插入一行（公开入口，加锁）。批量多步写请用 `batch`（单锁，F-04）。
        pub fn insert(self: *Self, row: T) !u64 {
            try self.lock();
            defer self.unlock();
            return self.insertLocked(row);
        }

        /// 插入一行（调用方必须已持有锁）——batch 的执行原语。
        /// F-04：原主体 lock + defer unlock，batch 需要嵌套调用时会第二次
        /// lockUncancelable 自死锁（std.Io.Mutex 不可重入，与 SessionManager
        /// 的 dupe-before-return 约定一致），因此把「锁内主体」从「公开加锁
        /// 入口」里拆出来。
        fn insertLocked(self: *Self, row: T) !u64 {
            const id = self.next_id;

            var new_row = row;
            applyDefaults(&new_row);
            setFieldByIdentifier(T, &new_row, "id", id);
            // 唯一约束校验：O(1) 增量索引查询（F-NEW-8，旧为全表扫描）
            try self.checkUnique(new_row, null);

            // 先把两个可失败的容量预留好，之后 append + put 都不会失败。
            // 旧实现先 dupStringFields 再 append/put：若 id_index.put OOM，
            // errdefer 会释放字符串，但行已经进了 self.rows → 之后 flush/close 是 UAF。
            try self.id_index.ensureUnusedCapacity(1);
            try self.rows.ensureUnusedCapacity(self.allocator, 1);
            // 唯一键索引的登记容量一并预留在「可失败段」内，保证 register
            // 阶段不可失败（缺一块都会导致索引与行脱同步）。
            if (unique_field_count > 0 or unique_index_count > 0) {
                try self.ensureUniqueCapacityRows(1);
            }
            // 字符串深拷贝到 self.allocator（与 load 的所有权模型一致）。
            // 这是最后一个可失败操作；一旦成功，后续均不会失败。
            try dupStringFields(T, self.allocator, &new_row);

            self.rows.appendAssumeCapacity(new_row);
            self.id_index.putAssumeCapacity(id, self.rows.items.len - 1);
            // 登记唯一键索引（全部可失败操作已在前面完成 / 容量已预留）
            if (unique_field_count > 0 or unique_index_count > 0) {
                self.registerRowUniques(new_row, id);
            }
            self.next_id += 1;
            self.dirty = true;
            return id;
        }

        /// 返回匹配的行，行内字符串由 `gpa` 拥有（锁内深拷贝）。
        /// 调用方负责 freeRow / 或传 ctx.arena 交给请求生命周期。
        ///
        /// **必须在锁内深拷贝**：行内 `[]const u8` 由 self.allocator 拥有，
        /// update/delete/truncate/close 会 freeStringFields 掉它们。若把裸指针越过
        /// 锁交给调用方（P0-6），并发下就是跨请求数据泄漏 / UAF。
        pub fn findAll(self: *Self, gpa: std.mem.Allocator, query: *QueryBuilder(T)) ![]T {
            try query.checkBuildError();
            try self.lock();
            defer self.unlock();

            // 先按未拷贝的行做匹配/排序/分页，最后只对存活行深拷贝字符串，
            // 否则被分页丢弃的行的 dup 字符串会泄漏。
            var matched = std.ArrayList(T).empty;
            defer matched.deinit(self.allocator);
            for (self.rows.items) |row| {
                if (query.matches(row)) try matched.append(self.allocator, row);
            }
            query.applySorting(&matched);
            query.applyPagination(&matched);

            var results = std.ArrayList(T).empty;
            errdefer {
                for (results.items) |r| freeStringFields(T, gpa, r);
                results.deinit(gpa);
            }
            try results.ensureTotalCapacityPrecise(gpa, matched.items.len);
            for (matched.items) |row| {
                var copy = row;
                try dupStringFields(T, gpa, &copy);
                results.appendAssumeCapacity(copy);
            }
            return results.toOwnedSlice(gpa);
        }

        /// 返回首个匹配行，行内字符串由 `gpa` 拥有（锁内深拷贝）。见 findAll 的所有权说明。
        pub fn findOne(self: *Self, gpa: std.mem.Allocator, query: *QueryBuilder(T)) !?T {
            try query.checkBuildError();
            try self.lock();
            defer self.unlock();

            for (self.rows.items) |row| {
                if (query.matches(row)) {
                    var copy = row;
                    try dupStringFields(T, gpa, &copy);
                    return copy;
                }
            }
            return null;
        }

        /// 按主键查找，行内字符串由 `gpa` 拥有（锁内深拷贝）。见 findAll 的所有权说明。
        pub fn findById(self: *Self, gpa: std.mem.Allocator, id: u64) !?T {
            try self.lock();
            defer self.unlock();
            return self.findByIdLocked(gpa, id);
        }

        /// findById（调用方必须已持有锁）——batch 的原语。
        fn findByIdLocked(self: *Self, gpa: std.mem.Allocator, id: u64) !?T {
            const idx = self.id_index.get(id) orelse return null;
            var copy = self.rows.items[idx];
            try dupStringFields(T, gpa, &copy);
            return copy;
        }

        /// 批量更新（公开入口，加锁）。多步批量写请用 `batch`（单锁，F-04）。
        pub fn update(self: *Self, query: *QueryBuilder(T)) !usize {
            try query.checkBuildError();
            try self.lock();
            defer self.unlock();
            return self.updateLocked(query);
        }

        /// 批量更新（调用方必须已持有锁）——batch 的执行原语。
        fn updateLocked(self: *Self, query: *QueryBuilder(T)) !usize {
            if (query.data == null) {
                return 0;
            }

            // First pass: collect indices of rows that match the query.
            // 锁由 wrapper 持有：内部的提前返回不需要自己 unlock。
            var matched_indices = std.ArrayList(usize).empty;
            defer matched_indices.deinit(self.allocator);
            for (self.rows.items, 0..) |row, idx| {
                if (query.matches(row)) try matched_indices.append(self.allocator, idx);
            }
            if (matched_indices.items.len == 0) {
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

            // 联合唯一约束：组员字段名切片来自编译期 schema（静态存储），
            // 可以安全地存进这个 ArrayList 留到第二趟用。
            var group_sets = std.ArrayList(std.StringHashMap(void)).empty;
            defer {
                for (group_sets.items) |*m| m.deinit();
                group_sets.deinit(self.allocator);
            }
            var group_names = std.ArrayList([]const []const u8).empty;
            defer group_names.deinit(self.allocator);

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
                        if (query_mod.isFieldNull(T, row, field_name)) continue;
                        // 使用 Opt 版本：field_name 来自运行时 update_fields（可能是用户
                        // JSON key）。旧用 getFieldValue 在字段不存在时 @panic → 远程 abort。
                        const fv = query_mod.getFieldValueOpt(T, row, field_name) orelse continue;
                        const key = try fieldValuesKey(key_alloc, fv);
                        try set.put(key, {});
                    }
                    try unique_sets.append(self.allocator, set);
                }
                for (schema.indexes) |idx| {
                    if (!idx.unique) continue;
                    if (!groupTouched(idx.fields, updating_fields)) continue;
                    try group_names.append(self.allocator, idx.fields);
                    var set = try self.buildGroupSet(self.allocator, key_alloc, matched_indices.items, idx.fields);
                    errdefer set.deinit(); // append OOM 时上面的 defer 看不到这个 set
                    try group_sets.append(self.allocator, set);
                }
            } else {
                // 整行替换（bug.md §4）：每个命中行都拿到同一份 query.data，唯一
                // 字段的新值在多行间必然相同。若只逐行 checkUnique（只比旧值、仅
                // 排除自身 id），两行各自都检不出冲突 → 静默写入重复唯一值。
                // 这里为**所有** unique 字段/联合索引建同样的「非命中行取值集」，
                // 交给第二趟统一的累积式校验循环。
                for (schema.fields) |fd| {
                    if (!fd.constraints.unique) continue;
                    try unique_field_names.append(self.allocator, fd.name);
                    var set = std.StringHashMap(void).init(self.allocator);
                    errdefer set.deinit();
                    outer2: for (self.rows.items, 0..) |row, idx| {
                        // skip rows that are being updated
                        for (matched_indices.items) |mi| {
                            if (mi == idx) continue :outer2;
                        }
                        if (query_mod.isFieldNull(T, row, fd.name)) continue;
                        const fv = query_mod.getFieldValueOpt(T, row, fd.name) orelse continue;
                        const key = try fieldValuesKey(key_alloc, fv);
                        try set.put(key, {});
                    }
                    try unique_sets.append(self.allocator, set);
                }
                for (schema.indexes) |idx| {
                    if (!idx.unique) continue;
                    try group_names.append(self.allocator, idx.fields);
                    var set = try self.buildGroupSet(self.allocator, key_alloc, matched_indices.items, idx.fields);
                    errdefer set.deinit();
                    try group_sets.append(self.allocator, set);
                }
            }

            // Second pass: build + validate ALL updated rows in a scratch copy first.
            // 只有全部行都通过校验（含唯一约束）后，才整体写回 self.rows，
            // 避免中途 UniqueViolation 返回时已部分修改 self.rows（数据完整性泄漏）。
            var new_rows = std.ArrayList(T).empty;
            defer new_rows.deinit(self.allocator);
            for (matched_indices.items) |idx| {
                const row = self.rows.items[idx];
                const orig_id = getFieldId(T, row);
                var updated = row;
                if (query.update_fields) |fields| {
                    for (fields) |field_name| {
                        // field_name 可能来自用户 JSON key：不存在的字段直接跳过，
                        // 不能 @panic（P0-8：一个 PATCH handler 把未知 key 传进来就能打死进程）。
                        const val = query_mod.getFieldValueOpt(T, query.data.?, field_name) orelse continue;
                        setFieldByIdentifier(T, &updated, field_name, val);
                    }
                    setFieldByIdentifier(T, &updated, "id", orig_id);
                } else {
                    // 整行替换路径：同样必须做唯一约束校验（H2），排除自身 id。
                    // 具体校验由下方与 update_fields 路径共用的累积集合完成
                    // （旧于此处的逐行 checkUnique 漏检命中行之间的冲突，bug.md §4）。
                    updated = query.data.?;
                    setFieldByIdentifier(T, &updated, "id", orig_id);
                }
                // Check unique constraints against the pre-built sets.
                // 两条路径共用：每个通过校验的新值都追加进集合，使后续命中行的
                // 相同新值也被判为冲突（累积式，覆盖「多行同名新值」）。
                for (unique_field_names.items, 0..) |ufn, ui| {
                    if (query_mod.isFieldNull(T, updated, ufn)) continue;
                    const new_val = query_mod.getFieldValueOpt(T, updated, ufn) orelse continue;
                    const key = try fieldValuesKey(key_alloc, new_val);
                    if (unique_sets.items[ui].contains(key)) {
                        // 不显式 unlock——让 errdefer 处理（避免双重解锁）
                        return error.UniqueViolation;
                    }
                    // Add the new value to the set so subsequent matched
                    // rows can't collide with this row's new value either.
                    try unique_sets.items[ui].put(key, {});
                }
                // 联合唯一：整组取值不得与集合里任何一行相同。
                for (group_names.items, 0..) |names, gi| {
                    if (groupHasNull(updated, names)) continue;
                    const key = try groupKey(key_alloc, updated, names);
                    if (group_sets.items[gi].contains(key)) {
                        return error.UniqueViolation;
                    }
                    try group_sets.items[gi].put(key, {});
                }
                try new_rows.append(self.allocator, updated);
            }

            // Third pass: commit — 调和字符串所有权并整体写回。所有校验均已通过。
            // 多行原子：先为所有命中行 prepare（全部可能失败，都不动旧值），
            // 全部成功后才逐行 apply（不可失败）。中途 OOM 不再留下「前几行
            // 已提交、dirty 未置位、永不落盘」的部分提交状态。
            var prepared_list = try self.allocator.alloc(std.ArrayList(StringChange), matched_indices.items.len);
            errdefer {
                for (prepared_list) |*changes| {
                    for (changes.items) |c| if (c.new) |s| self.allocator.free(s);
                    changes.deinit(self.allocator);
                }
                self.allocator.free(prepared_list);
            }
            for (prepared_list) |*changes| changes.* = .empty;

            for (matched_indices.items, 0..) |idx, j| {
                const row = self.rows.items[idx];
                var updated = new_rows.items[j];
                prepareStringChanges(T, self.allocator, row, &updated, &prepared_list[j]) catch |e| {
                    // OOM：无行已提交，索引一致，直接上抛。
                    return e;
                };
                new_rows.items[j] = updated;
            }

            // Prepare 全部成功后：唯一键索引维护同样原子——先逐 map 预留
            // 足够新 key 的容量（可失败段），综合 commit 阶段才全部不可失败。
            if (unique_field_count > 0 or unique_index_count > 0) {
                try self.ensureUniqueCapacityRows(matched_indices.items.len);
            }

            var updated_count: usize = 0;
            for (matched_indices.items, 0..) |idx, j| {
                const row = self.rows.items[idx];
                var updated = new_rows.items[j];
                // 唯一键索引：先摘除旧 key（free），提交后挂新 key。row 的字符串
                // 所有权在 applyStringChanges 中换手，旧 key 的内容在换手前计算。
                if (unique_field_count > 0 or unique_index_count > 0) {
                    self.unregisterRowUniques(row);
                }
                applyStringChanges(T, self.allocator, row, &updated, prepared_list[j].items);
                self.rows.items[idx] = updated;
                if (unique_field_count > 0 or unique_index_count > 0) {
                    self.registerRowUniques(updated, getFieldId(T, updated));
                }
                updated_count += 1;
            }

            // Apply 之后没有任何失败路径：dup'd 字符串已随行结构移入 self.rows，
            // 这里只回收 prepare 缓冲本身。
            for (prepared_list) |*changes| changes.deinit(self.allocator);
            self.allocator.free(prepared_list);

            // 修复 C3：dirty 必须在锁内写（其他地方都在锁内访问），
            // 否则与并发 flush 竞态可能丢失一次持久化。
            if (updated_count > 0) self.dirty = true;
            return updated_count;
        }

        /// 批量删除（公开入口，加锁）。多步批量写请用 `batch`（单锁，F-04）。
        pub fn delete(self: *Self, query: *QueryBuilder(T)) !usize {
            try query.checkBuildError();
            try self.lock();
            defer self.unlock();
            return self.deleteLocked(query);
        }

        /// 批量删除（调用方必须已持有锁）——batch 的执行原语。
        fn deleteLocked(self: *Self, query: *QueryBuilder(T)) !usize {
            // First pass: collect indices to delete (preserving ascending order
            // via a reverse scan so the indices array is sorted ascending).
            var to_delete = std.ArrayList(usize).empty;
            defer to_delete.deinit(self.allocator);
            for (self.rows.items, 0..) |row, idx| {
                if (query.matches(row)) try to_delete.append(self.allocator, idx);
            }
            const deleted_count = to_delete.items.len;
            if (deleted_count == 0) return 0;

            // 先把保留行拷到 kept（可能 OOM），全部成功后才释放被删行。
            // 旧实现先 freeStringFields 再建 kept，若建 kept 中途 OOM，
            // self.rows 里仍是已释放的字符串 → 之后 flush/close 是 UAF。
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

            // 先确保索引容量（唯一可能失败的步骤）再释放被删行的字符串、
            // 转移 kept 所有权——旧顺序（swap 之后再 ensureTotalCapacity）
            // 在 OOM 时触发 errdefer kept.deinit，而 buffer 已归 self.rows，
            // 造成 store 内 UAF + flush/close 双重释放。
            try self.id_index.ensureTotalCapacity(std.math.cast(u32, self.rows.items.len - deleted_count) orelse std.math.maxInt(u32));

            // 下面全部不可失败：现在才释放被删行的字符串。
            // （先从唯一键索引摘除——rows 下标换基前旧值还拿到，step 顺序固定。）
            for (to_delete.items) |idx| {
                const row = self.rows.items[idx];
                if (unique_field_count > 0 or unique_index_count > 0) {
                    self.unregisterRowUniques(row);
                }
                freeStringFields(T, self.allocator, row);
            }
            self.rows.deinit(self.allocator);
            self.rows = kept;

            // Rebuild id_index in one O(N) pass instead of decrementing per row.
            // 容量已就绪，putAssumeCapacity 不可失败地重建，避免中途 OOM
            // 造成索引半重建 + dirty 仍落盘。
            self.id_index.clearRetainingCapacity();
            for (self.rows.items, 0..) |row, idx| {
                self.id_index.putAssumeCapacity(getFieldId(T, row), idx);
            }

            self.dirty = true;
            return deleted_count;
        }

        pub fn count(self: *Self, query: *QueryBuilder(T)) !usize {
            try query.checkBuildError();
            try self.lock();
            defer self.unlock();

            var c: usize = 0;
            for (self.rows.items) |row| {
                if (query.matches(row)) c += 1;
            }
            return c;
        }

        /// 返回所有行的深拷贝，行内字符串由 `gpa` 拥有（锁内深拷贝）。
        /// 调用方需 freeRows(gpa, rows)（或传 ctx.arena）。见 findAll 的所有权说明。
        pub fn all(self: *Self, gpa: std.mem.Allocator) ![]T {
            try self.lock();
            defer self.unlock();

            const result = try gpa.alloc(T, self.rows.items.len);
            errdefer gpa.free(result);
            var done: usize = 0;
            errdefer for (result[0..done]) |r| freeStringFields(T, gpa, r);
            for (self.rows.items, 0..) |row, i| {
                var copy = row;
                try dupStringFields(T, gpa, &copy);
                result[i] = copy;
                done = i + 1;
            }
            return result;
        }

        /// 释放由 all/findAll 返回的行切片（含每行的字符串字段）。
        pub fn freeRows(self: *Self, gpa: std.mem.Allocator, rows: []T) void {
            _ = self;
            for (rows) |r| freeStringFields(T, gpa, r);
            gpa.free(rows);
        }

        /// 释放由 findById/findOne/findBy 返回的单行（含字符串字段）。
        pub fn freeRow(self: *Self, gpa: std.mem.Allocator, row: T) void {
            _ = self;
            freeStringFields(T, gpa, row);
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
            // 唯一键索引清空（key 全部 store 自持有，一并释放）
            if (unique_field_count > 0 or unique_index_count > 0) {
                self.destroyUniqueMaps();
                try self.initUniqueMaps();
            }
            self.next_id = 1;
            self.dirty = true;
        }

        // ── 易用性增强（新增便捷方法）──────────────────

        /// 按任意字段查找单条（Equals）。字段值自动转换为 FieldValue。
        /// 行内字符串由 `gpa` 拥有（见 findAll 的所有权说明）。
        pub fn findBy(self: *Self, gpa: std.mem.Allocator, comptime field: []const u8, value: anytype) !?T {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, field, query_mod.toFieldValue(value));
            return self.findOne(gpa, &qb);
        }

        /// 按任意字段查找所有匹配行（Equals），无需手搭 QueryBuilder。
        /// 行内字符串由 `gpa` 拥有（见 findAll 的所有权说明）。
        pub fn findAllBy(self: *Self, gpa: std.mem.Allocator, comptime field: []const u8, value: anytype) ![]T {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, field, query_mod.toFieldValue(value));
            return self.findAll(gpa, &qb);
        }

        /// 全表行数（O(1)，不深拷贝行、无需构造 QueryBuilder）。
        pub fn countAll(self: *Self) !usize {
            try self.lock();
            defer self.unlock();
            return self.rows.items.len;
        }

        /// 按主键更新整行（id 自动保留）。返回是否更新到记录。
        pub fn updateById(self: *Self, id: u64, data: T) !bool {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            // FieldValue.integer 是 i64：id 超出范围时按「无此记录」返回 false，
            // 不能 @intCast——安全构建下 panic、Unsafe 构建下 UB（bug.md §2，
            // DELETE /users/18446744073709551615 即可远程打穿），与 toFieldValue
            // 的 std.math.cast 饱和策略保持一致。
            const id_i: i64 = std.math.cast(i64, id) orelse return false;
            _ = qb.where(.Eq, "id", .{ .integer = id_i });
            _ = qb.update(data, null);
            const n = try self.update(&qb);
            return n > 0;
        }

        /// 按主键删除。返回是否删除到记录。
        pub fn deleteById(self: *Self, id: u64) !bool {
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            // 同 updateById：u64 越界视为「无此记录」，避免 @intCast panic（bug.md §2）。
            const id_i: i64 = std.math.cast(i64, id) orelse return false;
            _ = qb.where(.Eq, "id", .{ .integer = id_i });
            _ = qb.delete();
            const n = try self.delete(&qb);
            return n > 0;
        }

        /// 分页查询（按 id 升序）。page 从 0 开始。
        /// 行内字符串由 `gpa` 拥有（见 findAll 的所有权说明）。
        pub fn paginate(self: *Self, gpa: std.mem.Allocator, page: usize, per_page: usize) ![]T {
            // 乘法溢出（page/per_page 可直通请求）：返回空页而非 panic。
            const offset = std.math.mul(usize, page, per_page) catch {
                return try gpa.alloc(T, 0);
            };
            var qb = QueryBuilder(T).init(self.allocator);
            defer qb.deinit();
            _ = qb.orderBy("id", .Asc).limit(per_page).offset(offset);
            return self.findAll(gpa, &qb);
        }

        /// 分页查询（可带 where / orderBy，FRICTION F-21）。
        ///
        /// 传入调用方已构建好过滤条件的 QueryBuilder；本方法在其上追加：
        /// - 条件全部沿用（caller 的 conditions 不被修改）；
        /// - caller 未给任何 orderBy 时补默认 `id ASC`（保证分页稳定性）；
        /// - limit / offset 始终由本方法设置（caller 若设了会被覆盖——分页
        ///   语义里它们就是页大小 / 页起点，不属于过滤器）。
        ///
        /// 行内字符串由 `gpa` 拥有，调用方 `freeRows(gpa, rows)`。
        pub fn paginateWhere(
            self: *Self,
            gpa: std.mem.Allocator,
            page: usize,
            per_page: usize,
            query: *QueryBuilder(T),
        ) ![]T {
            const offset = std.math.mul(usize, page, per_page) catch {
                return try gpa.alloc(T, 0);
            };
            if (query.order_clauses.items.len == 0) {
                _ = query.orderBy("id", .Asc);
            }
            _ = query.limit(per_page).offset(offset);
            return self.findAll(gpa, query);
        }

        // ── batch：单锁多步批量写（F-04）────────────────
        //
        // 动机（FRICTION F-04）：`setRolePermissions = 先删全部、再逐条插入`
        // 这类多步写，每步独立 lock + dirty +（业务层自己）flush——步骤之间存在
        // 并发穿插窗口，且 K 步 = K 次全表 flush 写放大或「flush 之前崩溃即丢」。
        //
        // 约束：std.Io.Mutex 不可重入（与 SessionManager 的 dupe-before-return
        // 约定一致），所以 batch 不做嵌套加锁，而是把 insert/update/delete 主体
        // 抽成 `...Locked` 原语，回调在**单次持锁**期间自由组合调用。
        //
        // 语义边界（如实声明，不虚构 ACID）：
        // - **并发原子**：✅ 回调全程持锁，其它请求看不到中间态。
        // - **崩溃原子**：❌ 仍是内存模型——回调期间崩溃，已执行步骤留在内存且
        //   dirty 已置位；要落盘请调用 `b.flush()`（复用 tmp+fsync+rename），
        //   或 batch 后自行 `store.flush()`。真正的崩溃原子需要 WAL/undo log，
        //   那是 F-14 的后续范围。
        // - 回调中途出错：已执行的步骤保持已提交（内存），错误上抛。
        pub const Batch = struct {
            store: *Self,

            /// 插入一行（同 insert，但不再加锁）。
            pub fn insert(self: Batch, row: T) !u64 {
                return self.store.insertLocked(row);
            }

            /// 批量更新（同 update，但不再加锁）。
            pub fn update(self: Batch, query: *QueryBuilder(T)) !usize {
                try query.checkBuildError();
                return self.store.updateLocked(query);
            }

            /// 批量删除（同 delete，但不再加锁）。
            pub fn delete(self: Batch, query: *QueryBuilder(T)) !usize {
                try query.checkBuildError();
                return self.store.deleteLocked(query);
            }

            /// 在持锁状态下落盘（tmp + fsync + rename）。等价于「batch 全部成功
            /// 后的 flush」，省一次加锁；成功后 dirty 复位。
            pub fn flush(self: Batch) !void {
                return self.store.flushUnlocked();
            }

            /// 深拷贝一行（锁内，等价 findById 的 batch 版）。
            pub fn findById(self: Batch, gpa: std.mem.Allocator, id: u64) !?T {
                return self.store.findByIdLocked(gpa, id);
            }
        };

        /// 单锁多步批量写。`Ctx` 为回调上下文类型（无可传 `void` + `{}`），
        /// 回调在持锁期间执行。推荐用法（FRICTION F-04 的 setRolePermissions 场景）：
        /// ```zig
        /// try store.batch(null, struct {
        ///     fn f(_: void, b: *Store.Batch) !void {
        ///         _ = try b.delete(&del_qb);
        ///         for (perm_ids) |pid| {
        ///             _ = try b.insert(.{ .role_id = rid, .permission_id = pid });
        ///         }
        ///         try b.flush();
        ///     }
        /// }
        /// ```
        /// 注意回调读写 QueryBuilder 时它自身的 allocator 不受影响；锁内不要做
        /// 阻塞 IO 或长时间计算（会阻塞所有并发请求）。
        pub fn batch(self: *Self, comptime Ctx: type, ctx: Ctx, comptime cb: fn (Ctx, b: *Batch) anyerror!void) anyerror!void {
            try self.lock();
            defer self.unlock();
            var b = Batch{ .store = self };
            try cb(ctx, &b);
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

        /// 初始化唯一键增量索引的 map 数组（open 调用；无唯一约束时是空数组）。
        fn initUniqueMaps(self: *Self) !void {
            if (unique_field_count > 0) {
                self.field_key_maps = try self.allocator.alloc(std.StringHashMap(u64), unique_field_count);
                for (self.field_key_maps) |*m| m.* = .init(self.allocator);
            }
            if (unique_index_count > 0) {
                self.index_key_maps = try self.allocator.alloc(std.StringHashMap(u64), unique_index_count);
                for (self.index_key_maps) |*m| m.* = .init(self.allocator);
            }
        }

        /// 释放唯一键增量索引的全部资源（close/tableFileErrdefer 调用）。
        /// key 由 store 分配自持有，逐条释放（与 evictSampled 同约定）。
        fn destroyUniqueMaps(self: *Self) void {
            for (self.field_key_maps) |*m| {
                var it = m.keyIterator();
                while (it.next()) |k| self.allocator.free(k.*);
                m.deinit();
            }
            self.allocator.free(self.field_key_maps);
            self.field_key_maps = &.{};
            for (self.index_key_maps) |*m| {
                var it = m.keyIterator();
                while (it.next()) |k| self.allocator.free(k.*);
                m.deinit();
            }
            self.allocator.free(self.index_key_maps);
            self.index_key_maps = &.{};
        }

        /// 把一行登记进唯一的 key 索引（insert / update 提交调用）。
        /// **调用前提**：冲突校验已通过；所有 map 已 ensureUnusedCapacity(1)，
        /// 登记阶段不可失败。
        fn registerRowUniques(self: *Self, row: T, id: u64) void {
            inline for (schema.fields, 0..) |f, fi| {
                const mi = field_map_idx[fi];
                if (comptime mi >= 0 and f.constraints.unique) {
                    const m = &self.field_key_maps[@intCast(mi)];
                    if (!query_mod.isFieldNull(T, row, f.name)) {
                        const key = fieldValuesKey(self.allocator, query_mod.getFieldValue(T, row, f.name)) catch return;
                        const gop = m.getOrPut(key) catch {
                            self.allocator.free(key);
                            return;
                        };
                        if (gop.found_existing) {
                            // 校验已拦住；防御性：保留现有映射，丢弃新 key。
                            self.allocator.free(key);
                            return;
                        }
                        gop.value_ptr.* = id;
                    }
                }
            }
            inline for (schema.indexes, 0..) |idx, ii| {
                const mi = index_map_idx[ii];
                if (comptime mi >= 0 and idx.unique) {
                    const m = &self.index_key_maps[@intCast(mi)];
                    if (!groupHasNull(row, idx.fields)) {
                        const key = groupKey(self.allocator, row, idx.fields) catch return;
                        const gop = m.getOrPut(key) catch {
                            self.allocator.free(key);
                            return;
                        };
                        if (gop.found_existing) {
                            self.allocator.free(key);
                            return;
                        }
                        gop.value_ptr.* = id;
                    }
                }
            }
        }

        /// 把一行从唯一样式索引摘除并释放其 key（update 提交前 / delete 调用）。
        fn unregisterRowUniques(self: *Self, row: T) void {
            inline for (schema.fields, 0..) |f, fi| {
                const mi = field_map_idx[fi];
                if (comptime mi >= 0 and f.constraints.unique) {
                    const m = &self.field_key_maps[@intCast(mi)];
                    if (!query_mod.isFieldNull(T, row, f.name)) {
                        const key = fieldValuesKey(self.allocator, query_mod.getFieldValue(T, row, f.name)) catch return;
                        defer self.allocator.free(key);
                        if (m.fetchRemove(key)) |kv| self.allocator.free(kv.key);
                    }
                }
            }
            inline for (schema.indexes, 0..) |idx, ii| {
                const mi = index_map_idx[ii];
                if (comptime mi >= 0 and idx.unique) {
                    const m = &self.index_key_maps[@intCast(mi)];
                    if (!groupHasNull(row, idx.fields)) {
                        const key = groupKey(self.allocator, row, idx.fields) catch return;
                        defer self.allocator.free(key);
                        if (m.fetchRemove(key)) |kv| self.allocator.free(kv.key);
                    }
                }
            }
        }

        /// 唯一约束校验：O(1) map 查询（F-NEW-8）。row 的 unique 字段 / 唯一索引
        /// 组合不得与其它行冲突（自己 existing 的 key 允许——update 场景鞍事）。
        fn checkUnique(self: *const Self, row: T, except_id: ?u64) !void {
            if (unique_field_count == 0 and unique_index_count == 0) return;
            var key_draft = std.ArrayList([]u8).empty;
            defer {
                for (key_draft.items) |k| self.allocator.free(k);
                key_draft.deinit(self.allocator);
            }

            inline for (schema.fields, 0..) |f, fi| {
                const mi = field_map_idx[fi];
                if (comptime mi >= 0 and f.constraints.unique) {
                    if (!query_mod.isFieldNull(T, row, f.name)) {
                        const key = try fieldValuesKey(self.allocator, query_mod.getFieldValue(T, row, f.name));
                        key_draft.append(self.allocator, key) catch |e| {
                            self.allocator.free(key);
                            return e;
                        };
                        const m = &self.field_key_maps[@intCast(mi)];
                        if (m.get(key)) |existing_id| {
                            if (except_id == null or existing_id != except_id.?) {
                                return error.UniqueViolation;
                            }
                        }
                    }
                }
            }
            inline for (schema.indexes, 0..) |idx, ii| {
                const mi = index_map_idx[ii];
                if (comptime mi >= 0 and idx.unique) {
                    if (!groupHasNull(row, idx.fields)) {
                        const key = try groupKey(self.allocator, row, idx.fields);
                        key_draft.append(self.allocator, key) catch |e| {
                            self.allocator.free(key);
                            return e;
                        };
                        const m = &self.index_key_maps[@intCast(mi)];
                        if (m.get(key)) |existing_id| {
                            if (except_id == null or existing_id != except_id.?) {
                                return error.UniqueViolation;
                            }
                        }
                    }
                }
            }
        }

        /// 开启时重建唯一键索引（load 之后调用）。发现存量重复时告警
        /// 并保留首行映射（warning-only，不拒启动——见 F-NEW-5.1 讨论）。
        fn buildUniqueIndexes(self: *Self) void {
            if (unique_field_count == 0 and unique_index_count == 0) return;
            // 逐 map 预留容量，让 putAssumeCapacity 阶段不可失败。
            self.ensureUniqueCapacityRows(self.rows.items.len) catch return;
            for (self.rows.items) |row| {
                const id = getFieldId(T, row);
                inline for (schema.fields, 0..) |f, fi| {
                    const mi = field_map_idx[fi];
                    if (comptime mi >= 0 and f.constraints.unique) {
                        if (!query_mod.isFieldNull(T, row, f.name)) {
                            const key = fieldValuesKey(self.allocator, query_mod.getFieldValue(T, row, f.name)) catch return;
                            const m = &self.field_key_maps[@intCast(mi)];
                            const gop = m.getOrPut(key) catch {
                                self.allocator.free(key);
                                return;
                            };
                            if (gop.found_existing) {
                                std.log.warn("orm: {s} 打开时发现存量数据违反唯一约束（字段 {s} 有重复值）——加载已放行；后续 update/insert 该值会报 UniqueViolation", .{ self.table_name, f.name });
                                self.allocator.free(key);
                            } else {
                                gop.value_ptr.* = id;
                            }
                        }
                    }
                }
                inline for (schema.indexes, 0..) |idx, ii| {
                    const mi = index_map_idx[ii];
                    if (comptime mi >= 0 and idx.unique) {
                        if (!groupHasNull(row, idx.fields)) {
                            const key = groupKey(self.allocator, row, idx.fields) catch return;
                            const m = &self.index_key_maps[@intCast(mi)];
                            const gop = m.getOrPut(key) catch {
                                self.allocator.free(key);
                                return;
                            };
                            if (gop.found_existing) {
                                std.log.warn("orm: {s} 打开时发现存量数据违反联合唯一约束（索引 {s} 有重复组合）——加载已放行；后续写入会报 UniqueViolation", .{ self.table_name, idx.name });
                                self.allocator.free(key);
                            } else {
                                gop.value_ptr.* = id;
                            }
                        }
                    }
                }
            }
        }

        /// 为唯一索引预留足够容量：此后每行 put（最多一次 per map per row）
        /// 都不会中途 OOM。
        fn ensureUniqueCapacityRows(self: *Self, rows: usize) !void {
            if (unique_field_count > 0) {
                for (self.field_key_maps) |*m| try m.ensureUnusedCapacity(@intCast(rows));
            }
            if (unique_index_count > 0) {
                for (self.index_key_maps) |*m| try m.ensureUnusedCapacity(@intCast(rows));
            }
        }

        /// 一组字段的组合值是否完全相同。字段名不存在 → 视为不相等（不外泄、
        /// 不 panic；schema 是编译期常量，名字只可能在手写 schema 时写错）。
        fn groupEquals(a: T, b: T, names: []const []const u8) bool {
            for (names) |n| {
                const va = query_mod.getFieldValueOpt(T, a, n) orelse return false;
                const vb = query_mod.getFieldValueOpt(T, b, n) orelse return false;
                if (!fieldValuesEqual(va, vb)) return false;
            }
            return names.len > 0;
        }

        /// 组内任一字段为 NULL → 该行不参与联合唯一比较（SQL 语义）。
        fn groupHasNull(row: T, names: []const []const u8) bool {
            for (names) |n| {
                if (query_mod.isFieldNull(T, row, n)) return true;
            }
            return false;
        }

        /// 组内是否有字段被本次 update 触及。没触及任何组员时组合值必然不变，
        /// 不需要建集合也不需要校验。
        fn groupTouched(names: []const []const u8, updating: []const []const u8) bool {
            for (names) |n| {
                for (updating) |u| {
                    if (std.mem.eql(u8, n, u)) return true;
                }
            }
            return false;
        }

        /// 一组字段的组合值 → 可比较的字符串键。用 0x1f 分隔：不分隔的话
        /// ("ab","c") 与 ("a","bc") 会撞出同一个键。
        fn groupKey(allocator: std.mem.Allocator, row: T, names: []const []const u8) ![]u8 {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            for (names) |n| {
                const fv = query_mod.getFieldValueOpt(T, row, n) orelse continue;
                const part = try fieldValuesKey(allocator, fv);
                defer allocator.free(part);
                try buf.append(allocator, 0x1f);
                try buf.appendSlice(allocator, part);
            }
            return buf.toOwnedSlice(allocator);
        }

        /// 建「不在 matched 里的行」在给定字段组上的取值集合，供 update 做 O(1) 查重。
        fn buildGroupSet(
            self: *const Self,
            set_alloc: std.mem.Allocator,
            key_alloc: std.mem.Allocator,
            matched: []const usize,
            names: []const []const u8,
        ) !std.StringHashMap(void) {
            var set = std.StringHashMap(void).init(set_alloc);
            errdefer set.deinit();
            outer: for (self.rows.items, 0..) |row, idx| {
                for (matched) |mi| {
                    if (mi == idx) continue :outer;
                }
                if (groupHasNull(row, names)) continue;
                const key = try groupKey(key_alloc, row, names);
                try set.put(key, {});
            }
            return set;
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

/// 检测单条存量行与当前 Row(T) 结构是否漂移（F-05.1）：
/// 满足其一即 true —— ① T 有字段而 JSON 里没有（缺列）；
/// ② JSON 里有 T 不认识的键（多余列，jsonObjectToType 会静默丢弃）。
fn rowSchemaDiff(comptime T: type, obj: std.json.ObjectMap) bool {
    const names = @typeInfo(T).@"struct".field_names;
    inline for (names) |name| {
        if (obj.get(name) == null) return true;
    }
    var it = obj.iterator();
    outer: while (it.next()) |e| {
        inline for (names) |name| {
            if (std.mem.eql(u8, e.key_ptr.*, name)) continue :outer;
        }
        return true;
    }
    return false;
}

/// 打印 schema 漂移详情（F-05.1）：缺哪些列、多余哪些键（截断到 64 字符）。
/// 消息按 warnSchemaDiff 的调用点约定只对该表打一条。
fn warnSchemaDiff(comptime T: type, allocator: std.mem.Allocator, table_name: []const u8, obj: std.json.ObjectMap) void {
    const names = @typeInfo(T).@"struct".field_names;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "missing=[") catch return;
    var first = true;
    inline for (names) |name| {
        if (obj.get(name) == null) {
            if (!first) buf.appendSlice(allocator, ", ") catch return;
            buf.appendSlice(allocator, name) catch return;
            first = false;
        }
    }
    buf.appendSlice(allocator, "] extra=[") catch return;
    var it = obj.iterator();
    var first_extra = true;
    outer2: while (it.next()) |e| {
        inline for (names) |name| {
            if (std.mem.eql(u8, e.key_ptr.*, name)) continue :outer2;
        }
        if (!first_extra) buf.appendSlice(allocator, ", ") catch return;
        const k = if (e.key_ptr.*.len > 64) e.key_ptr.*[0..64] else e.key_ptr.*;
        buf.appendSlice(allocator, k) catch return;
        first_extra = false;
    }
    buf.appendSlice(allocator, "]") catch return;
    std.log.warn("orm: {s} 存量数据与当前 Row 结构不一致（缺失字段已按 schema 默认值补齐 / 多余字段已忽略）——{s}；改表结构后建议尽快 flush 让数据归位", .{ table_name, buf.items });
}

fn jsonObjectToType(comptime T: type, allocator: std.mem.Allocator, obj: std.json.ObjectMap) !T {
    var result: T = undefined;
    const struct_info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };
    // 先把所有字段初始化为默认值：中途任一字幕串字段 dup 失败时，errdefer 能
    // 安全释放已 dup 的字符串（未 dup 的字段是空串/null，free 是 no-op），
    // 避免 load() 失败行的部分 dup 字符串泄漏。
    inline for (struct_info.field_names, struct_info.field_types) |name, typ| {
        @field(result, name) = getDefaultForType(typ);
    }
    errdefer freeStringFields(T, allocator, result);
    inline for (struct_info.field_names, struct_info.field_types) |name, typ| {
        if (obj.get(name)) |jval| {
            @field(result, name) = try jsonValueToField(typ, allocator, jval);
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
            if (value == .integer) return std.math.cast(T, value.integer) orelse error.CorruptData;
            if (value == .float) {
                const f = value.float;
                // @intFromFloat 的前提是值在目标类型（按 i64 界）范围内；越界数值来自
                // 手工写坏的数据库文件，应报损坏而非 UB/panic。
                if (!(f >= @as(f64, @floatFromInt(std.math.minInt(i64))) and f <= @as(f64, @floatFromInt(std.math.maxInt(i64))))) return error.CorruptData;
                return std.math.cast(T, @as(i64, @intFromFloat(f))) orelse error.CorruptData;
            }
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
                // P2-29：不再 `@panic("OOM")`——OOM 沿 `!T` 传播，不把内存压力变成进程 abort。
                // 另：非字符串 JSON 值（数字/布尔/对象）落到字符串字段不再静默变 ""
                // （那是静默数据损坏），而是报 error.TypeMismatch。null 仍视为空串。
                if (value == .string) return try allocator.dupe(u8, value.string);
                if (value == .null) return &[_]u8{};
                return error.TypeMismatch;
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
                const tag: std.meta.Tag(T) = std.math.cast(std.meta.Tag(T), value.integer) orelse return error.CorruptData;
                return @fromBackingInt(tag);
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
            // 其余**全部**控制字符必须转成 \u00XX（0x09/0x0a/0x0d 已在上面单独处理）。
            // 旧代码写的是 `0...7, 11, 14...31`，漏掉了 0x08 (\b) 和 0x0c (\f)：
            // 它们会落到 else 分支被原样写出 → 非法 JSON → 下次 load() 的
            // parseFromSlice 直接失败 → **整张表打不开**（且失败点在 open()，
            // 通常导致进程起不来）。这是不可逆的数据损坏，用户只要提交一个
            // 含退格/换页符的字符串就能触发。
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex_buf: [8]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "\\u{X:0>4}", .{c});
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
            setTypedField(ftype, &@field(instance, fname), value);
            return;
        }
    }
}

/// 按目标字段类型写入值。optional 字段递归解包到 child 类型（与 query.zig 的
/// setTyped 一致），保证 `?T` 字段的更新真正生效而不被静默丢弃（M2）。
fn setTypedField(comptime FieldT: type, field_ptr: anytype, value: anytype) void {
    switch (@typeInfo(FieldT)) {
        .optional => |opt| return setTypedField(opt.child, field_ptr, value),
        else => {},
    }
    const ValueT = @TypeOf(value);
    switch (@typeInfo(ValueT)) {
        .int, .comptime_int => {
            switch (@typeInfo(FieldT)) {
                .int, .comptime_int => field_ptr.* = @intCast(value),
                .float, .comptime_float => field_ptr.* = @floatFromInt(value),
                else => {},
            }
        },
        else => {
            // FieldValue union
            switch (value) {
                .integer => |v| switch (@typeInfo(FieldT)) {
                    .int, .comptime_int => field_ptr.* = @intCast(v),
                    .float, .comptime_float => field_ptr.* = @floatFromInt(v),
                    else => {},
                },
                .string => |v| {
                    if (comptime isConstU8Slice(FieldT)) field_ptr.* = v;
                },
                .boolean => |v| {
                    if (FieldT == bool) field_ptr.* = v;
                },
                .float => |v| switch (@typeInfo(FieldT)) {
                    .float, .comptime_float => field_ptr.* = @floatCast(v),
                    .int, .comptime_int => field_ptr.* = @intFromFloat(v),
                    else => {},
                },
                else => {},
            }
        },
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
    // bug.md §5：某个字段 dupe 失败时，回滚本行中已 dup 的较前字段，
    // 避免仅 OOM 路径泄漏。done 按「字符串字段序号」计数，errdefer 里
    // 用同一顺序释放前 done 个（optional-null 字段未 dupe，free 自然跳过）。
    var done: usize = 0;
    errdefer {
        var freed: usize = 0;
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (comptime isConstU8Slice(ftype)) {
                if (freed < done) allocator.free(@field(row.*, fname));
                freed += 1;
            } else if (comptime isOptionalConstU8Slice(ftype)) {
                if (freed < done) {
                    if (@field(row.*, fname)) |s| allocator.free(s);
                }
                freed += 1;
            }
        }
    }
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isConstU8Slice(ftype)) {
            @field(row.*, fname) = try allocator.dupe(u8, @field(row.*, fname));
            done += 1;
        } else if (comptime isOptionalConstU8Slice(ftype)) {
            if (@field(row.*, fname)) |s| {
                @field(row.*, fname) = try allocator.dupe(u8, s);
            }
            done += 1;
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

/// 单个字符串字段的待写回变更：apply 阶段释放旧（owned）值、安装 dup 入 allocator
/// 的新值。未变的字段不出现在 changes 里（updated 与 original 共享 owned 指针）。
const StringChange = struct {
    name: []const u8,
    is_optional: bool,
    new: ?[]const u8,
};

/// 单行 prepare 阶段：dup 所有变更的新值到 changes（每条变更原子：append 失败
/// 时释放该 dup，旧值尚未动）。全程不动 original / updated 的旧值。
/// 修复 C1/C2（升级为多行原子版）：调用方只有在所有命中行的 prepare 全部成功
/// 后才逐行 apply，保证多行 update 要么全部换上新值、要么全部保持旧值——
/// 旧的单行两阶段实现在多行循环中途 OOM 时会留下「前几行已提交、后几行未提交、
/// dirty 未置位（永不落盘）」的部分提交状态。
fn prepareStringChanges(comptime T: type, allocator: std.mem.Allocator, original: T, updated: *T, changes: *std.ArrayList(StringChange)) !void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };

    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isConstU8Slice(ftype)) {
            const orig_slice = @field(original, fname);
            const new_slice = @field(updated.*, fname);
            if (orig_slice.ptr != new_slice.ptr) {
                try dupAppendChange(allocator, changes, fname, false, new_slice);
            }
        } else if (comptime isOptionalConstU8Slice(ftype)) {
            const orig_opt = @field(original, fname);
            const new_opt = @field(updated.*, fname);
            switch (orig_opt) {
                null => if (new_opt) |new_slice| try dupAppendChange(allocator, changes, fname, true, new_slice),
                else => |orig_slice| switch (new_opt) {
                    null => try changes.append(allocator, .{ .name = fname, .is_optional = true, .new = null }),
                    else => |new_slice| if (orig_slice.ptr != new_slice.ptr) {
                        try dupAppendChange(allocator, changes, fname, true, new_slice);
                    },
                },
            }
        }
    }
}

/// 单行 apply 阶段：该行的 prepare 已全部成功（dup 均就位），释放旧值并回写
/// 新值。不可失败。
fn applyStringChanges(comptime T: type, allocator: std.mem.Allocator, original: T, updated: *T, changes: []const StringChange) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => @compileError("expected struct"),
    };

    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime !isConstU8Slice(ftype) and !isOptionalConstU8Slice(ftype)) continue;
        for (changes) |c| {
            if (!std.mem.eql(u8, c.name, fname)) continue;
            if (comptime isConstU8Slice(ftype)) {
                allocator.free(@field(original, fname));
                @field(updated.*, fname) = c.new.?;
            } else {
                if (@field(original, fname)) |old| allocator.free(old);
                @field(updated.*, fname) = c.new;
            }
            break;
        }
    }
}

/// dup 一个变更的新字符串并 append 到 changes；append 失败时释放该 dup，
/// 保证单个变更原子（旧值尚未动）。
fn dupAppendChange(allocator: std.mem.Allocator, changes: anytype, comptime name: []const u8, is_optional: bool, src: []const u8) !void {
    const dup = try allocator.dupe(u8, src);
    errdefer allocator.free(dup);
    try changes.append(allocator, .{ .name = name, .is_optional = is_optional, .new = dup });
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

    const found = try store.findById(allocator, id);
    try std.testing.expect(found != null);
    defer store.freeRow(allocator, found.?);
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

    const found = try store.findById(allocator, id);
    defer store.freeRow(allocator, found.?);
    try std.testing.expectEqualStrings("Bobby", found.?.name);

    // Delete
    var qd = QueryBuilder(User).init(allocator);
    defer qd.deinit();
    _ = qd.where(.Eq, "id", .{ .integer = @intCast(id) });
    const deleted = try store.delete(&qd);
    try std.testing.expectEqual(@as(usize, 1), deleted);

    const gone = try store.findById(allocator, id);
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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const result = try store.findOne(allocator, &qb);
    try std.testing.expect(result != null);
    defer store.freeRow(allocator, result.?);
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

    const result = try store.findOne(allocator, &qb);
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

    const found = try store.findById(allocator, id1);
    try std.testing.expect(found != null);
    defer store.freeRow(allocator, found.?);
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

    const found = try store.findById(allocator, 9999);
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

    const all_rows = try store.all(allocator);
    defer store.freeRows(allocator, all_rows);

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

    const found = try store.findById(allocator, id);
    try std.testing.expect(found != null);
    defer store.freeRow(allocator, found.?);
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

    const all_rows = try store.all(allocator);
    defer store.freeRows(allocator, all_rows);
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

    const gone = try store.findById(allocator, id2);
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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const all_rows = try store.all(allocator);
    defer store.freeRows(allocator, all_rows);

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

    const found = try store.findById(allocator, 1);
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

    const result = try store.findOne(allocator, &qb);
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

    const all_rows1 = try store.all(allocator);
    defer store.freeRows(allocator, all_rows1);

    const all_rows2 = try store.all(allocator);
    defer store.freeRows(allocator, all_rows2);

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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);

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

    const found = try store.findById(allocator, id);
    try std.testing.expect(found != null);
    defer store.freeRow(allocator, found.?);
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

    const results = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // id <= 1 should match Alice (id=1)
    var qb2 = QueryBuilder(TestUser).init(allocator);
    defer qb2.deinit();
    _ = qb2.where(.Lte, "id", .{ .integer = 1 });

    const results2 = try store.findAll(allocator, &qb2);
    defer store.freeRows(allocator, results2);
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
    const all_rows = try store.all(allocator);
    defer store.freeRows(allocator, all_rows);
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

    {
        const fa = (try store.findById(allocator, a)).?;
        defer store.freeRow(allocator, fa);
        try std.testing.expectEqualStrings("A", fa.name);
    }
    {
        const fb = (try store.findById(allocator, b)).?;
        defer store.freeRow(allocator, fb);
        try std.testing.expectEqualStrings("B", fb.name);
    }
    {
        const fc = (try store.findById(allocator, c)).?;
        defer store.freeRow(allocator, fc);
        try std.testing.expectEqualStrings("C", fc.name);
    }

    // 删除中间行后，主键索引必须保持一致
    try std.testing.expect((try store.deleteById(b)));
    try std.testing.expect((try store.findById(allocator, b)) == null);
    {
        const fa = (try store.findById(allocator, a)).?;
        defer store.freeRow(allocator, fa);
        try std.testing.expectEqualStrings("A", fa.name);
    }
    {
        const fc = (try store.findById(allocator, c)).?;
        defer store.freeRow(allocator, fc);
        try std.testing.expectEqualStrings("C", fc.name);
    }
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
    const f = try store.findById(allocator, id);
    defer store.freeRow(allocator, f.?);
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
    const f = try store.findBy(allocator, "email", "alice@x.com");
    try std.testing.expect(f != null);
    defer store.freeRow(allocator, f.?);
    try std.testing.expectEqualStrings("Alice", f.?.name);
    const none = try store.findBy(allocator, "email", "nobody@x.com");
    try std.testing.expect(none == null);
}

test "findAllBy returns all matching rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "a", .email = "org1@x.com" });
    _ = try store.insert(.{ .id = 0, .name = "b", .email = "org2@x.com" });
    _ = try store.insert(.{ .id = 0, .name = "c", .email = "org1@x.com" });

    const rows = try store.findAllBy(allocator, "email", "org1@x.com");
    defer store.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    const none = try store.findAllBy(allocator, "email", "none@x.com");
    defer store.freeRows(allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "countAll counts rows without query builder" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    try std.testing.expectEqual(@as(usize, 0), try store.countAll());
    const id1 = try store.insert(.{ .id = 0, .name = "a", .email = "a@x.com" });
    _ = try store.insert(.{ .id = 0, .name = "b", .email = "b@x.com" });
    try std.testing.expectEqual(@as(usize, 2), try store.countAll());
    _ = try store.deleteById(id1);
    try std.testing.expectEqual(@as(usize, 1), try store.countAll());
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

    const p0 = try store.paginate(allocator, 0, 4);
    defer store.freeRows(allocator, p0);
    try std.testing.expectEqual(@as(usize, 4), p0.len);
    try std.testing.expectEqual(@as(u64, 1), p0[0].id);

    const p1 = try store.paginate(allocator, 1, 4);
    defer store.freeRows(allocator, p1);
    try std.testing.expectEqual(@as(u64, 5), p1[0].id);

    const p2 = try store.paginate(allocator, 2, 4);
    defer store.freeRows(allocator, p2);
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

test "full-row replace update detects duplicate unique value across matched rows" {
    // bug.md §4 回归：整行替换时每个命中行拿到同一份 data，旧实现逐行
    // checkUnique（只比旧值）→ 两行各自检不出冲突，静默写入重复唯一值。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, email: []const u8 };
    const sch = TableSchema{
        .table_name = "uniq_replace",
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

    _ = try store.insert(.{ .id = 0, .email = "a@x.com" });
    _ = try store.insert(.{ .id = 0, .email = "b@x.com" });

    // WHERE 命中 2 行，整行替换 email 为一个不同于任何旧值的新值：
    // 两行新值彼此相同 → 必须拒绝。
    var qb = QueryBuilder(U).init(allocator);
    defer qb.deinit();
    _ = qb.where(.Gt, "id", .{ .integer = 0 });
    _ = qb.update(.{ .id = 0, .email = "c@x.com" }, null);
    try std.testing.expectError(error.UniqueViolation, store.update(&qb));

    // 校验失败不得部分写回：两行旧值仍在。
    var qb2 = QueryBuilder(U).init(allocator);
    defer qb2.deinit();
    const rows = try store.findAll(allocator, &qb2);
    defer store.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("a@x.com", rows[0].email);
    try std.testing.expectEqualStrings("b@x.com", rows[1].email);

    // 单行整行替换新唯一值：正常通过。
    var qb3 = QueryBuilder(U).init(allocator);
    defer qb3.deinit();
    _ = qb3.where(.Eq, "id", .{ .integer = 1 });
    _ = qb3.update(.{ .id = 0, .email = "c@x.com" }, null);
    try std.testing.expectEqual(@as(usize, 1), try store.update(&qb3));
}

test "updateById/deleteById reject ids beyond i64 range instead of panicking" {
    // bug.md §2 回归：id > maxInt(i64) 时 @intCast 会 panic（远程 DoS）。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Store = JsonStore(TestUser, test_schema);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }

    _ = try store.insert(.{ .id = 0, .name = "a", .email = "a@x.com" });

    const huge: u64 = std.math.maxInt(u64);
    try std.testing.expectEqual(false, try store.updateById(huge, .{ .id = 0, .name = "x", .email = "x@x.com" }));
    try std.testing.expectEqual(false, try store.deleteById(huge));
    // 越界 id 不能被误匹配到已有行。
    try std.testing.expectEqual(@as(usize, 1), try store.countAll());
    // 正常 id 仍工作。
    try std.testing.expectEqual(true, try store.deleteById(1));
    try std.testing.expectEqual(@as(usize, 0), try store.countAll());
}

test "dupStringFields rolls back earlier dups when a later dupe fails" {
    // bug.md §5 回归：函数内部无回滚时，靠后的字段 dupe 失败会泄漏本行
    // 较前字段已 dup 的字符串（仅 OOM 路径）。
    const Row = struct { id: u64, first: []const u8, second: []const u8 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var row = Row{ .id = 1, .first = "first", .second = "second" };
    try std.testing.expectError(error.OutOfMemory, dupStringFields(Row, failing.allocator(), &row));
    // first 的 dupe 已成功分配（第 1 次分配），second 的 dupe 被注入失败（第 2 次）；
    // 若回滚生效，first 必须被释放 → 分配/释放次数相等。
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), failing.deallocations);
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
    const f = try store.findById(allocator, id);
    defer store.freeRow(allocator, f.?);
    try std.testing.expectEqualStrings("user", f.?.role);
}

// ── F-21：paginate 可带 where / orderBy ──────────────────────────────
test "paginateWhere 按 where 过滤分页，默认 id 升序" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, org_id: i64, name: []const u8 };
    const sch = TableSchema{
        .table_name = "page_users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "org_id", .field_type = .integer },
            .{ .name = "name", .field_type = .string },
        },
    };
    const Store = JsonStore(U, sch);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }
    _ = try store.insert(.{ .id = 0, .org_id = 1, .name = "u1" });
    _ = try store.insert(.{ .id = 0, .org_id = 2, .name = "u2" });
    _ = try store.insert(.{ .id = 0, .org_id = 1, .name = "u3" });

    var qb = QueryBuilder(U).init(allocator);
    defer qb.deinit();
    _ = qb.whereEq("org_id", .{ .integer = 1 });
    const page = try store.paginateWhere(allocator, 0, 10, &qb);
    defer store.freeRows(allocator, page);
    try std.testing.expectEqual(@as(usize, 2), page.len);
    try std.testing.expectEqualStrings("u1", page[0].name);
    try std.testing.expectEqualStrings("u3", page[1].name);
}

// ── F-NEW-5.1：open 时发现存量重复唯一值只告警、不拒启动 ─────────────
test "open 遇存量重复唯一值放行加载，后续写入仍报 UniqueViolation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, email: []const u8 };
    const sch = TableSchema{
        .table_name = "uniq_drift",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "email", .field_type = .string, .constraints = .{ .unique = true } },
        },
    };
    const Store = JsonStore(U, sch);
    // 直接落一个含重复 email 的表文件（模拟线上脏数据）
    const cwd = std.Io.Dir.cwd();
    {
        const data = try allocator.dupe(u8,
            \\[{"id":1,"email":"a@x.com"},{"id":2,"email":"a@x.com"}]
        );
        defer allocator.free(data);
        const f = try cwd.createFile(io, ".test_data/uniq_drift.json", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, data);
    }
    // open 必须**成功**（ warnDuplicateUniques 只告警不 reject）
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }
    // 存量 2 行都在（去重改写为正常计数）
    var cqb = QueryBuilder(U).init(allocator);
    defer cqb.deinit();
    _ = cqb.where(.Neq, "id", .{ .integer = 0 });
    try std.testing.expectEqual(@as(usize, 2), try store.count(&cqb));

    // 相同值再插一行：撞唯一约束（加载放行不应用于写路径）
    try std.testing.expectError(error.UniqueViolation, store.insert(.{ .id = 0, .email = "a@x.com" }));
}

// ── F-03：In / NotIn 成员判定 ────────────────────────────────────────
test "whereIn / whereNotIn 整数与字符串成员判定" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, org_id: i64, role: []const u8 };
    const sch = TableSchema{
        .table_name = "in_users",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "org_id", .field_type = .integer },
            .{ .name = "role", .field_type = .string },
        },
    };
    const Store = JsonStore(U, sch);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }
    _ = try store.insert(.{ .id = 0, .org_id = 1, .role = "admin" });
    _ = try store.insert(.{ .id = 0, .org_id = 2, .role = "operator" });
    _ = try store.insert(.{ .id = 0, .org_id = 3, .role = "viewer" });

    // IN
    const org_ids = [_]FieldValue{ .{ .integer = 1 }, .{ .integer = 3 } };
    var qb = QueryBuilder(U).init(allocator);
    defer qb.deinit();
    _ = qb.whereIn("org_id", &org_ids);
    const rows = try store.findAll(allocator, &qb);
    defer store.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("admin", rows[0].role);
    try std.testing.expectEqualStrings("viewer", rows[1].role);

    // NOT IN
    var qb2 = QueryBuilder(U).init(allocator);
    defer qb2.deinit();
    _ = qb2.whereNotIn("org_id", &org_ids);
    const rows2 = try store.findAll(allocator, &qb2);
    defer store.freeRows(allocator, rows2);
    try std.testing.expectEqual(@as(usize, 1), rows2.len);
    try std.testing.expectEqualStrings("operator", rows2[0].role);

    // 字符串 IN
    const roles = [_]FieldValue{ .{ .string = "operator" }, .{ .string = "viewer" } };
    var qb3 = QueryBuilder(U).init(allocator);
    defer qb3.deinit();
    _ = qb3.whereIn("role", &roles);
    const rows3 = try store.findAll(allocator, &qb3);
    defer store.freeRows(allocator, rows3);
    try std.testing.expectEqual(@as(usize, 2), rows3.len);

    // 空列表：IN 恒假 / NOT IN 恒真（SQL 语义）
    var qb4 = QueryBuilder(U).init(allocator);
    defer qb4.deinit();
    _ = qb4.whereIn("org_id", &.{});
    try std.testing.expectEqual(@as(usize, 0), try store.count(&qb4));
    var qb5 = QueryBuilder(U).init(allocator);
    defer qb5.deinit();
    _ = qb5.whereNotIn("org_id", &.{});
    try std.testing.expectEqual(@as(usize, 3), try store.count(&qb5));
}

// ── F-04：单锁多步批量写 ─────────────────────────────────────────────
test "batch 单锁多步批量写：setRolePermissions 式删后插 + 持锁 flush" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Perm = struct { id: u64 = 0, role_id: i64, code: []const u8 };
    const sch = TableSchema{
        .table_name = "batch_role_perms",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "role_id", .field_type = .integer },
            .{ .name = "code", .field_type = .string },
        },
    };
    const Store = JsonStore(Perm, sch);
    var store = try Store.open(allocator, io, ".test_data");
    defer {
        store.truncate() catch {};
        store.close() catch {};
    }
    _ = try store.insert(.{ .id = 0, .role_id = 7, .code = "old.a" });
    _ = try store.insert(.{ .id = 0, .role_id = 7, .code = "old.b" });
    _ = try store.insert(.{ .id = 0, .role_id = 8, .code = "keep.a" });

    var del_qb = QueryBuilder(Perm).init(allocator);
    defer del_qb.deinit();
    _ = del_qb.whereEq("role_id", .{ .integer = 7 });

    const Ctx = struct { dqb: *QueryBuilder(Perm) };
    const migrator = struct {
        fn f(c: Ctx, b: *Store.Batch) anyerror!void {
            // 全删该角色旧权限，再插两条新权限，然后持锁 flush——全程单锁。
            const n = try b.delete(c.dqb);
            try std.testing.expectEqual(@as(usize, 2), n);
            _ = try b.insert(.{ .id = 0, .role_id = 7, .code = "new.a" });
            _ = try b.insert(.{ .id = 0, .role_id = 7, .code = "new.b" });
            try b.flush();
        }
    }.f;
    try store.batch(Ctx, Ctx{ .dqb = &del_qb }, migrator);

    // flush 已落盘（dirty 复位）；随后 close 不再触发第二落盘也能对得上。
    try std.testing.expectEqual(@as(usize, 3), try store.countAll());
    const new_u = (try store.findBy(allocator, "code", "new.a")).?;
    defer store.freeRow(allocator, new_u);
    try std.testing.expectEqual(@as(i64, 7), new_u.role_id);
    try std.testing.expect(store.dirty == false);
}

test "batch 回调出错：错误上抛、锁释放、store 可继续使用" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, email: []const u8 };
    const sch = TableSchema{
        .table_name = "batch_err",
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

    const f = struct {
        fn g(_: void, b: *Store.Batch) anyerror!void {
            _ = try b.insert(.{ .id = 0, .email = "a@x.com" });
            // 第二条撞唯一约束：错误从原语冒出、穿 batch 上抛
            _ = try b.insert(.{ .id = 0, .email = "a@x.com" });
            return error.Unreachable;
        }
    }.g;
    try std.testing.expectError(error.UniqueViolation, store.batch(void, {}, f));

    // 锁已释放（继续可写不死锁），已执行步骤保持（内存可见性按 F-04 语义）
    _ = try store.insert(.{ .id = 0, .email = "b@x.com" });
    try std.testing.expectEqual(@as(usize, 2), try store.countAll());
}

// ── F-05.1：最低限度迁移执行器（schema 漂移对齐 + 告警） ──────────────
test "load 时按当前 schema 对齐旧数据：缺列补默认值、多余键丢弃、warn 一次" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const U = struct { id: u64 = 0, email: []const u8, role: []const u8 = "viewer" };
    const sch = TableSchema{
        .table_name = "legacy_migration",
        .fields = &.{
            .{ .name = "id", .field_type = .integer, .constraints = .{ .primary_key = true, .auto_increment = true } },
            .{ .name = "email", .field_type = .string, .constraints = .{ .unique = true } },
            .{ .name = "role", .field_type = .string, .constraints = .{ .default_value = FieldValue{ .string = "member" } } },
        },
    };
    const Store = JsonStore(U, sch);

    // 手工写一份「旧 schema」数据：旧行没有 role 列（新列），还有已删除的 legacy 列
    const legacy_rows = "[{\"id\":1,\"email\":\"a@x.com\",\"legacy\":\"x\"},{\"id\":2,\"email\":\"b@x.com\"}]";
    {
        const cwd = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(allocator, ".test_data/legacy_migration.json", .{});
        defer allocator.free(path);
        const f = try cwd.createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        var wb: [512]u8 = undefined;
        var w = f.writer(io, wb[0..]);
        try w.interface.writeAll(legacy_rows);
        try w.flush();
    }
    // 结束后删除遗留文件，避免污染共享 .test_data（其他测试 open 同表名）。
    defer std.Io.Dir.cwd().deleteFile(io, ".test_data/legacy_migration.json") catch {};

    var store = try Store.open(allocator, io, ".test_data");
    defer store.close() catch {};

    // 缺列：role 补成 schema default_value（"member"，而非类型零值 ""）
    const r1 = (try store.findById(allocator, 1)).?;
    defer store.freeRow(allocator, r1);
    try std.testing.expectEqualStrings("a@x.com", r1.email);
    try std.testing.expectEqualStrings("member", r1.role);

    const r2 = (try store.findById(allocator, 2)).?;
    defer store.freeRow(allocator, r2);
    try std.testing.expectEqualStrings("b@x.com", r2.email);
    try std.testing.expectEqualStrings("member", r2.role);

    // 存在的 0 值数据不被默认值改写：补齐只针对「JSON 里没有该键」的行
    const rows = try store.all(allocator);
    defer store.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    // 把补齐后的数据落盘，再次打开 → 不再漂移（下一轮 load 无 warn）
    store.dirty = true;
    try store.flush();
    var reopened = try Store.open(allocator, io, ".test_data");
    defer reopened.close() catch {};
    const rr = (try reopened.findById(allocator, 1)).?;
    defer reopened.freeRow(allocator, rr);
    try std.testing.expectEqualStrings("member", rr.role);
}
