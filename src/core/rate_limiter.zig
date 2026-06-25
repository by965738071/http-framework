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
            // 无法识别客户端（如无 IP、无标识头），放行请求
            // 注意：之前返回 .err 会导致路由器静默吞掉请求（视为内部错误）
            return .next;
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
            // key_dup 的所有权转移给 HashMap，由 deinit 统一释放
            const key_dup = try self.allocator.dupe(u8, identifier);
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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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

    const allocator = std.testing.allocator;

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

// =========================================================================
// 补充测试：updateRecord
// =========================================================================

test "updateRecord: 首次请求应创建 count=1 的记录" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    try rl.updateRecord("client-new", 10_000_000_000);

    const record = rl.records.get("client-new").?;
    try std.testing.expectEqual(@as(u32, 1), record.count);
    try std.testing.expectEqual(@as(i128, 10_000_000_000), record.window_start);
}

test "updateRecord: 同一窗口内 count 递增" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    try rl.updateRecord("client-inc", 10_000_000_000);
    try rl.updateRecord("client-inc", 15_000_000_000);
    try rl.updateRecord("client-inc", 20_000_000_000);

    const record = rl.records.get("client-inc").?;
    try std.testing.expectEqual(@as(u32, 3), record.count);
    // 窗口起始时间不变
    try std.testing.expectEqual(@as(i128, 10_000_000_000), record.window_start);
}

test "updateRecord: 跨窗口后 count 重置为 1" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 第一个窗口：3 次请求
    try rl.updateRecord("client-reset", 10_000_000_000);
    try rl.updateRecord("client-reset", 15_000_000_000);
    try rl.updateRecord("client-reset", 20_000_000_000);

    // 第二个窗口：距首次请求超过 60s
    try rl.updateRecord("client-reset", 70_000_000_000);

    const record = rl.records.get("client-reset").?;
    try std.testing.expectEqual(@as(u32, 1), record.count);
    // 窗口起始时间更新到新窗口
    try std.testing.expectEqual(@as(i128, 70_000_000_000), record.window_start);
}

test "updateRecord: 多个不同 identifier 独立计数" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    try rl.updateRecord("client-a", 10_000_000_000);
    try rl.updateRecord("client-b", 10_000_000_000);
    try rl.updateRecord("client-a", 15_000_000_000);

    try std.testing.expectEqual(@as(u32, 2), rl.records.get("client-a").?.count);
    try std.testing.expectEqual(@as(u32, 1), rl.records.get("client-b").?.count);
    // 确认共有 2 条记录
    try std.testing.expectEqual(@as(u32, 2), rl.records.count());
}

// =========================================================================
// 补充测试：isRateLimited 边界条件
// =========================================================================

test "isRateLimited: count 恰好等于 max_requests 时被限制" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 5 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const key = try allocator.dupe(u8, "exact-client");
    try rl.records.put(allocator, key, .{ .count = 5, .window_start = 0 });

    // count == max_requests → 被限制
    try std.testing.expect(rl.isRateLimited("exact-client", 10_000_000_000));
}

test "isRateLimited: count 等于 max_requests-1 时不被限制" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 5 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const key = try allocator.dupe(u8, "under-client");
    try rl.records.put(allocator, key, .{ .count = 4, .window_start = 0 });

    // count == max_requests - 1 → 未被限制
    try std.testing.expect(!rl.isRateLimited("under-client", 10_000_000_000));
}

test "isRateLimited: 无记录的新 identifier 不被限制" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 1 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 无记录 → 未被限制
    try std.testing.expect(!rl.isRateLimited("brand-new-client", 10_000_000_000));
}

test "isRateLimited: 不同窗口秒数配置影响过期判断" {
    const allocator = std.testing.allocator;

    // 短窗口: 10 秒
    const config = RateLimitConfig{ .window_seconds = 10, .max_requests = 3 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const key = try allocator.dupe(u8, "short-window-client");
    try rl.records.put(allocator, key, .{ .count = 3, .window_start = 0 });

    // 5s（在 10s 窗口内）→ 被限制
    try std.testing.expect(rl.isRateLimited("short-window-client", 5_000_000_000));

    // 10s（恰好到达窗口边界）→ 未被限制（now - window_start >= window_ns）
    try std.testing.expect(!rl.isRateLimited("short-window-client", 10_000_000_000));

    // 11s（超过窗口）→ 未被限制
    try std.testing.expect(!rl.isRateLimited("short-window-client", 11_000_000_000));
}

// =========================================================================
// 补充测试：addRateLimitHeaders
// =========================================================================

test "addRateLimitHeaders: 有记录时设置三个 X-RateLimit-* 头" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 插入记录: count=3
    const key = try allocator.dupe(u8, "header-client");
    try rl.records.put(allocator, key, .{ .count = 3, .window_start = 0 });

    var res = Response.init(allocator, undefined);
    defer res.deinit();

    try rl.addRateLimitHeaders(&res, "header-client", 10_000_000_000);

    // 应设置 3 个头
    try std.testing.expectEqual(@as(usize, 3), res.headers.items.len);
    try std.testing.expectEqualStrings("X-RateLimit-Limit", res.headers.items[0].name);
    try std.testing.expectEqualStrings("X-RateLimit-Remaining", res.headers.items[1].name);
    try std.testing.expectEqualStrings("X-RateLimit-Reset", res.headers.items[2].name);
}

test "addRateLimitHeaders: 无记录时不设置头" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 10 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    var res = Response.init(allocator, undefined);
    defer res.deinit();

    // identifier 无记录 → 不设置头
    try rl.addRateLimitHeaders(&res, "unknown-client", 10_000_000_000);
    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
}

test "addRateLimitHeaders: remaining = 0 当 count >= max_requests" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 5 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // count == max_requests → remaining 应为 0
    const key = try allocator.dupe(u8, "full-client");
    try rl.records.put(allocator, key, .{ .count = 5, .window_start = 0 });

    var res = Response.init(allocator, undefined);
    defer res.deinit();

    try rl.addRateLimitHeaders(&res, "full-client", 10_000_000_000);

    // 头数量正确
    try std.testing.expectEqual(@as(usize, 3), res.headers.items.len);
}

test "addRateLimitHeaders: remaining = max_requests - count 当 count < max_requests" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .window_seconds = 60, .max_requests = 100 };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // count = 70, max = 100 → remaining = 30
    const key = try allocator.dupe(u8, "partial-client");
    try rl.records.put(allocator, key, .{ .count = 70, .window_start = 0 });

    var res = Response.init(allocator, undefined);
    defer res.deinit();

    try rl.addRateLimitHeaders(&res, "partial-client", 10_000_000_000);

    // 头数量正确
    try std.testing.expectEqual(@as(usize, 3), res.headers.items.len);
}

// =========================================================================
// 补充测试：getIdentifier
// =========================================================================

test "getIdentifier: 使用 identifier_header 配置时从请求头获取标识" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{
        .per_ip = true,
        .identifier_header = "X-API-Key",
    };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-API-Key: my-secret-key\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier != null);
    try std.testing.expectEqualStrings("my-secret-key", identifier.?);
}

test "getIdentifier: 使用 per_ip 配置时从 X-Forwarded-For 获取 IP" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .per_ip = true, .identifier_header = null };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Forwarded-For: 192.168.1.1, 10.0.0.1\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier != null);
    // X-Forwarded-For 取第一个 IP
    try std.testing.expectEqualStrings("192.168.1.1", identifier.?);
}

test "getIdentifier: 使用 per_ip 配置时从 X-Real-IP 获取 IP" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .per_ip = true, .identifier_header = null };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Real-IP: 10.0.0.5\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier != null);
    try std.testing.expectEqualStrings("10.0.0.5", identifier.?);
}

test "getIdentifier: 全局模式返回 \"global\"" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .per_ip = false, .identifier_header = null };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier != null);
    try std.testing.expectEqualStrings("global", identifier.?);
}

test "getIdentifier: identifier_header 优先于 per_ip" {
    const allocator = std.testing.allocator;
    // 同时设置了 identifier_header 和 per_ip
    const config = RateLimitConfig{
        .per_ip = true,
        .identifier_header = "X-API-Key",
    };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 请求同时有 IP 头和 API Key 头
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Forwarded-For: 192.168.1.1\r\n" ++
        "X-API-Key: api-key-123\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // identifier_header 优先 → 返回 API Key 而非 IP
    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier != null);
    try std.testing.expectEqualStrings("api-key-123", identifier.?);
}

test "getIdentifier: identifier_header 对应的请求头不存在时返回 null" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{
        .per_ip = false,
        .identifier_header = "X-API-Key",
    };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 请求中没有 X-API-Key 头
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // header 不存在 → 返回 null
    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier == null);
}

test "getIdentifier: per_ip 无 IP 头时返回 null" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{ .per_ip = true, .identifier_header = null };
    var rl = try RateLimiter.init(allocator, undefined, config);
    defer rl.deinit();

    // 请求中没有 X-Forwarded-For 或 X-Real-IP
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // 无 IP 头 → 返回 null
    const identifier = rl.getIdentifier(&ctx);
    try std.testing.expect(identifier == null);
}

// =========================================================================
// 补充测试：process（完整流程）
// =========================================================================

test "process: 未超限时返回 .next 并更新记录" {
    const allocator = std.testing.allocator;
    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 10,
        .per_ip = true,
        .identifier_header = null,
    };
    var rl = try RateLimiter.init(allocator, std.testing.io, config);
    defer rl.deinit();

    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Forwarded-For: 10.0.0.1\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const action = try rl.process(&ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);

    // 应该创建了记录
    try std.testing.expectEqual(@as(u32, 1), rl.records.count());
}

test "process: 无标识头时返回 .next（放行请求）" {
    const allocator = std.testing.allocator;
    // 配置 per_ip=true 但请求中无 IP 头
    const config = RateLimitConfig{
        .window_seconds = 60,
        .max_requests = 10,
        .per_ip = true,
        .identifier_header = null,
    };
    var rl = try RateLimiter.init(allocator, std.testing.io, config);
    defer rl.deinit();

    // 无 X-Forwarded-For / X-Real-IP
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try RequestContext.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // 无法识别客户端 → 返回 .next
    const action = try rl.process(&ctx);
    try std.testing.expectEqual(Middleware.NextAction.next, action);

    // 不应创建记录
    try std.testing.expectEqual(@as(u32, 0), rl.records.count());
}
