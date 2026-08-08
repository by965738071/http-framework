//! 日志接口（核心侧）
//!
//! 核心只定义"往哪写一行日志"这件事，不关心轮转、压缩、异步队列、文件格式——
//! 那些是 `observability` 的职责。这样 core 不必知道任何具体日志实现，
//! 用户也可以把日志接到 syslog / stderr / 测试缓冲区上。
//!
//! ```zig
//! var file_logger = try FileLogger.init(allocator, io, "logs/app.log", .{});
//! defer file_logger.deinit();
//! server.setLogger(file_logger.logger());
//! ```

const std = @import("std");

pub const Level = enum(u3) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBUG",
        };
    }

    /// 当 `self` 的严重程度不低于 `min` 时返回 true。
    pub fn atLeast(self: Level, min: Level) bool {
        return @backingInt(self) <= @backingInt(min);
    }
};

/// 单条日志的最大长度。超出部分被截断——日志绝不应该因为一条超长消息而
/// 分配内存或失败，这条路径上任何错误都比丢一行日志更糟。
pub const max_line_len = 4096;

/// 日志接收端接口。
pub const Logger = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 写入一行已格式化的日志（不含换行符）。
        /// 实现必须自行处理并发调用，且不得返回错误——日志失败不能影响请求处理。
        write: *const fn (ptr: *anyopaque, level: Level, msg: []const u8) void,
    };

    /// 由具体实现构造。`T` 需提供 `fn write(*T, Level, []const u8) void`。
    pub fn init(comptime T: type, impl: *T) Logger {
        const gen = struct {
            fn write(ptr: *anyopaque, level: Level, msg: []const u8) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                T.write(self, level, msg);
            }
        };
        return .{
            .ptr = impl,
            .vtable = &.{ .write = gen.write },
        };
    }

    /// 格式化并写入一行日志。
    ///
    /// 使用栈缓冲区，不分配堆内存；超长内容被截断而不是报错。
    pub fn print(self: Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        var buf: [max_line_len]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // 截断：保留前缀，尾部标注被截断
            const ellipsis = "...[truncated]";
            @memcpy(buf[buf.len - ellipsis.len ..], ellipsis);
            break :blk buf[0..];
        };
        self.vtable.write(self.ptr, level, msg);
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.print(.debug, fmt, args);
    }
    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.print(.info, fmt, args);
    }
    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.print(.warn, fmt, args);
    }
    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.print(.err, fmt, args);
    }
};

/// 把日志转发到 `std.log` 的内置实现。默认即用，无需任何依赖。
pub const StdLogger = struct {
    min_level: Level = .info,

    pub fn write(self: *StdLogger, level: Level, msg: []const u8) void {
        if (!level.atLeast(self.min_level)) return;
        switch (level) {
            .err => std.log.err("{s}", .{msg}),
            .warn => std.log.warn("{s}", .{msg}),
            .info => std.log.info("{s}", .{msg}),
            .debug => std.log.debug("{s}", .{msg}),
        }
    }

    pub fn logger(self: *StdLogger) Logger {
        return Logger.init(StdLogger, self);
    }
};

// =========================================================================
// 测试
// =========================================================================

/// 收集日志到内存的测试替身。
const CaptureLogger = struct {
    lines: std.ArrayList([]u8) = .empty,
    allocator: std.mem.Allocator,

    fn write(self: *CaptureLogger, level: Level, msg: []const u8) void {
        _ = level;
        const dup = self.allocator.dupe(u8, msg) catch return;
        self.lines.append(self.allocator, dup) catch self.allocator.free(dup);
    }

    fn deinit(self: *CaptureLogger) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
};

test "Logger dispatches through vtable to implementation" {
    const allocator = std.testing.allocator;
    var cap = CaptureLogger{ .allocator = allocator };
    defer cap.deinit();

    const log = Logger.init(CaptureLogger, &cap);
    log.info("hello {s} {d}", .{ "world", 42 });
    log.err("boom", .{});

    try std.testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try std.testing.expectEqualStrings("hello world 42", cap.lines.items[0]);
    try std.testing.expectEqualStrings("boom", cap.lines.items[1]);
}

test "Logger.print truncates instead of failing on oversized messages" {
    const allocator = std.testing.allocator;
    var cap = CaptureLogger{ .allocator = allocator };
    defer cap.deinit();

    const huge = comptime blk: {
        var b: [max_line_len * 2]u8 = undefined;
        @memset(&b, 'x');
        break :blk b;
    };
    Logger.init(CaptureLogger, &cap).info("{s}", .{&huge});

    // 没有 panic、没有丢失：得到一条被截断的日志
    try std.testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try std.testing.expectEqual(max_line_len, cap.lines.items[0].len);
    try std.testing.expect(std.mem.endsWith(u8, cap.lines.items[0], "[truncated]"));
}

test "Level.atLeast filters by severity" {
    try std.testing.expect(Level.err.atLeast(.info));
    try std.testing.expect(Level.info.atLeast(.info));
    try std.testing.expect(!Level.debug.atLeast(.info));
    try std.testing.expect(Level.debug.atLeast(.debug));
}
