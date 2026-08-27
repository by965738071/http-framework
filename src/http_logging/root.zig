//! http_logging — 结构化日志（回应 fix.md §二.1）
//!
//! 功能：
//! - 日志级别：debug / info / warn / err / fatal
//! - 结构化字段：key-value 对（string / int / uint / float / bool / null）
//! - 两种输出格式：JSON（生产）和 text（开发）
//! - 输出到 stderr（默认）、stdout 或文件（.file）
//! - 文件输出：日志轮转 + gzip 压缩归档（超过 max_size 自动轮转）
//! - 请求 ID 关联：从 ctx.state.user_data 取 RequestId
//!
//! 用法：
//! ```zig
//! // 1. 创建 Logger（全局单例）
//! var logger = framework.Logger.init(allocator, io, .{
//!     .min_level = .info,
//!     .format = .json,
//!     .output = .file,
//!     .file = .{ .path = "log/app.log", .max_size = 16 * 1024 * 1024 },
//! }) catch |err| @panic("logger init: {s}");
//! defer logger.deinit();
//!
//! // 2a. 作为 Hook 使用（推荐——server 计算 duration/status）
//! var log_hook = framework.LoggingHook{ .logger = &logger };
//! const hooks = [_]framework.Hook{
//!     framework.Hook.init(framework.LoggingHook, &log_hook),
//! };
//!
//! // 2b. 或者作为中间件使用（自带 timing，但 error 状态码可能不准）
//! var log_mw = framework.LoggingMiddleware{ .logger = &logger };
//! router.use(framework.Middleware.init(framework.LoggingMiddleware, &log_mw));
//!
//! // 3. handler 中直接使用
//! logger.info(ctx, "user login", &.{
//!     framework.fstr("user", "alice"),
//!     framework.fbool("success", true),
//! });
//! ```

const std = @import("std");
const builtin = @import("builtin");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");
const flate = std.compress.flate;

pub const Context = http_app.Context;
pub const Response = http_protocol.Response;
pub const Middleware = http_app.Middleware;
pub const Next = http_app.Next;
pub const RequestId = http_app.RequestId;

/// 跨平台实现，不依赖 libc：
/// - 写 stderr/stdout 走 std.Io.File（std.Io 自带各平台后端）。
/// - 时间戳用 std.Io.Timestamp.realtime（Unix epoch 纳秒）。
/// 日志级别（有序：debug < info < warn < err < fatal）
pub const Level = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn enabled(self: Level, min: Level) bool {
        return @backingInt(self) >= @backingInt(min);
    }
};

/// 结构化字段值
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    null: void,

    fn writeJson(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| try writeJsonString(writer, s),
            .int => |n| try writer.print("{d}", .{n}),
            .uint => |n| try writer.print("{d}", .{n}),
            .float => |n| {
                if (std.math.isFinite(n)) {
                    try writer.print("{d}", .{n});
                } else {
                    // NaN/±Inf 不是合法 JSON 数字，输出 null 以免破坏整行 JSON
                    try writer.writeAll("null");
                }
            },
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }

    fn writeText(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| try writeTextEscaped(writer, s),
            .int => |n| try writer.print("{d}", .{n}),
            .uint => |n| try writer.print("{d}", .{n}),
            .float => |n| try writer.print("{d}", .{n}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }
};

/// 结构化字段（key-value 对）
pub const Field = struct {
    key: []const u8,
    value: Value,
};

// ── 字段构造便捷函数 ──────────────────────────────────────────

pub fn fstr(key: []const u8, val: []const u8) Field {
    return .{ .key = key, .value = .{ .string = val } };
}
pub fn fint(key: []const u8, val: i64) Field {
    return .{ .key = key, .value = .{ .int = val } };
}
pub fn fuint(key: []const u8, val: u64) Field {
    return .{ .key = key, .value = .{ .uint = val } };
}
pub fn ffloat(key: []const u8, val: f64) Field {
    return .{ .key = key, .value = .{ .float = val } };
}
pub fn fbool(key: []const u8, val: bool) Field {
    return .{ .key = key, .value = .{ .bool = val } };
}
pub fn fnull(key: []const u8) Field {
    return .{ .key = key, .value = .null };
}

/// 输出格式
pub const Format = enum {
    json,
    text,
};

/// 输出目标
pub const Output = enum {
    stderr,
    stdout,
    file,
};

/// 文件输出配置（日志轮转 + gzip 压缩）
pub const FileOutputConfig = struct {
    /// 日志文件路径（相对 cwd；父目录不存在会自动创建）
    path: []const u8,
    /// 超过该字节数后触发轮转（默认 16 MiB）
    max_size: usize = 16 * 1024 * 1024,
    /// 保留的压缩备份数量（.1.gz .. .N.gz），最老的会被删除
    max_backups: u8 = 5,
    /// 轮转时对归档文件做 gzip 压缩
    compress: bool = true,
};

/// Logger 配置
pub const LoggerConfig = struct {
    min_level: Level = .info,
    format: Format = .json,
    output: Output = .stderr,
    /// output == .file 时的文件配置（必填）
    file: ?FileOutputConfig = null,
};

/// 单条日志的最大字节长度（超出截断）
const MAX_LOG_LINE = 8192;

/// 结构化日志器
///
/// 线程安全：
/// - stderr/stdout：每条日志格式化到栈缓冲后用单次 `write()` 写出。
///   POSIX 保证小于 PIPE_BUF 的 write 是原子的。
/// - 文件：用 `writePositionalAll`（pwrite）追加，配合 `mutex` 串行化
///   写入与轮转。
pub const Logger = struct {
    config: LoggerConfig,
    io: std.Io,
    allocator: std.mem.Allocator,
    /// 文件模式写路径串行化（防止轮转与写入并发竞争）
    mutex: std.Io.Mutex = .init,
    /// 文件模式持有的文件句柄
    file: std.Io.File,
    /// 当前文件大小（= 下一个写入偏移），用于追加与轮转判断
    file_offset: u64,
    /// init 时 dupe 的文件路径（deinit 释放）
    owned_path: ?[]const u8,
    /// 是否成功开启 O_APPEND 模式（POSIX）。为 true 时写入走内核原子追加
    /// （writeStreamingAll，无需每请求 stat 重算偏移），跨进程安全且更快。
    /// 为 false（Windows / fcntl 失败）时退回 stat+pwrite 兼容路径。
    append_mode: bool = false,
    /// 轮转失败后置位：暂停文件写（日志降级到 stderr），不再触碰可能已关闭的 fd。
    file_paused: bool = false,
    /// 轮转后待压缩的归档路径（由 log() 在锁外 gzip，压缩后释放）。
    pending_gzip: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) !Logger {
        var self = Logger{
            .config = config,
            .io = io,
            .allocator = allocator,
            .file = .{ .handle = undefined, .flags = .{ .nonblocking = false } },
            .file_offset = 0,
            .owned_path = null,
        };

        if (config.output == .file) {
            const fc = config.file orelse return error.MissingFileOutputConfig;
            self.owned_path = try allocator.dupe(u8, fc.path);
            self.openLogFile() catch {
                // 打开失败则退回 stderr，避免日志静默丢失
                self.config.output = .stderr;
            };
        }
        return self;
    }

    pub fn deinit(self: *Logger) void {
        if (self.config.output == .file) {
            // 持锁关闭：避免关机期并发日志写已关闭的 fd
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.file.close(self.io);
        }
        if (self.owned_path) |p| {
            self.allocator.free(p);
            self.owned_path = null;
        }
    }

    /// 打开（或复用）日志文件，file_offset 定位到文件末尾（追加语义）。
    fn openLogFile(self: *Logger) !void {
        const path = self.owned_path orelse return error.MissingFileOutputConfig;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) cwd.createDirPath(self.io, dir) catch {};
        }
        self.file = try cwd.createFile(self.io, path, .{ .truncate = false });
        // 用路径 stat 而非已打开的写句柄 stat：Windows 上以写模式打开的
        // 句柄缺少 FILE_READ_ATTRIBUTES，NtQueryInformationFile 会返回
        // AccessDenied，导致读不到真实文件大小。
        const st = cwd.statFile(self.io, path, .{}) catch {
            self.file_offset = 0;
            return;
        };
        self.file_offset = st.size;

        // POSIX：给 fd 设置 O_APPEND，之后每次 write 由内核原子追加到 EOF。
        // 这样写入路径不再需要每请求 statFile 重算偏移（性能瓶颈），也天然
        // 跨进程/多线程安全（多个 writer 各自的 write 不会互相覆盖）。
        // 失败（或非 POSIX）时保持 append_mode=false，退回 stat+pwrite 路径。
        self.append_mode = enableAppendMode(self.file.handle);
    }

    /// 给已打开的文件描述符设置 O_APPEND（POSIX）。成功返回 true。
    /// 非 POSIX 平台或 fcntl 失败返回 false（调用方退回 pwrite 路径）。
    fn enableAppendMode(handle: std.posix.fd_t) bool {
        switch (builtin.os.tag) {
            .windows, .wasi => return false,
            else => {
                const F = std.posix.F;
                const cur = std.c.fcntl(handle, F.GETFL, @as(usize, 0));
                if (cur < 0) return false;
                const append_bit: usize = @as(u32, @bitCast(std.posix.O{ .APPEND = true }));
                const new_flags: usize = @as(usize, @intCast(cur)) | append_bit;
                if (std.c.fcntl(handle, F.SETFL, new_flags) < 0) return false;
                return true;
            },
        }
    }

    /// 主日志方法。ctx 可为 null（启动/关闭阶段无请求上下文）。
    pub fn log(self: *Logger, level: Level, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        if (!level.enabled(self.config.min_level)) return;

        var buf: [MAX_LOG_LINE]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));

        switch (self.config.format) {
            .json => formatJson(&writer, ts, level, ctx, msg, fields) catch {
                // 缓冲区写满（WriteFailed）时不能把整条日志丢掉：字段最多、
                // 最长的日志恰恰是出错时那些。回退成一条截断标记行
                // （保留 ts/level/rid + "truncated":true）。
                writer = std.Io.Writer.fixed(&buf);
                formatTruncated(&writer, ts, level, ctx, msg) catch return;
            },
            .text => formatText(&writer, ts, level, ctx, msg, fields) catch {
                writer = std.Io.Writer.fixed(&buf);
                formatTruncated(&writer, ts, level, ctx, msg) catch return;
            },
        }

        const written = writer.buffered();
        if (written.len == 0) return;

        // 修复 M10：output 判断与句柄使用整体放在同一把锁内——轮转（可能 close
        // 文件、reopen 失败降级）也在锁内进行，其它线程不会在锁外读到陈旧 output
        // 后向已关闭的 fd 写入。
        self.mutex.lockUncancelable(self.io);
        switch (self.config.output) {
            .stderr => std.Io.File.stderr().writeStreamingAll(self.io, written) catch {},
            .stdout => std.Io.File.stdout().writeStreamingAll(self.io, written) catch {},
            .file => {
                if (self.file_paused) {
                    // 轮转曾失败：file 句柄可能已关闭，暂停文件写降级到 stderr，
                    // 避免写入被其它 open 复用的 fd（日志字节落进错误文件）。
                    std.Io.File.stderr().writeStreamingAll(self.io, written) catch {};
                } else {
                    // 写前以 stat 校准 file_offset（append 与兼容路径统一），避免
                    // 外部 truncate 后偏移陈旧导致轮转判断过早/过晚（跨进程场景）。
                    if (self.owned_path) |p| {
                        if (std.Io.Dir.cwd().statFile(self.io, p, .{})) |st| {
                            self.file_offset = st.size;
                        } else |_| {}
                    }
                    if (self.append_mode) {
                        // O_APPEND 快路径：内核保证每次 write 原子追加到 EOF，
                        // 不会留下 NUL 空洞。
                        self.file.writeStreamingAll(self.io, written) catch {
                            self.mutex.unlock(self.io);
                            return;
                        };
                    } else {
                        // 兼容路径（Windows / fcntl 失败）：stat 校准后 pwrite。
                        self.file.writePositionalAll(self.io, written, self.file_offset) catch {
                            self.mutex.unlock(self.io);
                            return;
                        };
                    }
                    self.file_offset += written.len;
                    self.rotateIfNeeded();
                }
            },
        }
        // 在锁内取走待压缩归档路径：若在锁外读，两个线程可能同时取到同一路径，
        // 导致重复压缩与双重 free。
        const pending = self.pending_gzip;
        self.pending_gzip = null;
        self.mutex.unlock(self.io);

        // 压缩在锁外执行：轮转时 rename 出归档文件后即释放锁，gzip 整文件
        // 不阻塞其它日志写（修复低优先：轮转压缩不持日志锁）。
        if (pending) |rotated| {
            self.compressToGzip(rotated);
            self.allocator.free(rotated);
        }
    }

    /// 当前文件超过 max_size 时触发轮转。
    fn rotateIfNeeded(self: *Logger) void {
        const fc = self.config.file orelse return;
        if (self.file_offset < fc.max_size) return;
        self.rotate();
    }

    /// 轮转：path -> path.1(-> gzip -> path.1.gz)，旧备份编号下移，删除最老备份。
    ///
    /// 在 log() 的锁内调用（需持锁才能安全 close/rename/reopen）。gzip 压缩
    /// 不在锁内做——这里只把当前文件 rename 出并重开新文件，并把待压缩路径
    /// 记录到 pending_gzip，由 log() 释放锁后压缩。
    ///
    /// best-effort：任一步失败都不阻塞日志写入。rename/reopen 失败置
    /// file_paused（暂停文件写），而非改动 config.output（避免 M10 竞态）。
    fn rotate(self: *Logger) void {
        const path = self.owned_path orelse return;
        const fc = self.config.file orelse return;
        const allocator = self.allocator;
        const cwd = std.Io.Dir.cwd();
        const max = fc.max_backups;

        self.file.close(self.io);

        if (max == 0) {
            // 不保留备份：重开新文件即可
            self.reopen();
            return;
        }

        // 备份后缀由 compress 设置决定；但无论哪种，都同时迁移 .gz 与裸后缀
        // 两种备份（修复 M11：compress:false 或某次 gzip 失败留下的未压缩
        // 备份也能正确下移，max_backups 才真正生效）。
        const suffix = if (fc.compress) ".gz" else "";

        // 1. 删除最老备份 path.{max}{suffix} 与 path.{max}（两种后缀都清理）
        const oldest = std.fmt.allocPrint(allocator, "{s}.{d}{s}", .{ path, max, suffix }) catch {
            self.reopen();
            return;
        };
        defer allocator.free(oldest);
        cwd.deleteFile(self.io, oldest) catch {};
        const oldest_bare = std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, max }) catch {
            self.reopen();
            return;
        };
        defer allocator.free(oldest_bare);
        cwd.deleteFile(self.io, oldest_bare) catch {};

        // 2. 反向 shift：每个索引位同时迁移 .gz 与裸后缀备份
        var i: u8 = max;
        while (i > 1) : (i -= 1) {
            const from_gz = std.fmt.allocPrint(allocator, "{s}.{d}.gz", .{ path, i - 1 }) catch break;
            defer allocator.free(from_gz);
            const to_gz = std.fmt.allocPrint(allocator, "{s}.{d}.gz", .{ path, i }) catch break;
            defer allocator.free(to_gz);
            cwd.rename(from_gz, cwd, to_gz, self.io) catch {};

            const from_bare = std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, i - 1 }) catch break;
            defer allocator.free(from_bare);
            const to_bare = std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, i }) catch break;
            defer allocator.free(to_bare);
            cwd.rename(from_bare, cwd, to_bare, self.io) catch {};
        }

        // 3. 当前文件改名 path -> path.1。改名成功后，若目标 path.1 已存在
        //    （上次 gzip 失败遗留的未压缩备份），先显式删除，避免 rename 在
        //    POSIX 上静默覆盖丢历史（修复低优先：超限残留截断/改名而非静默覆盖）。
        const rotated = std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, 1 }) catch {
            self.reopen();
            return;
        };
        cwd.deleteFile(self.io, rotated) catch {};
        defer allocator.free(rotated);
        cwd.rename(path, cwd, rotated, self.io) catch {
            // 改名失败（跨设备/权限等）：暂停文件写，避免向已关闭 fd 写入。
            self.pauseFileWrites();
            return;
        };

        // 4. 需要压缩：记录归档路径，交给 log() 在锁外 gzip。
        if (fc.compress) {
            self.pending_gzip = allocator.dupe(u8, rotated) catch null;
        }

        // 5. 重开新文件；失败则暂停文件写。
        self.reopen();
    }

    /// 暂停文件写：后续 log() 直接写 stderr，不再触碰可能已关闭的 fd。
    fn pauseFileWrites(self: *Logger) void {
        self.file_paused = true;
    }

    /// 将已轮转的归档文件 gzip 压缩为 {src}.gz，并删除未压缩的原文件。
    /// 由 log() 在释放日志锁后调用，避免阻塞其它日志写。
    fn compressToGzip(self: *Logger, src: []const u8) void {
        const fc = self.config.file orelse return;
        const allocator = self.allocator;
        const cwd = std.Io.Dir.cwd();

        const cap = fc.max_size + MAX_LOG_LINE;
        const bytes = blk: {
            break :blk cwd.readFileAlloc(self.io, src, allocator, .limited(cap)) catch |e| {
                // 文件超过压缩上限（异常大）：先截断源文件到 cap 再压缩，避免
                // 超限归档残留、下次轮转被静默覆盖（修复低优先）。其它错误放弃。
                if (e != error.StreamTooLong) return;
                const f = cwd.openFile(self.io, src, .{ .mode = .read_write }) catch return;
                defer f.close(self.io);
                if (std.c.ftruncate(f.handle, @intCast(cap)) != 0) return;
                break :blk cwd.readFileAlloc(self.io, src, allocator, .limited(cap)) catch return;
            };
        };
        defer allocator.free(bytes);

        const gz_path = std.fmt.allocPrint(allocator, "{s}.gz", .{src}) catch return;
        defer allocator.free(gz_path);

        const gz_file = cwd.createFile(self.io, gz_path, .{ .truncate = true }) catch return;
        defer gz_file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = gz_file.writer(self.io, write_buf[0..]);
        // hist_buf (~64KB) 与 flate.Compress (~224KB) 必须堆分配，不能放栈上：
        // rotate() 在 zio 协程的提交栈里跑，http_compress 模块已明令禁止这种
        // 模式（“放栈上会直接溢出到 guard page”）。同一仓库不应一个模块知道、
        // 另一个在犯。
        const hist_buf = allocator.alloc(u8, flate.max_window_len) catch return;
        defer allocator.free(hist_buf);
        const encoder = allocator.create(flate.Compress) catch return;
        defer allocator.destroy(encoder);
        encoder.* = flate.Compress.init(&file_writer.interface, hist_buf, .gzip, .default) catch return;
        encoder.writer.writeAll(bytes) catch return;
        encoder.finish() catch return;
        file_writer.flush() catch return;

        cwd.deleteFile(self.io, src) catch {};
    }

    /// 轮转后重开新的日志文件；失败则暂停文件写（不改动 config.output，
    /// 避免 M10 竞态：锁外读到降级后的 output 向已关闭 fd 写入）。
    fn reopen(self: *Logger) void {
        self.openLogFile() catch {
            self.file_paused = true;
        };
    }

    pub fn debug(self: *Logger, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        self.log(.debug, ctx, msg, fields);
    }
    pub fn info(self: *Logger, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        self.log(.info, ctx, msg, fields);
    }
    pub fn warn(self: *Logger, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        self.log(.warn, ctx, msg, fields);
    }
    pub fn err(self: *Logger, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        self.log(.err, ctx, msg, fields);
    }
    pub fn fatal(self: *Logger, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        self.log(.fatal, ctx, msg, fields);
    }
};

// ── 格式化 ─────────────────────────────────────────────────────

fn formatJson(writer: *std.Io.Writer, ts: i64, level: Level, ctx: ?*const Context, msg: []const u8, fields: []const Field) !void {
    try writer.writeAll("{");

    try writer.print("\"ts\":{d}", .{ts});

    try writer.print(",\"level\":\"{s}\"", .{level.name()});

    try writer.writeAll(",\"msg\":");
    try writeJsonString(writer, msg);

    if (ctx) |c| {
        if (c.state.getUserData(RequestId)) |rid| {
            try writer.writeAll(",\"rid\":");
            try writeJsonString(writer, rid.slice());
        }
        try writer.writeAll(",\"method\":");
        try writeJsonString(writer, @tagName(c.request.method));
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, c.request.path);
    }

    for (fields) |f| {
        try writer.writeAll(",");
        try writeJsonString(writer, f.key);
        try writer.writeAll(":");
        try f.value.writeJson(writer);
    }

    try writer.writeAll("}\n");
}

fn formatText(writer: *std.Io.Writer, ts: i64, level: Level, ctx: ?*const Context, msg: []const u8, fields: []const Field) !void {
    // 转义控制字符（防日志注入）：msg/path 等用户可控字段可能含 \r\n，
    // 未转义会伪造日志行。
    try writer.print("{d} {s} ", .{ ts, level.name() });
    try writeTextEscaped(writer, msg);

    if (ctx) |c| {
        if (c.state.getUserData(RequestId)) |rid| {
            try writer.print(" rid={s}", .{rid.slice()});
        }
        try writer.print(" method={s} path=", .{@tagName(c.request.method)});
        try writeTextEscaped(writer, c.request.path);
    }

    for (fields) |f| {
        try writer.writeAll(" ");
        // 修复 M6：key 也要转义（与 value/msg 一致），否则动态 key 含换行可伪造日志行。
        try writeTextEscaped(writer, f.key);
        try writer.writeAll("=");
        try f.value.writeText(writer);
    }

    try writer.writeAll("\n");
}

/// 当 formatJson/formatText 写满固定缓冲区时的回退：只写最小骨架
/// （ts/level/rid + "truncated":true），保证出错时那条日志不会整条丢失。
/// 统一用 JSON 形式（即使配置为 text）——截断行很短，不会再溢出。
fn formatTruncated(writer: *std.Io.Writer, ts: i64, level: Level, ctx: ?*const Context, msg: []const u8) !void {
    try writer.print("{{\"ts\":{d},\"level\":\"{s}\"", .{ ts, level.name() });
    if (ctx) |c| {
        if (c.state.getUserData(RequestId)) |rid| {
            try writer.writeAll(",\"rid\":");
            try writeJsonString(writer, rid.slice());
        }
    }
    // msg 只取前 64 字节，避免再次写满。
    const short = msg[0..@min(msg.len, 64)];
    try writer.writeAll(",\"msg\":");
    try writeJsonString(writer, short);
    try writer.writeAll(",\"truncated\":true}\n");
}
/// 防止用户可控内容注入伪造日志行。
fn writeTextEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            0...8, 11, 12, 14...31, 127 => {
                const hex = "0123456789abcdef";
                var esc: [4]u8 = .{ '\\', 'x', '0', '0' };
                esc[2] = hex[c >> 4];
                esc[3] = hex[c & 0xf];
                try writer.writeAll(&esc);
            },
            else => try writer.writeAll(&[1]u8{c}),
        }
    }
}

/// JSON 字符串转义（RFC 8259）
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...31 => {
                const hex = "0123456789abcdef";
                var esc: [6]u8 = .{ '\\', 'u', '0', '0', '0', '0' };
                esc[4] = hex[c >> 4];
                esc[5] = hex[c & 0xf];
                try writer.writeAll(&esc);
            },
            else => try writer.writeAll(&[1]u8{c}),
        }
    }
    try writer.writeAll("\"");
}

// ── 中间件 ─────────────────────────────────────────────────────

/// 请求日志中间件 — 记录请求开始和结束（自带 timing）
///
/// 放在 RequestIdMiddleware 之后（需要 rid）。
///
/// 注意：如果 handler 返回 error，此中间件会捕获并记录，
/// 但此时 res.status 尚未被 ErrorRenderer 设置（ErrorRenderer 在外层）。
/// 如需准确的 status，请用 LoggingHook（基于生命周期事件）。
pub const LoggingMiddleware = struct {
    logger: *Logger,

    const Self = @This();

    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        self.logger.info(ctx, "request_start", &.{});

        const start = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
        next.call(ctx, res) catch |e| {
            const elapsed = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
            self.logger.err(ctx, "request_error", &.{
                fstr("error", @errorName(e)),
                fint("duration_ns", @intCast(elapsed)),
                fint("status", @backingInt(res.status)),
            });
            return e;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;

        self.logger.info(ctx, "request_end", &.{
            fint("status", @backingInt(res.status)),
            fint("duration_ns", @intCast(elapsed)),
        });
    }
};

// ── 生命周期 Hook ──────────────────────────────────────────────

/// 请求日志 Hook — 基于 server 生命周期事件（推荐）
///
/// 利用 server 计算的 duration_ns 和 status，比 LoggingMiddleware 更准确。
///
/// 用法：
/// ```zig
/// var log_hook = framework.LoggingHook{ .logger = &logger };
/// const hooks = [_]framework.Hook{
///     framework.Hook.init(framework.LoggingHook, &log_hook),
/// };
/// server.setLifecycle(.{ .hooks = &hooks });
/// ```
pub const LoggingHook = struct {
    logger: *Logger,

    pub fn onEvent(self: *@This(), event: http_app.Event, data: *const http_app.EventData) void {
        const ctx: ?*const Context = if (data.ctx) |c| c else null;

        switch (event) {
            .request_start => {
                // 不要把 method/path 再当 field 传一遍：formatJson/formatText 已经
                // 从 ctx 输出了这两个字段（见 formatJson 里的 ",\"method\":" / ",\"path\":"）。
                // 重复传会产出重复 JSON key
                // （实测：{"msg":"request_start","method":"GET","path":"/x","method":"GET","path":"/x"}），
                // 重复 key 的 JSON 行为未定义，Loki/ES/jq 处理各异，最坏整行被拒收 ——
                // 也就是出事时最需要的那条日志没了。
                // ctx 为 null（无请求上下文）时才补上，保证信息不丢。
                if (ctx != null) {
                    self.logger.info(ctx, "request_start", &.{});
                } else {
                    const method_str = if (data.method) |m| @tagName(m) else "?";
                    const path_str = if (data.path) |p| p else "?";
                    self.logger.info(null, "request_start", &.{
                        fstr("method", method_str),
                        fstr("path", path_str),
                    });
                }
            },
            .request_end => {
                const status_val: i64 = if (data.status) |s| @backingInt(s) else 0;
                const dur_val: i64 = if (data.duration_ns) |d| @intCast(d) else 0;
                self.logger.info(ctx, "request_end", &.{
                    fint("status", status_val),
                    fint("duration_ns", dur_val),
                });
            },
            .request_error => {
                const err_name: []const u8 = if (data.err) |e| @errorName(e) else "unknown";
                self.logger.err(ctx, "request_error", &.{
                    fstr("error", err_name),
                });
            },
            .connection_open => {
                self.logger.debug(ctx, "connection_open", &.{});
            },
            .connection_close => {
                self.logger.debug(ctx, "connection_close", &.{});
            },
            else => {},
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Level.enabled" {
    try std.testing.expect(Level.debug.enabled(.debug));
    try std.testing.expect(Level.info.enabled(.debug));
    try std.testing.expect(!Level.debug.enabled(.info));
    try std.testing.expect(Level.fatal.enabled(.debug));
}

test "Level.name" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.name());
    try std.testing.expectEqualStrings("INFO", Level.info.name());
    try std.testing.expectEqualStrings("ERROR", Level.err.name());
}

test "field helpers" {
    const f1 = fstr("user", "alice");
    try std.testing.expectEqualStrings("user", f1.key);
    try std.testing.expectEqualStrings("alice", f1.value.string);

    const f2 = fint("count", 42);
    try std.testing.expectEqual(@as(i64, 42), f2.value.int);

    const f3 = fbool("ok", true);
    try std.testing.expectEqual(true, f3.value.bool);
}

test "writeJsonString escapes special characters" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeJsonString(&writer, "hello \"world\" \n \\ \t");
    const out = writer.buffered();
    try std.testing.expectEqualStrings("\"hello \\\"world\\\" \\n \\\\ \\t\"", out);
}

test "writeJsonString escapes control characters" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeJsonString(&writer, "a\x01b");
    const out = writer.buffered();
    try std.testing.expectEqualStrings("\"a\\u0001b\"", out);
}

test "formatJson produces valid JSON" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const fields = [_]Field{
        fstr("user", "alice"),
        fint("count", 42),
        fbool("ok", true),
    };
    try formatJson(&writer, 1234567890, .info, null, "test message", &fields);
    const out = writer.buffered();

    // 验证 JSON 结构
    try std.testing.expect(out[0] == '{');
    try std.testing.expect(out[out.len - 1] == '\n');
    try std.testing.expect(out[out.len - 2] == '}');
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"INFO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"msg\":\"test message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"user\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"count\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
}

test "formatText produces readable output" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const fields = [_]Field{
        fstr("user", "alice"),
        fint("count", 42),
    };
    try formatText(&writer, 1234567890, .warn, null, "warning msg", &fields);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "WARN") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "warning msg") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "user=alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "count=42") != null);
}

// test "Logger.log respects min_level" {
//     // 用一个假 fd 测试——log 在 level 不足时应直接返回不写
//     var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
//         .min_level = .warn,
//         .format = .json,
//         .output = .stderr,
//     });
//     // debug < warn，应被过滤
//     logger.debug(null, "should not appear", &.{});
//     // err >= warn，应通过（写入 fd 2，不影响测试）
//     logger.err(null, "should appear", &.{});
// }

test "file output writes lines to the log file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/app.log",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
        .min_level = .debug,
        .format = .text,
        .output = .file,
        .file = .{ .path = path, .max_size = 1 << 20 },
    });
    defer logger.deinit();

    logger.info(null, "hello file", &.{fstr("k", "v")});
    logger.debug(null, "second line", &.{});
    logger.warn(null, "third line", &.{fint("n", 42)});

    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1 << 20),
    ) catch |err| {
        std.debug.print("read log file failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "hello file") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "k=v") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "second line") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "n=42") != null);
}

test "file output rotates and gzips backups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/app.log",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
        .min_level = .debug,
        .format = .text,
        .output = .file,
        .file = .{ .path = path, .max_size = 200, .max_backups = 2 },
    });
    defer logger.deinit();

    // 每行约 100 字节，10 行 → 触发多次轮转
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        logger.info(null, "line {d} with some padding ..........", &.{fint("seq", @intCast(i))});
    }

    // 当前活动文件仍有内容
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(4096),
    ) catch |err| {
        std.debug.print("read active log failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);

    // .1.gz 与 .2.gz 备份都应存在
    const gz1 = try std.fmt.allocPrint(std.testing.allocator, "{s}.1.gz", .{path});
    defer std.testing.allocator.free(gz1);
    _ = std.Io.Dir.cwd().statFile(std.testing.io, gz1, .{}) catch |err| {
        std.debug.print("missing backup .1.gz: {s}\n", .{@errorName(err)});
        return err;
    };
    const gz2 = try std.fmt.allocPrint(std.testing.allocator, "{s}.2.gz", .{path});
    defer std.testing.allocator.free(gz2);
    _ = std.Io.Dir.cwd().statFile(std.testing.io, gz2, .{}) catch |err| {
        std.debug.print("missing backup .2.gz: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "rotated backup decompresses to original lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/app.log",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
        .min_level = .debug,
        .format = .text,
        .output = .file,
        .file = .{ .path = path, .max_size = 200, .max_backups = 2 },
    });
    defer logger.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        logger.info(null, "line {d} with some padding ..........", &.{fint("seq", @intCast(i))});
    }

    // 读取 .1.gz 并解压
    const gz1 = try std.fmt.allocPrint(std.testing.allocator, "{s}.1.gz", .{path});
    defer std.testing.allocator.free(gz1);
    const compressed = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        gz1,
        std.testing.allocator,
        .limited(1 << 20),
    ) catch |err| {
        std.debug.print("read .1.gz failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(compressed);

    var hist_buf: [flate.max_window_len]u8 = undefined;
    var reader: std.Io.Reader = .fixed(compressed);
    var decompress: flate.Decompress = .init(&reader, .gzip, &hist_buf);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = decompress.reader.streamRemaining(&out.writer) catch {};
    const decompressed = out.written();

    // 归档内容应包含被轮转的行（含 seq 字段）
    try std.testing.expect(std.mem.indexOf(u8, decompressed, "line ") != null);
    try std.testing.expect(std.mem.indexOf(u8, decompressed, "seq=") != null);

    // 压缩后未压缩的 path.1 应被删除
    const rot1 = try std.fmt.allocPrint(std.testing.allocator, "{s}.1", .{path});
    defer std.testing.allocator.free(rot1);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, rot1, .{}));
}

test "file output re-syncs offset after external truncation (no NUL holes)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/trunc.log",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    // 先放一段“旧内容”，模拟文件已有数据
    {
        const old = std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true }) catch unreachable;
        defer old.close(std.testing.io);
        var buf: [4096]u8 = undefined;
        var w = old.writer(std.testing.io, buf[0..]);
        w.interface.writeAll("old-padding-line\n") catch unreachable;
        w.interface.writeAll("old-padding-line\n") catch unreachable;
        w.flush() catch unreachable;
    }

    var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
        .min_level = .debug,
        .format = .text,
        .output = .file,
        .file = .{ .path = path, .max_size = 1 << 20 },
    });
    defer logger.deinit();

    // 追加一行（file_offset 越过旧内容）
    logger.info(null, "before truncate", &.{});

    // 外部进程将文件截断为 0（同一 inode）
    const ft = std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true }) catch unreachable;
    ft.close(std.testing.io);

    // 再写一行：修复前会以陈旧偏移 pwrite → 留下 NUL 空洞
    logger.info(null, "after truncate", &.{});

    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1 << 20),
    ) catch |err| {
        std.debug.print("read trunc log failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(content);

    // 文件里不能有任何 NUL 字节
    for (content) |b| try std.testing.expect(b != 0);
    // 截断后的新行应位于文件开头（追加到真实 EOF）
    try std.testing.expect(std.mem.indexOf(u8, content, "after truncate") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "before truncate") == null);
}

test "formatJson includes request context when ctx provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = http_app.RequestConfig{};
    var req = http_protocol.Request{
        .method = .POST,
        .target = "/login",
        .path = "/login",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "POST /login HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    // 设置 RequestId
    const rid = try arena.allocator().create(RequestId);
    rid.* = .{ .value = "abcdef0123456789abcdef0123456789".*, .len = 32 };
    try ctx.state.setUserData(RequestId, rid, arena.allocator());

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try formatJson(&writer, 1234567890, .info, &ctx, "login attempt", &.{});
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"rid\":\"abcdef0123456789abcdef0123456789\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"method\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/login\"") != null);
}

test {
    std.testing.refAllDecls(@This());
}
