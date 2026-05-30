//! 速率限制中间件（Rate Limiting）
//! 支持基于 IP 或 API Key 的请求频率限制。
//! 使用滑动窗口算法，支持 X-RateLimit-* 响应头。

const std = @import("std");
const mem = std.mem;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");

/// 速率限制配置
pub const RateLimitConfig = struct {
    /// 时间窗口（秒）
    window_seconds: u32 = 60,

    /// 最大请求数（在时间窗口内）
    max_requests: u32 = 100,

    /// 是否按 IP 限制（true）或按全局限制（false）
    per_ip: bool = true,

    /// 用于识别客户端的请求头（如 "X-API-Key"），为空则使用 IP
    identifier_header: ?[]const u8 = null,

    /// 超出限制时的响应信息
    limit_message: []const u8 = "Rate limit exceeded",
};

/// 速率限制器（滑动窗口算法）
pub const RateLimiter = struct {
    config: RateLimitConfig,
    middleware: Middleware,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 存储客户端请求记录：key -> {count, window_start}
    records: std.StringHashMapUnmanaged(Record) = .empty,

    const Self = @This();

    /// 请求记录
    const Record = struct {
        count: u32,
        window_start: i128, // 时间戳（纳秒）
    };

    /// 创建速率限制器
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: RateLimitConfig) !*Self {
        const ptr = try allocator.create(Self);
        ptr.* = .{
            .config = config,
            .middleware = undefined,
            .allocator = allocator,
            .io = io,
        };
        ptr.middleware = Middleware.init(Self, ptr);
        return ptr;
    }

    /// 处理请求 - 检查速率限制
    pub fn process(self: *Self, ctx: *RequestContext) !Middleware.NextAction {
        // 获取客户端标识符
        const identifier = self.getIdentifier(ctx) orelse {
            // 无法识别客户端，放行
            return .err;
        };

        // 获取当前时间（纳秒）
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds; // time.nanoTimestamp();

        // 检查速率限制
        if (self.isRateLimited(identifier, now)) {
            ctx.blocked_status = .too_many_requests;
            return .respond;
        }

        // 更新记录
        try self.updateRecord(identifier, now);

        // 注意：响应头需要在路由处理器中通过 addRateLimitHeaders 设置
        // 因为中间件 process 无法直接访问 Response 对象

        return .next;
    }

    /// 销毁速率限制器
    pub fn deinit(self: *Self) void {
        // 释放所有记录
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.records.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 获取客户端标识符
    fn getIdentifier(self: *const Self, ctx: *RequestContext) ?[]const u8 {
        // 如果配置了自定义头，使用该头的值
        if (self.config.identifier_header) |header_name| {
            return ctx.getHeader(header_name);
        }

        // 否则使用 IP（如果配置了 per_ip）
        if (self.config.per_ip) {
            return ctx.getClientIp();
        }

        // 全局限制，使用固定 key
        return "global";
    }

    /// 检查是否超出速率限制
    fn isRateLimited(self: *Self, identifier: []const u8, now: i96) bool {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;

        if (self.records.get(identifier)) |record| {
            // 检查是否在当前窗口内
            if (now - record.window_start < window_ns) {
                return record.count >= self.config.max_requests;
            }
        }

        return false;
    }

    /// 更新请求记录
    fn updateRecord(self: *Self, identifier: []const u8, now: i96) !void {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;

        if (self.records.getPtr(identifier)) |record| {
            // check if window needs reset
            if (now - record.window_start >= window_ns) {
                record.* = .{
                    .count = 1,
                    .window_start = now,
                };
            } else {
                record.count += 1;
            }
        } else {
            // 新记录
            const key_dup = try self.allocator.dupe(u8, identifier);
            defer self.allocator.free(key_dup);
            try self.records.put(self.allocator, key_dup, .{
                .count = 1,
                .window_start = now,
            });
        }
    }

    /// 添加 X-RateLimit-* 响应头（需要在路由处理器中手动调用）
    pub fn addRateLimitHeaders(self: *const Self, res: *Response, identifier: []const u8, now: i96) !void {
        // 获取记录
        if (self.records.get(identifier)) |record| {
            const limit = self.config.max_requests;
            const remaining = @as(u32, @intCast(if (limit > record.count) limit - record.count else 0));
            const reset_time = now + @as(i96, self.config.window_seconds) * 1_000_000_000;

            // 通过 Response API 设置响应头
            var limit_buf: [32]u8 = undefined;
            var remain_buf: [32]u8 = undefined;
            var reset_buf: [32]u8 = undefined;

            _ = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
            _ = try std.fmt.bufPrint(&remain_buf, "{d}", .{remaining});
            _ = try std.fmt.bufPrint(&reset_buf, "{d}", .{reset_time});

            _ = try res.header("X-RateLimit-Limit", &limit_buf);
            _ = try res.header("X-RateLimit-Remaining", &remain_buf);
            _ = try res.header("X-RateLimit-Reset", &reset_buf);
        }
    }
};

// =========================================================================
// 测试
// =========================================================================

test "RateLimiter.init creates instance with given config" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 30,
        .max_requests = 50,
        .per_ip = false,
    };

    const rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    try std.testing.expectEqual(@as(u32, 30), rl.config.window_seconds);
    try std.testing.expectEqual(@as(u32, 50), rl.config.max_requests);
    try std.testing.expectEqual(false, rl.config.per_ip);
    try std.testing.expectEqual(@as(u64, 0), rl.records.count());
}

test "RateLimiter sliding window: within limit not rate-limited" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 10,
    };

    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // Directly insert a record: 5 requests at window_start=0
    const key = try allocator.dupe(u8, "client-a");
    try rl.records.put(allocator, key, .{ .count = 5, .window_start = 0 });

    // At 30s (within 60s window), 5 < 10 max → not limited
    try std.testing.expect(!rl.isRateLimited("client-a", 30_000_000_000));
}

test "RateLimiter sliding window: exceeding limit is rate-limited" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 10,
    };

    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // Record with count at exactly the limit, within the window
    const key = try allocator.dupe(u8, "client-b");
    try rl.records.put(allocator, key, .{ .count = 10, .window_start = 0 });

    // At 10s (within 60s window), 10 >= 10 → rate-limited (triggers .respond in process)
    try std.testing.expect(rl.isRateLimited("client-b", 10_000_000_000));
}

test "RateLimiter sliding window: window expiry resets limit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 5,
    };

    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // Record at window_start=0 with count=5 (at limit)
    const key = try allocator.dupe(u8, "client-c");
    try rl.records.put(allocator, key, .{ .count = 5, .window_start = 0 });

    // At 10s (within 60s window) → rate-limited
    try std.testing.expect(rl.isRateLimited("client-c", 10_000_000_000));

    // At 60s (exactly window boundary, now - window_start = 60s, NOT < 60s) → not limited
    // Actually: now - window_start >= window_ns → returns false (window expired)
    try std.testing.expect(!rl.isRateLimited("client-c", 60_000_000_000));

    // At 61s (past window) → definitely not limited
    try std.testing.expect(!rl.isRateLimited("client-c", 61_000_000_000));
}

test "RateLimiter: unknown identifier not rate-limited" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 1,
    };

    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // No record exists for "unknown-client" → not rate-limited
    try std.testing.expect(!rl.isRateLimited("unknown-client", 0));
}

test "RateLimiter: over-limit returns respond-equivalent" {
    // When isRateLimited returns true, process() would return .respond
    // and set ctx.blocked_status = .too_many_requests.
    // This test verifies the core logic that triggers .respond.

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = RateLimitConfig{
        .window_seconds = 1,
        .max_requests = 3,
    };

    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const key = try allocator.dupe(u8, "over-limit-client");
    try rl.records.put(allocator, key, .{ .count = 4, .window_start = 0 });

    // 4 > 3 max, still within 1s window → rate-limited → would trigger .respond
    try std.testing.expect(rl.isRateLimited("over-limit-client", 500_000_000));
}
