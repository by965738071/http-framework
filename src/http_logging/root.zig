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
            .float => |n| try writer.print("{d}", .{n}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }

    fn writeText(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |s| try writer.writeAll(s),
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
    }

    /// 主日志方法。ctx 可为 null（启动/关闭阶段无请求上下文）。
    pub fn log(self: *Logger, level: Level, ctx: ?*const Context, msg: []const u8, fields: []const Field) void {
        if (!level.enabled(self.config.min_level)) return;

        var buf: [MAX_LOG_LINE]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));

        switch (self.config.format) {
            .json => formatJson(&writer, ts, level, ctx, msg, fields) catch return,
            .text => formatText(&writer, ts, level, ctx, msg, fields) catch return,
        }

        const written = writer.buffered();
        if (written.len == 0) return;

        switch (self.config.output) {
            .stderr, .stdout => {
                const out_file = if (self.config.output == .stderr)
                    std.Io.File.stderr()
                else
                    std.Io.File.stdout();
                out_file.writeStreamingAll(self.io, written) catch {};
            },
            .file => {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                // 每次写入前以 stat 实时校准偏移：若文件被外部进程截断/改写，
                // 直接追加到真实 EOF，避免陈旧偏移 pwrite 在文件中间留下
                // NUL 空洞（Mac 会因此把日志判为二进制）。
                // 用路径 stat（而非已打开的写句柄）：Windows 上写句柄缺
                // FILE_READ_ATTRIBUTES，直连句柄 stat 会返回 AccessDenied。
                if (self.owned_path) |p| {
                    if (std.Io.Dir.cwd().statFile(self.io, p, .{})) |st| {
                        self.file_offset = st.size;
                    } else |_| {}
                }
                self.file.writePositionalAll(self.io, written, self.file_offset) catch return;
                self.file_offset += written.len;
                self.rotateIfNeeded();
            },
        }
    }

    /// 当前文件超过 max_size 时触发轮转。
    fn rotateIfNeeded(self: *Logger) void {
        const fc = self.config.file orelse return;
        if (self.file_offset < fc.max_size) return;
        self.rotate();
    }

    /// 轮转：path -> path.1 -> gzip -> path.1.gz，旧备份编号下移，删除最老备份。
    /// best-effort：任一步失败都退回重开新文件（或 stderr），不阻塞日志写入。
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

        // 1. 删除最老备份 path.{max}.gz
        const oldest = std.fmt.allocPrint(allocator, "{s}.{d}.gz", .{ path, max }) catch {
            self.reopen();
            return;
        };
        defer allocator.free(oldest);
        cwd.deleteFile(self.io, oldest) catch {};

        // 2. 反向 shift：path.{i-1}.gz -> path.{i}.gz
        var i: u8 = max;
        while (i > 1) : (i -= 1) {
            const from = std.fmt.allocPrint(allocator, "{s}.{d}.gz", .{ path, i - 1 }) catch break;
            const to = std.fmt.allocPrint(allocator, "{s}.{d}.gz", .{ path, i }) catch {
                allocator.free(from);
                break;
            };
            cwd.rename(from, cwd, to, self.io) catch {};
            allocator.free(from);
            allocator.free(to);
        }

        // 3. 当前文件改名 path -> path.1
        const rotated = std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, 1 }) catch {
            self.reopen();
            return;
        };
        defer allocator.free(rotated);
        cwd.rename(path, cwd, rotated, self.io) catch {
            self.reopen();
            return;
        };

        // 4. gzip 压缩归档（成功后删除未压缩的 path.1）
        if (fc.compress) self.compressToGzip(rotated);

        // 5. 重开新文件
        self.reopen();
    }

    /// 将已轮转的归档文件 gzip 压缩为 {src}.gz，并删除未压缩的原文件。
    fn compressToGzip(self: *Logger, src: []const u8) void {
        const fc = self.config.file orelse return;
        const allocator = self.allocator;
        const cwd = std.Io.Dir.cwd();

        const content = cwd.readFileAlloc(
            self.io,
            src,
            allocator,
            .limited(fc.max_size + MAX_LOG_LINE),
        ) catch return;
        defer allocator.free(content);

        const gz_path = std.fmt.allocPrint(allocator, "{s}.gz", .{src}) catch return;
        defer allocator.free(gz_path);

        const gz_file = cwd.createFile(self.io, gz_path, .{ .truncate = true }) catch return;
        defer gz_file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = gz_file.writer(self.io, write_buf[0..]);
        var hist_buf: [flate.max_window_len]u8 = undefined;
        var encoder = flate.Compress.init(&file_writer.interface, &hist_buf, .gzip, .default) catch return;
        encoder.writer.writeAll(content) catch return;
        encoder.finish() catch return;
        file_writer.flush() catch return;

        cwd.deleteFile(self.io, src) catch {};
    }

    /// 轮转后重开新的日志文件；失败则退回 stderr。
    fn reopen(self: *Logger) void {
        self.openLogFile() catch {
            self.config.output = .stderr;
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
    try writer.print("{d} {s} {s}", .{ ts, level.name(), msg });

    if (ctx) |c| {
        if (c.state.getUserData(RequestId)) |rid| {
            try writer.print(" rid={s}", .{rid.slice()});
        }
        try writer.print(" method={s} path={s}", .{ @tagName(c.request.method), c.request.path });
    }

    for (fields) |f| {
        try writer.writeAll(" ");
        try writer.writeAll(f.key);
        try writer.writeAll("=");
        try f.value.writeText(writer);
    }

    try writer.writeAll("\n");
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

        const start = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds;
        next.call(ctx, res) catch |e| {
            const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;
            self.logger.err(ctx, "request_error", &.{
                fstr("error", @errorName(e)),
                fint("duration_ns", @intCast(elapsed)),
                fint("status", @backingInt(res.status)),
            });
            return e;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .awake).nanoseconds - start;

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
                const method_str = if (data.method) |m| @tagName(m) else "?";
                const path_str = if (data.path) |p| p else "?";
                self.logger.info(ctx, "request_start", &.{
                    fstr("method", method_str),
                    fstr("path", path_str),
                });
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

test "Logger.log respects min_level" {
    // 用一个假 fd 测试——log 在 level 不足时应直接返回不写
    var logger = try Logger.init(std.testing.allocator, std.testing.io, .{
        .min_level = .warn,
        .format = .json,
        .output = .stderr,
    });
    // debug < warn，应被过滤
    logger.debug(null, "should not appear", &.{});
    // err >= warn，应通过（写入 fd 2，不影响测试）
    logger.err(null, "should appear", &.{});
}

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
