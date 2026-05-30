//! 内置中间件实现 (Zig 0.17)
//!
//! 提供日志中间件、Bearer Token 鉴权中间件和文件日志中间件。
//! 中间件使用堆分配 + VTable 模式，适配标准 `Middleware` 接口。
//!
//! # 文件日志特性
//!
//! - 日志级别：debug / info / warn / err，可按级别过滤
//! - 写入缓冲：减少磁盘 I/O，默认 8KB 缓冲区
//! - 异步写入：后台任务写盘，`log()` 调用立即返回不阻塞请求
//! - 自动创建目录：日志路径的父目录不存在时自动创建
//! - 每日轮转：日期变更时自动创建新日志文件
//! - 大小滚动：文件超过阈值时轮转并保留编号备份
//! - gzip 压缩：轮转后的旧日志自动压缩为 .gz

const std = @import("std");
const flate = std.compress.flate;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const NextAction = @import("middleware.zig").NextAction;
const Middle = @import("middleware.zig");

// =========================================================================
// LogMiddleware — 请求日志 (控制台)
// =========================================================================

pub const LogMiddleware = struct {
    prefix: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) !*LogMiddleware {
        const ptr = try allocator.create(LogMiddleware);
        ptr.* = .{ .prefix = prefix, .allocator = allocator, .io = io, .middle = undefined };
        ptr.middle = Middle.init(LogMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *LogMiddleware, ctx: *RequestContext) anyerror!NextAction {
        std.log.debug("[{s}] {s} {s}", .{ self.prefix, @tagName(ctx.method), ctx.path });
        return .next;
    }

    pub fn deinit(self: *LogMiddleware) void {
        std.log.debug("[{s}] LogMiddleware destroyed", .{self.prefix});
        self.allocator.destroy(self);
    }
};

// =========================================================================
// AuthMiddleware — Bearer Token 鉴权
// =========================================================================

pub const AuthMiddleware = struct {
    token: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, expected_token: []const u8) !*AuthMiddleware {
        const ptr = try allocator.create(AuthMiddleware);
        errdefer allocator.destroy(ptr);
        const token_dup = try allocator.dupe(u8, expected_token);
        ptr.* = .{ .allocator = allocator, .io = io, .middle = undefined, .token = token_dup };
        ptr.middle = Middle.init(AuthMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *AuthMiddleware, ctx: *RequestContext) anyerror!NextAction {
        const auth_header = ctx.getHeader("Authorization") orelse {
            std.log.debug("[Auth] Missing Authorization header", .{});
            return .err;
        };
        const bearer_prefix = "Bearer ";
        if (!std.mem.startsWith(u8, auth_header, bearer_prefix)) {
            std.log.debug("[Auth] Invalid Authorization scheme", .{});
            return .err;
        }
        const provided_token = auth_header[bearer_prefix.len..];
        if (std.mem.eql(u8, provided_token, self.token)) return .next;
        std.log.debug("[Auth] Token mismatch", .{});
        return .err;
    }

    pub fn deinit(self: *AuthMiddleware) void {
        self.allocator.free(self.token);
        self.allocator.destroy(self);
    }
};

// =========================================================================
// RotatingFileLogger — 滚动文件日志器
// =========================================================================

pub const RotatingFileLogger = struct {
    // ---- 配置 ----
    base_path: []const u8,
    max_file_size: u64,
    max_backup_files: u32,
    compress_rotated: bool,
    rotate_daily: bool,
    min_level: Level,
    buf_size: usize,
    async_enabled: bool,

    // ---- 同步模式状态 ----
    current_file: ?std.Io.File,
    current_size: u64,
    current_year: u16,
    current_month: u8,
    current_day: u8,
    write_buf: ?[]u8,
    write_buf_end: usize,

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,

    // ---- 异步模式状态 ----
    async_queue: ?AsyncQueue,
    async_future: ?std.Io.Future(std.Io.Cancelable!void) = .{ .any_future = null, .result = {} },

    const Date = struct { year: u16, month: u8, day: u8 };

    const ASYNC_QUEUE_CAP = 4096;

    const AsyncQueue = struct {
        entries: []AsyncEntry,
        write_pos: std.atomic.Value(u32),
        read_pos: std.atomic.Value(u32),

        fn init(allocator: std.mem.Allocator) !AsyncQueue {
            const entries = try allocator.alloc(AsyncEntry, ASYNC_QUEUE_CAP);
            @memset(entries, .{ .level = .info, .text = null });
            return .{
                .entries = entries,
                .write_pos = std.atomic.Value(u32).init(0),
                .read_pos = std.atomic.Value(u32).init(0),
            };
        }

        fn deinit(self: *AsyncQueue, allocator: std.mem.Allocator) void {
            for (self.entries) |*e| {
                if (e.text) |t| allocator.free(t);
            }
            allocator.free(self.entries);
        }

        /// SPSC push — 由调用者（单生产者）调用。
        fn push(self: *AsyncQueue, level: Level, text: []const u8) bool {
            const w = self.write_pos.load(.acquire);
            const r = self.read_pos.load(.acquire);
            const next = (w + 1) % ASYNC_QUEUE_CAP;
            if (next == r) return false; // 队列满
            self.entries[w] = .{ .level = level, .text = text };
            self.write_pos.store(next, .release);
            return true;
        }

        /// SPSC pop — 由后台线程（单消费者）调用。
        fn pop(self: *AsyncQueue) ?struct { level: Level, text: []const u8 } {
            const r = self.read_pos.load(.acquire);
            const w = self.write_pos.load(.acquire);
            if (r == w) return null;
            const entry = self.entries[r];
            self.entries[r] = .{ .level = .info, .text = null };
            self.read_pos.store((r + 1) % ASYNC_QUEUE_CAP, .release);
            return .{ .level = entry.level, .text = entry.text.? };
        }
    };

    const AsyncEntry = struct {
        level: Level,
        text: ?[]const u8, // heap-allocated, owned by queue
    };

    // ---- 公开类型 ----

    pub const Level = enum(u3) {
        err = 0,
        warn = 1,
        info = 2,
        debug = 3,

        pub fn label(l: Level) []const u8 {
            return switch (l) {
                .debug => "DEBUG",
                .info => "INFO ",
                .warn => "WARN ",
                .err => "ERROR",
            };
        }
        pub fn atLeast(l: Level, min: Level) bool {
            return @intFromEnum(l) <= @intFromEnum(min);
        }
    };

    pub const Config = struct {
        max_file_size: u64 = 10 * 1024 * 1024,
        max_backup_files: u32 = 10,
        compress_rotated: bool = true,
        rotate_daily: bool = true,
        min_level: Level = .info,
        buf_size: usize = 8192,
        /// 启用异步写入后，log() 立即返回，后台线程负责写磁盘。
        async_enabled: bool = false,
    };

    // =================================================================
    // 公开方法
    // =================================================================

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, config: Config) !RotatingFileLogger {
        ensureDir(io, base_path);

        var write_buf: ?[]u8 = null;
        var async_queue: ?AsyncQueue = null;

        if (config.async_enabled) {
            async_queue = try AsyncQueue.init(allocator);
        } else if (config.buf_size > 0) {
            write_buf = try allocator.alloc(u8, config.buf_size);
        }

        var logger = RotatingFileLogger{
            .allocator = allocator,
            .io = io,
            .base_path = base_path,
            .max_file_size = config.max_file_size,
            .max_backup_files = config.max_backup_files,
            .compress_rotated = config.compress_rotated,
            .rotate_daily = config.rotate_daily,
            .min_level = config.min_level,
            .buf_size = config.buf_size,
            .async_enabled = config.async_enabled,
            .current_file = null,
            .current_size = 0,
            .current_year = 0,
            .current_month = 0,
            .current_day = 0,
            .write_buf = write_buf,
            .write_buf_end = 0,
            .mutex = .init,
            .async_queue = async_queue,
        };

        if (config.async_enabled) {
            // 线程由首次 log() 调用懒启动，先设置日期保证首条日志时间戳正确
            const today = logger.getCurrentDate();
            logger.current_year = today.year;
            logger.current_month = today.month;
            logger.current_day = today.day;
        } else {
            logger.rotateExistingFile();
            try logger.openLogFile();
        }

        return logger;
    }

    pub fn deinit(self: *RotatingFileLogger) void {
        if (self.async_enabled) {
            // 请求取消后台任务并等待完成
            if (self.async_future) |*f| {
                _ = f.cancel(self.io) catch unreachable;
            }
            if (self.async_queue) |*q| q.deinit(self.allocator);
        } else {
            if (self.current_file) |file| {
                self.flushBuffer() catch {};
                file.close(self.io);
            }
            if (self.write_buf) |buf| {
                self.allocator.free(buf);
            }
        }
    }

    // ---- 级别日志 ----

    pub fn debug(self: *RotatingFileLogger, comptime fmt: []const u8, args: anytype) !void {
        if (!Level.atLeast(.debug, self.min_level)) return;
        try self.log(.debug, fmt, args);
    }
    pub fn info(self: *RotatingFileLogger, comptime fmt: []const u8, args: anytype) !void {
        if (!Level.atLeast(.info, self.min_level)) return;
        try self.log(.info, fmt, args);
    }
    pub fn warn(self: *RotatingFileLogger, comptime fmt: []const u8, args: anytype) !void {
        if (!Level.atLeast(.warn, self.min_level)) return;
        try self.log(.warn, fmt, args);
    }
    pub fn err(self: *RotatingFileLogger, comptime fmt: []const u8, args: anytype) !void {
        if (!Level.atLeast(.err, self.min_level)) return;
        try self.log(.err, fmt, args);
    }

    pub fn log(self: *RotatingFileLogger, level: Level, comptime format: []const u8, args: anytype) !void {
        if (!Level.atLeast(level, self.min_level)) return;

        if (self.async_enabled) {
            // 懒启动后台任务（首次调用 log 时）
            if (self.async_future == null) {
                self.rotateExistingFile();
                self.openLogFile() catch return;
                self.async_future = self.io.async(asyncWriterThread, .{self});
            }
            // 格式化 + 推入队列
            const now = std.Io.Timestamp.now(self.io, .real);
            const secs = now.toSeconds();
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
            const day_secs = epoch.getDaySeconds();

            const msg = try std.fmt.allocPrint(self.allocator, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}][{s}] " ++ format ++ "\n", .{
                self.current_year,          self.current_month,            self.current_day,
                day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour(), day_secs.getSecondsIntoMinute(),
                Level.label(level),
            } ++ args);
            // 推入锁-free 队列；满则丢弃并直接写盘
            if (self.async_queue) |*q| {
                if (!q.push(level, msg)) {
                    self.allocator.free(msg);
                    // fallback: 队列满时丢弃（保证不阻塞调用者）
                }
            }
            return;
        }

        // 同步路径
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);

        try self.checkRotation();

        const now = std.Io.Timestamp.now(self.io, .real);
        const secs = now.toSeconds();
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
        const day_secs = epoch.getDaySeconds();

        try self.writeFormatted("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}][{s}] ", .{
            self.current_year,          self.current_month,            self.current_day,
            day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour(), day_secs.getSecondsIntoMinute(),
            Level.label(level),
        });
        try self.writeFormatted(format ++ "\n", args);
        try self.flushIfLarge();
        try self.flushBuffer();
    }

    // =================================================================
    // 异步后台线程
    // =================================================================

    fn asyncWriterThread(self: *RotatingFileLogger) std.Io.Cancelable!void {
        // 初始化文件
        self.rotateExistingFile();
        self.openLogFile() catch return;

        var write_buf: ?[]u8 = null;
        if (self.buf_size > 0) {
            write_buf = self.allocator.alloc(u8, self.buf_size) catch null;
        }
        self.write_buf = write_buf;

        defer {
            if (self.current_file) |file| {
                self.flushBuffer() catch {};
                file.close(self.io);
            }
            if (self.write_buf) |buf| self.allocator.free(buf);
        }

        while (true) {
            try self.io.checkCancel();
            // 排空队列中的所有消息
            var did_work = false;
            while (self.async_queue) |*q| {
                const entry = q.pop() orelse break;
                defer self.allocator.free(entry.text);

                self.checkRotation() catch continue;
                self.writeFormatted("{s}", .{entry.text}) catch continue;
                did_work = true;
            }
            if (did_work) {
                self.flushBuffer() catch {};
            } else {
                // 队列空，短暂休眠避免忙等
                std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(@intCast(1 * std.time.ns_per_ms)), .awake) catch {};
            }
        }
    }

    // =================================================================
    // 内部 — 轮转（同步和异步共用）
    // =================================================================

    fn getCurrentDate(self: *const RotatingFileLogger) Date {
        const now = std.Io.Timestamp.now(self.io, .real);
        const secs = now.toSeconds();
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{ .year = year_day.year, .month = month_day.month.numeric(), .day = @as(u8, month_day.day_index) + 1 };
    }

    fn checkRotation(self: *RotatingFileLogger) !void { // error set includes error.Canceled
        if (self.rotate_daily) {
            const today = self.getCurrentDate();
            if (self.current_year != 0 and
                (self.current_year != today.year or self.current_month != today.month or self.current_day != today.day))
            {
                if (self.current_size > 0) {
                    try self.rotateDaily(today);
                } else {
                    self.current_year = today.year;
                    self.current_month = today.month;
                    self.current_day = today.day;
                }
            }
            if (self.current_year == 0) {
                self.current_year = today.year;
                self.current_month = today.month;
                self.current_day = today.day;
            }
        }
        if (self.current_size >= self.max_file_size) {
            try self.rotateSize();
        }
    }

    fn rotateDaily(self: *RotatingFileLogger, new_date: Date) !void {
        if (self.current_file) |file| {
            self.flushBuffer() catch {};
            file.close(self.io);
            self.current_file = null;
        }
        const dir = std.Io.Dir.cwd();
        const rotated_path = try std.fmt.allocPrint(self.allocator, "{s}.{d:0>4}-{d:0>2}-{d:0>2}", .{
            self.base_path, self.current_year, self.current_month, self.current_day,
        });
        defer self.allocator.free(rotated_path);
        dir.rename(self.base_path, dir, rotated_path, self.io) catch {};
        if (self.compress_rotated) self.compressFile(rotated_path) catch {};
        self.current_year = new_date.year;
        self.current_month = new_date.month;
        self.current_day = new_date.day;
        self.current_size = 0;
        try self.openLogFile();
    }

    fn rotateSize(self: *RotatingFileLogger) !void {
        if (self.current_file) |file| {
            self.flushBuffer() catch {};
            file.close(self.io);
            self.current_file = null;
        }
        const dir = std.Io.Dir.cwd();
        if (self.max_backup_files == 0) {
            dir.deleteFile(self.io, self.base_path) catch {};
            self.current_size = 0;
            try self.openLogFile();
            return;
        }
        const oldest = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, self.max_backup_files });
        defer self.allocator.free(oldest);
        dir.deleteFile(self.io, oldest) catch {};
        if (self.compress_rotated) {
            const oldest_gz = try std.fmt.allocPrint(self.allocator, "{s}.gz", .{oldest});
            defer self.allocator.free(oldest_gz);
            dir.deleteFile(self.io, oldest_gz) catch {};
        }
        var i: u32 = self.max_backup_files - 1;
        while (i >= 1) {
            const old_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i });
            defer self.allocator.free(old_path);
            const new_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i + 1 });
            defer self.allocator.free(new_path);
            dir.rename(old_path, dir, new_path, self.io) catch {};
            if (self.compress_rotated) {
                const old_gz = try std.fmt.allocPrint(self.allocator, "{s}.gz", .{old_path});
                defer self.allocator.free(old_gz);
                const new_gz = try std.fmt.allocPrint(self.allocator, "{s}.gz", .{new_path});
                defer self.allocator.free(new_gz);
                dir.rename(old_gz, dir, new_gz, self.io) catch {};
            }
            if (i == 1) break;
            i -= 1;
        }
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.1", .{self.base_path});
        defer self.allocator.free(backup_path);
        dir.rename(self.base_path, dir, backup_path, self.io) catch {};
        if (self.compress_rotated) self.compressFile(backup_path) catch {};
        self.current_size = 0;
        try self.openLogFile();
    }

    fn rotateExistingFile(self: *RotatingFileLogger) void {
        const dir = std.Io.Dir.cwd();
        dir.access(self.io, self.base_path, .{}) catch return;
        const today = self.getCurrentDate();
        self.current_year = today.year;
        self.current_month = today.month;
        self.current_day = today.day;
        const rotated_path = std.fmt.allocPrint(self.allocator, "{s}.{d:0>4}-{d:0>2}-{d:0>2}", .{
            self.base_path, today.year, today.month, today.day,
        }) catch return;
        defer self.allocator.free(rotated_path);
        dir.rename(self.base_path, dir, rotated_path, self.io) catch {};
        if (self.compress_rotated) self.compressFile(rotated_path) catch {};
    }

    // =================================================================
    // 内部 — 文件 I/O & 缓冲（同步和异步共用）
    // =================================================================

    fn openLogFile(self: *RotatingFileLogger) !void { // error set includes error.Canceled
        self.current_file = try std.Io.Dir.cwd().createFile(self.io, self.base_path, .{});
        self.current_size = 0;
    }

    fn writeFormatted(self: *RotatingFileLogger, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [2048]u8 = undefined;
        var temp_writer = std.Io.Writer.fixed(&stack_buf);
        temp_writer.print(fmt, args) catch {
            const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(msg);
            return self.writeBuf(msg);
        };
        return self.writeBuf(temp_writer.buffered());
    }

    fn writeBuf(self: *RotatingFileLogger, data: []const u8) !void {
        const file = self.current_file orelse return;
        if (self.write_buf) |buf| {
            var remaining = data;
            while (remaining.len > 0) {
                const space = buf.len - self.write_buf_end;
                if (space == 0) {
                    try self.flushBuffer();
                    continue;
                }
                const n = @min(remaining.len, space);
                @memcpy(buf[self.write_buf_end..][0..n], remaining[0..n]);
                self.write_buf_end += n;
                self.current_size += n;
                remaining = remaining[n..];
            }
        } else {
            try file.writeStreamingAll(self.io, data);
            self.current_size += data.len;
        }
    }

    fn flushBuffer(self: *RotatingFileLogger) !void {
        if (self.current_file == null) return;
        const file = self.current_file.?;
        if (self.write_buf) |buf| {
            if (self.write_buf_end > 0) {
                try file.writeStreamingAll(self.io, buf[0..self.write_buf_end]);
                self.write_buf_end = 0;
            }
        }
    }

    fn flushIfLarge(self: *RotatingFileLogger) !void {
        if (self.write_buf) |buf| {
            if (self.write_buf_end > buf.len * 4 / 5) try self.flushBuffer();
        }
    }

    // =================================================================
    // 内部 — 压缩
    // =================================================================

    fn compressFile(self: *const RotatingFileLogger, path: []const u8) !void {
        const dir = std.Io.Dir.cwd();
        const source_data = dir.readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024 * 1024)) catch return;
        defer self.allocator.free(source_data);
        const gz_path = try std.fmt.allocPrint(self.allocator, "{s}.gz", .{path});
        defer self.allocator.free(gz_path);

        var alloc_writer = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        errdefer alloc_writer.deinit();
        var compress_buf: [flate.max_window_len]u8 = undefined;
        var compressor = try flate.Compress.init(&alloc_writer.writer, &compress_buf, .gzip, .default);
        try compressor.writer.writeAll(source_data);
        try compressor.finish();
        const compressed_data = alloc_writer.written();
        defer alloc_writer.deinit();

        var gz_file = try dir.createFile(self.io, gz_path, .{});
        defer gz_file.close(self.io);
        try gz_file.writeStreamingAll(self.io, compressed_data);
        dir.deleteFile(self.io, path) catch {};
    }

    // =================================================================
    // 内部 — 工具
    // =================================================================

    fn ensureDir(io: std.Io, path: []const u8) void {
        const sep = std.fs.path.sep;
        if (std.mem.lastIndexOfScalar(u8, path, sep)) |idx| {
            if (idx == 0) return;
            const dir_path = path[0..idx];
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
        }
    }
};

// =========================================================================
// 测试
// =========================================================================

test "Level.label returns correct labels" {
    const t = std.testing;
    try t.expectEqualStrings("ERROR", RotatingFileLogger.Level.label(.err));
    try t.expectEqualStrings("WARN ", RotatingFileLogger.Level.label(.warn));
    try t.expectEqualStrings("INFO ", RotatingFileLogger.Level.label(.info));
    try t.expectEqualStrings("DEBUG", RotatingFileLogger.Level.label(.debug));
}

test "Level.atLeast filters by minimum level" {
    const t = std.testing;
    // Level encoding: err=0, warn=1, info=2, debug=3
    // atLeast(l, min) = @intFromEnum(l) <= @intFromEnum(min)
    // Lower numeric value = higher severity; allowed when severity >= min

    // err (0) passes every filter
    try t.expect(RotatingFileLogger.Level.atLeast(.err, .err));
    try t.expect(RotatingFileLogger.Level.atLeast(.err, .warn));
    try t.expect(RotatingFileLogger.Level.atLeast(.err, .info));
    try t.expect(RotatingFileLogger.Level.atLeast(.err, .debug));

    // warn (1) blocked by err filter, passes warn+
    try t.expect(!RotatingFileLogger.Level.atLeast(.warn, .err));
    try t.expect(RotatingFileLogger.Level.atLeast(.warn, .warn));
    try t.expect(RotatingFileLogger.Level.atLeast(.warn, .info));
    try t.expect(RotatingFileLogger.Level.atLeast(.warn, .debug));

    // info (2) blocked by err/warn filters
    try t.expect(!RotatingFileLogger.Level.atLeast(.info, .err));
    try t.expect(!RotatingFileLogger.Level.atLeast(.info, .warn));
    try t.expect(RotatingFileLogger.Level.atLeast(.info, .info));
    try t.expect(RotatingFileLogger.Level.atLeast(.info, .debug));

    // debug (3) only passes debug filter
    try t.expect(!RotatingFileLogger.Level.atLeast(.debug, .err));
    try t.expect(!RotatingFileLogger.Level.atLeast(.debug, .warn));
    try t.expect(!RotatingFileLogger.Level.atLeast(.debug, .info));
    try t.expect(RotatingFileLogger.Level.atLeast(.debug, .debug));
}

test "Date struct construction and field access" {
    const t = std.testing;
    const date = RotatingFileLogger.Date{ .year = 2026, .month = 5, .day = 30 };
    try t.expectEqual(@as(u16, 2026), date.year);
    try t.expectEqual(@as(u8, 5), date.month);
    try t.expectEqual(@as(u8, 30), date.day);
}

test "Date struct zero values" {
    const t = std.testing;
    const d = RotatingFileLogger.Date{ .year = 0, .month = 0, .day = 0 };
    try t.expectEqual(@as(u16, 0), d.year);
    try t.expectEqual(@as(u8, 0), d.month);
    try t.expectEqual(@as(u8, 0), d.day);
}

// =========================================================================
// FileLogMiddleware — 文件日志中间件
// =========================================================================

pub const FileLogMiddleware = struct {
    logger: RotatingFileLogger,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, config: RotatingFileLogger.Config) !*FileLogMiddleware {
        const ptr = try allocator.create(FileLogMiddleware);
        errdefer allocator.destroy(ptr);
        const logger = try RotatingFileLogger.init(allocator, io, base_path, config);
        ptr.* = .{ .logger = logger, .allocator = allocator, .io = io, .middle = undefined };
        ptr.middle = Middle.init(FileLogMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *FileLogMiddleware, ctx: *RequestContext) anyerror!NextAction {
        self.logger.info("[ACCESS] {s} {s}", .{ @tagName(ctx.method), ctx.path }) catch {};
        return .next;
    }

    pub fn deinit(self: *FileLogMiddleware) void {
        self.logger.deinit();
        self.allocator.destroy(self);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Level.atLeast - debug allows all" {
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.debug, .debug));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.info, .debug));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.warn, .debug));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.err, .debug));
}

test "Level.atLeast - info filters debug" {
    try std.testing.expect(!RotatingFileLogger.Level.atLeast(.debug, .info));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.info, .info));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.warn, .info));
    try std.testing.expect(RotatingFileLogger.Level.atLeast(.err, .info));
}

test "Level.label - correct strings" {
    try std.testing.expectEqualStrings("DEBUG", RotatingFileLogger.Level.label(.debug));
    try std.testing.expectEqualStrings("INFO ", RotatingFileLogger.Level.label(.info));
    try std.testing.expectEqualStrings("WARN ", RotatingFileLogger.Level.label(.warn));
    try std.testing.expectEqualStrings("ERROR", RotatingFileLogger.Level.label(.err));
}

test "Config defaults" {
    const cfg: RotatingFileLogger.Config = .{};
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), cfg.max_file_size);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_backup_files);
    try std.testing.expectEqual(true, cfg.compress_rotated);
    try std.testing.expectEqual(true, cfg.rotate_daily);
    try std.testing.expectEqual(RotatingFileLogger.Level.info, cfg.min_level);
    try std.testing.expectEqual(@as(usize, 8192), cfg.buf_size);
    try std.testing.expectEqual(false, cfg.async_enabled);
}
