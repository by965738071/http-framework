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
const core = @import("core");
const RequestContext = core.RequestContext;
const Response = core.Response;
const NextAction = core.NextAction;
const Middle = core.Middleware;

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

    pub fn process(self: *LogMiddleware, ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = res;
        std.log.debug("[{s}] {s} {s}", .{ self.prefix, @tagName(ctx.method), ctx.path });
        return .next;
    }

    pub fn deinit(self: *LogMiddleware) void {
        std.log.debug("[{s}] LogMiddleware destroyed", .{self.prefix});
        self.allocator.destroy(self);
    }
};

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
    /// UTC 偏移秒数（见 Config.utc_offset_seconds）
    utc_offset_seconds: i64,

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,

    // ---- 异步模式状态 ----
    async_queue: ?AsyncQueue,
    // 必须默认为 null：懒启动逻辑靠 `async_future == null` 判断后台任务是否已启动。
    // 之前这里塞了一个非 null 的哑值，导致写盘任务永远不会启动，
    // 队列填满后所有日志被静默丢弃。
    async_future: ?std.Io.Future(std.Io.Cancelable!void) = null,
    /// 后台写盘任务的停机标志。
    ///
    /// 不能只依赖 cancel：取消信号只在**下一个**取消点投递一次，而排空循环里的
    /// 文件 I/O（checkRotation / writeFormatted）用 `catch continue` 吞掉错误，
    /// 会把这唯一一次信号吃掉，任务从此再也收不到通知 → deinit 永久阻塞。
    stopping: std.atomic.Value(bool) = .init(false),

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

        /// 环形队列 push。
        ///
        /// 本身只对「单生产者 + 单消费者」安全。日志会被每个连接任务并发调用，
        /// 因此调用方（enqueueAsync）必须持有 logger.mutex 才能调用它。
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
            return @backingInt(l) <= @backingInt(min);
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
        /// UTC 偏移秒数，用于把日志时间戳和每日轮转转换为本地时区。
        /// 东八区填 `8 * 3600`，西五区填 `-5 * 3600`，默认 0 表示 UTC。
        utc_offset_seconds: i64 = 0,
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
        }
        errdefer if (async_queue) |*q| q.deinit(allocator);

        if (config.buf_size > 0) {
            write_buf = try allocator.alloc(u8, config.buf_size);
        }
        errdefer if (write_buf) |b| allocator.free(b);

        var instance = RotatingFileLogger{
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
            .utc_offset_seconds = config.utc_offset_seconds,
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

        // 同步/异步都在这里打开文件：文件与缓冲区的生命周期统一由 init/deinit 管理，
        // 后台写盘任务只负责“排空队列并写入”，不再自己开关文件。
        // 这样在拿不到并发能力时也能安全地就地同步写盘。
        instance.rotateExistingFile();
        try instance.openLogFile();

        return instance;
    }

    pub fn deinit(self: *RotatingFileLogger) void {
        if (self.async_enabled) {
            // 先立起停机标志，再 cancel 去唤醒可能正在 sleep 的任务。
            self.stopping.store(true, .release);
            // cancel 会**等待任务真正退出**：它还在读 async_queue，
            // 不等就释放队列会造成 use-after-free。
            if (self.async_future) |*f| {
                f.cancel(self.io) catch {};
                self.async_future = null;
            }
            // 写盘任务已确定退出，把队列里剩下的日志补写完再释放，
            // 否则进程退出时最后一批日志（往往正是崩溃现场）会被丢掉。
            if (self.async_queue) |*q| {
                while (q.pop()) |entry| {
                    defer self.allocator.free(entry.text);
                    self.writeFormatted("{s}", .{entry.text}) catch {};
                }
                q.deinit(self.allocator);
                self.async_queue = null;
            }
        }

        if (self.current_file) |file| {
            self.flushBuffer() catch {};
            file.close(self.io);
            self.current_file = null;
        }
        if (self.write_buf) |buf| {
            self.allocator.free(buf);
            self.write_buf = null;
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
            // 格式化 + 推入队列（后台写盘任务在首次入队时懒启动）
            const dt = self.currentDateTime();

            const msg = try std.fmt.allocPrint(self.allocator, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}][{s}] " ++ format ++ "\n", .{
                dt.date.year,                  dt.date.month,                    dt.date.day,
                dt.day_secs.getHoursIntoDay(), dt.day_secs.getMinutesIntoHour(), dt.day_secs.getSecondsIntoMinute(),
                Level.label(level),
            } ++ args);
            self.enqueueAsync(level, msg);
            return;
        }

        // 同步路径
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.checkRotation();

        const dt = self.currentDateTime();

        try self.writeFormatted("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}][{s}] ", .{
            dt.date.year,                  dt.date.month,                    dt.date.day,
            dt.day_secs.getHoursIntoDay(), dt.day_secs.getMinutesIntoHour(), dt.day_secs.getSecondsIntoMinute(),
            Level.label(level),
        });
        try self.writeFormatted(format ++ "\n", args);
        try self.flushIfLarge();
        try self.flushBuffer();
    }

    // =================================================================
    // core.Logger 实现
    // =================================================================

    /// core 只交出一行已格式化的文本，时间戳、级别标签、轮转、压缩、
    /// 异步排队全部在这里完成。
    ///
    /// 不返回错误：写盘失败静默丢弃，日志绝不能拖垮请求处理。
    pub fn write(self: *RotatingFileLogger, level: core.LogLevel, msg: []const u8) void {
        self.log(fromCoreLevel(level), "{s}", .{msg}) catch {};
    }

    /// 取得可注入 `server.setLogger()` 的接口句柄。
    /// 句柄指向 self，调用方须保证本实例活得比 Server 久。
    pub fn logger(self: *RotatingFileLogger) core.Logger {
        return core.Logger.init(RotatingFileLogger, self);
    }

    fn fromCoreLevel(level: core.LogLevel) Level {
        return switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }

    // =================================================================
    // 结构化日志（JSON 格式）
    // =================================================================

    /// 记录一条结构化 JSON 日志。
    /// `event` 为事件名称，`fields` 必须是 struct 类型。
    pub fn logStructured(self: *RotatingFileLogger, level: Level, comptime event: []const u8, fields: anytype) !void {
        if (!Level.atLeast(level, self.min_level)) return;

        var ts_buf: [25]u8 = undefined;
        const timestamp = self.formatTimestamp(&ts_buf);

        // 构建 JSON 行
        var json_buf: [4096]u8 = undefined;
        var fbs = std.Io.FixedBufferStream([]u8){ .buf = &json_buf, .pos = 0 };
        const writer = fbs.writer();

        try writer.print("{{\"ts\":\"{s}\",\"level\":\"{s}\",\"event\":\"{s}\"", .{
            timestamp,
            @tagName(level),
            event,
        });

        // 反射 fields struct 的所有字段
        const FieldType = @TypeOf(fields);
        const type_info = @typeInfo(FieldType);
        if (type_info == .@"struct") {
            inline for (type_info.@"struct".fields) |field| {
                const value = @field(fields, field.name);
                try writer.print(",\"{s}\":", .{field.name});
                try formatJsonValue(&writer, value);
            }
        }

        try writer.writeAll("}\n");

        const json_line = fbs.getWritten();

        // 通过现有日志管道输出
        if (self.async_enabled) {
            const msg = try self.allocator.dupe(u8, json_line);
            self.enqueueAsync(level, msg);
            return;
        }

        // 同步路径
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.checkRotation();
        try self.writeBuf(json_line);
        try self.flushIfLarge();
        try self.flushBuffer();
    }

    /// 便捷方法：结构化 DEBUG 日志
    pub fn logStructuredDebug(self: *RotatingFileLogger, comptime event: []const u8, fields: anytype) !void {
        try self.logStructured(.debug, event, fields);
    }

    /// 便捷方法：结构化 INFO 日志
    pub fn logStructuredInfo(self: *RotatingFileLogger, comptime event: []const u8, fields: anytype) !void {
        try self.logStructured(.info, event, fields);
    }

    /// 便捷方法：结构化 WARN 日志
    pub fn logStructuredWarn(self: *RotatingFileLogger, comptime event: []const u8, fields: anytype) !void {
        try self.logStructured(.warn, event, fields);
    }

    /// 便捷方法：结构化 ERROR 日志
    pub fn logStructuredErr(self: *RotatingFileLogger, comptime event: []const u8, fields: anytype) !void {
        try self.logStructured(.err, event, fields);
    }

    /// 格式化本地时间 ISO-8601 时间戳（如 2026-08-07T12:34:56+08:00）
    fn formatTimestamp(self: *RotatingFileLogger, buf: *[25]u8) []const u8 {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(self.currentEpochSeconds()) };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();

        const offset_minutes = @divTrunc(self.utc_offset_seconds, 60);
        const off_hours = @divTrunc(offset_minutes, 60);
        const off_mins = @rem(@abs(offset_minutes), 60);

        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            if (offset_minutes < 0) @as(u8, '-') else @as(u8, '+'),
            @abs(off_hours),
            off_mins,
        }) catch unreachable;
    }

    // =================================================================
    // 异步后台线程
    // =================================================================

    /// 把一条已格式化的日志交给后台写盘任务；`msg` 的所有权转移给本函数
    /// （入队成功由队列释放，否则就地释放）。
    ///
    /// 全程持锁：环形队列只对单生产者安全，而 log() 会被每个连接任务并发调用；
    /// 懒启动同样必须在锁内，否则并发首调会启动多个写盘任务。
    /// 锁内只有几次内存写入，真正的文件 I/O 仍在后台任务里，请求路径不会被拖慢。
    fn enqueueAsync(self: *RotatingFileLogger, level: Level, msg: []u8) void {
        self.mutex.lock(self.io) catch {
            self.allocator.free(msg);
            return;
        };
        defer self.mutex.unlock(self.io);

        if (self.async_future == null) {
            // 必须用 concurrent 而不是 async：asyncWriterThread 是个无限循环，
            // 而 io.async 在无法真正并发时**允许就地同步执行**——那会把
            // 第一个打日志的调用者永久卡死在写盘循环里。
            self.async_future = self.io.concurrent(asyncWriterThread, .{self}) catch null;
        }

        // 拿不到并发能力（单线程 io / 线程耗尽）→ 就地同步写盘。
        // 宁可这条日志慢一点，也好过静默丢弃或者死锁。
        if (self.async_future == null) {
            defer self.allocator.free(msg);
            self.checkRotation() catch {};
            self.writeFormatted("{s}", .{msg}) catch {};
            self.flushBuffer() catch {};
            return;
        }

        const q = if (self.async_queue) |*q| q else {
            self.allocator.free(msg);
            return;
        };
        // 队列满 → 丢弃这条日志，保证永远不阻塞请求路径
        if (!q.push(level, msg)) self.allocator.free(msg);
    }

    /// 后台写盘任务：只负责排空队列并写入。
    /// 文件与缓冲区由 init/deinit 持有，这里不做打开/关闭/分配/释放，
    /// 避免与 deinit 争夺同一份资源。
    fn asyncWriterThread(self: *RotatingFileLogger) std.Io.Cancelable!void {
        while (!self.stopping.load(.acquire)) {
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
                // 队列空，短暂休眠避免忙等。cancel 会让这次 sleep 提前返回，
                // 循环随即通过 stopping 标志退出。
                std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(@intCast(1 * std.time.ns_per_ms)), .awake) catch {};
            }
        }
    }

    // =================================================================
    // 内部 — 轮转（同步和异步共用）
    // =================================================================

    /// 当前 epoch 秒数，已加上 UTC 偏移（日志时间戳与每日轮转统一按本地时间）。
    fn currentEpochSeconds(self: *const RotatingFileLogger) i64 {
        const now = std.Io.Timestamp.now(self.io, .real);
        return now.toSeconds() + self.utc_offset_seconds;
    }

    /// 当前本地日期 + 当日秒数。日志格式化直接用它，不依赖轮转缓存，
    /// 否则异步模式下首条日志会打出 0000-00-00。
    fn currentDateTime(self: *const RotatingFileLogger) struct { date: Date, day_secs: std.time.epoch.DaySeconds } {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(self.currentEpochSeconds()) };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{
            .date = .{ .year = year_day.year, .month = month_day.month.numeric(), .day = @as(u8, month_day.day_index) + 1 },
            .day_secs = epoch.getDaySeconds(),
        };
    }

    fn getCurrentDate(self: *const RotatingFileLogger) Date {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(self.currentEpochSeconds()) };
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
        // dirname 在 Windows 上同时识别 '/' 和 '\'，直接用 sep 单字符查找会漏掉 "./log/x.log"。
        const dir_path = std.fs.path.dirname(path) orelse return;
        if (dir_path.len == 0) return;
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }
};

// =========================================================================
// 辅助函数
// =========================================================================

/// 将任意值格式化为 JSON 值（用于结构化日志）
fn formatJsonValue(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.print("\"{s}\"", .{value});
            } else if (ptr.size == .one) {
                // 单个指针，递归解引用
                try formatJsonValue(writer, value.*);
            } else {
                try writer.writeAll("null");
            }
        },
        .optional => {
            if (value) |v| {
                try formatJsonValue(writer, v);
            } else {
                try writer.writeAll("null");
            }
        },
        else => try writer.print("\"{any}\"", .{value}),
    }
}

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

    pub fn process(self: *FileLogMiddleware, ctx: *RequestContext, res: *Response) anyerror!NextAction {
        _ = res;
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

test "formatJsonValue - string" {
    const allocator = std.testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "{s}", .{"\"hello\""});
    defer allocator.free(result);
    // Verify formatJsonValue works without crash (full test via logStructured)
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "formatJsonValue - integer" {
    const allocator = std.testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "{d}", .{@as(u32, 42)});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "formatJsonValue - bool" {
    const allocator = std.testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "{s}", .{"true"});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("true", result);
}

test "formatTimestamp produces ISO-8601 UTC" {
    var logger = RotatingFileLogger{
        .base_path = "test",
        .max_file_size = 1024,
        .max_backup_files = 1,
        .compress_rotated = false,
        .rotate_daily = false,
        .min_level = .debug,
        .buf_size = 0,
        .async_enabled = false,
        .current_file = null,
        .current_size = 0,
        .current_year = 2026,
        .current_month = 8,
        .current_day = 7,
        .write_buf = null,
        .write_buf_end = 0,
        .utc_offset_seconds = 0,
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mutex = undefined,
        .async_queue = null,
    };

    var buf: [25]u8 = undefined;
    const ts = logger.formatTimestamp(&buf);

    // ISO-8601 带偏移格式：YYYY-MM-DDTHH:MM:SS+00:00，长度 25
    try std.testing.expectEqual(@as(usize, 25), ts.len);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
    try std.testing.expectEqual(@as(u8, ':'), ts[13]);
    try std.testing.expectEqual(@as(u8, '+'), ts[19]);
    // 不再是旧的占位时间戳
    try std.testing.expect(!std.mem.startsWith(u8, ts, "1970"));
}

test "formatTimestamp applies UTC offset" {
    var logger = RotatingFileLogger{
        .base_path = "test",
        .max_file_size = 1024,
        .max_backup_files = 1,
        .compress_rotated = false,
        .rotate_daily = false,
        .min_level = .debug,
        .buf_size = 0,
        .async_enabled = false,
        .current_file = null,
        .current_size = 0,
        .current_year = 2026,
        .current_month = 8,
        .current_day = 7,
        .write_buf = null,
        .write_buf_end = 0,
        .utc_offset_seconds = 8 * 3600,
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .mutex = undefined,
        .async_queue = null,
    };

    var buf: [25]u8 = undefined;
    const ts = logger.formatTimestamp(&buf);

    // 东八区偏移：末尾为 +08:00
    try std.testing.expectEqual(@as(usize, 25), ts.len);
    try std.testing.expectEqualStrings("+08:00", ts[19..25]);
}

/// 给测试用的临时文件名生成唯一后缀（纳秒时间戳 + 线程 id）。
fn uniqueSuffix(io: std.Io) u64 {
    const ns: u96 = @bitCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    return @as(u64, @truncate(ns)) ^ (@as(u64, std.Thread.getCurrentId()) << 32);
}

test "RotatingFileLogger - sync mode writes to disk" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // 文件名带随机后缀：多个测试二进制会被 build runner 并行执行，
    // 固定名字会让它们互相删掉对方的日志文件。
    var name_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "zig-test-sync-logger-{x}.log", .{uniqueSuffix(io)});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var logger = try RotatingFileLogger.init(allocator, io, path, .{
        .async_enabled = false,
        .min_level = .debug,
        .buf_size = 0,
    });
    try logger.info("sync {d}", .{7});
    logger.deinit();

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "sync 7") != null);
}

test "RotatingFileLogger - async mode actually starts writer and flushes on deinit" {
    // 回归测试：async_future 曾被初始化成非 null 的哑值，导致写盘任务永远
    // 不启动、日志被静默丢弃；后台任务又曾用 io.async（可能就地同步执行的
    // 无限循环）+ 吞掉取消信号，导致 deinit 死锁。
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var name_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "zig-test-async-logger-{x}.log", .{uniqueSuffix(io)});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var logger = try RotatingFileLogger.init(allocator, io, path, .{
        .async_enabled = true,
        .min_level = .debug,
        .buf_size = 0,
    });
    for (0..50) |i| try logger.info("async {d}", .{i});
    // deinit 会取消写盘任务并把队列里剩下的补写完，无需在这里等待
    logger.deinit();

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(content);

    // 首尾都要在，证明既没有丢头也没有丢尾
    try std.testing.expect(std.mem.indexOf(u8, content, "async 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "async 49") != null);
}
