//! 速率限制中间件 — 迁移到新架构
//!
//! 滑动窗口算法，支持按 IP 或自定义头识别客户端。
//!
//! 修复 bug.md Part 2 P0/P1：
//! - P0：线程不安全 — records map 无锁访问 → 加 std.Io.Mutex
//! - P1：时间类型 i128/i96 不一致 → 统一用 i96（Timestamp.nanoseconds 类型）

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

const Context = http_app.Context;
const Response = http_protocol.Response;
const Next = http_app.Next;

pub const RateLimitConfig = struct {
    window_seconds: u32 = 60,
    max_requests: u32 = 100,
    per_ip: bool = true,
    identifier_header: ?[]const u8 = null,
    limit_message: []const u8 = "Rate limit exceeded",
    /// 是否信任 X-Forwarded-For / X-Real-IP 头。
    /// false 时不读代理头——防止客户端伪造头绕过限流（fix.md §二.7）。
    /// true 时按顺序读 X-Real-IP → X-Forwarded-For（第一个 IP）。
    trust_proxy: bool = false,
};

pub const RateLimiter = struct {
    config: RateLimitConfig,
    allocator: std.mem.Allocator,
    io: std.Io,
    records: std.StringHashMapUnmanaged(Record) = .empty,
    mutex: std.Io.Mutex = .init,
    /// 上次清理过期记录的时间（纳秒）。用于周期性驱逐，防止 map 无限增长（修复 B1）。
    last_cleanup: i96 = 0,

    const Self = @This();

    const Record = struct {
        count: u32,
        window_start: i96, // 修复 P1：统一用 i96
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: RateLimitConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.records.deinit(self.allocator);
    }

    /// 中间件入口：检查速率限制
    /// - 超限 → 写 429 响应，short-circuit
    /// - 未超限 → 更新记录，调 next
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        const identifier = self.getIdentifier(ctx) orelse {
            try next.call(ctx, res);
            return;
        };

        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;

        // 加锁检查 + 更新（修复 P0 线程不安全）
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isRateLimitedLocked(identifier, now)) {
            _ = res.statusCode(.too_many_requests);
            try self.addRateLimitHeadersLocked(res, identifier, now);
            _ = try res.header("Retry-After", "1");
            try res.text(self.config.limit_message);
            return; // short-circuit
        }

        try self.updateRecordLocked(identifier, now);
        self.maybeCleanupLocked(now);
        try self.addRateLimitHeadersLocked(res, identifier, now);
        try next.call(ctx, res);
    }

    /// 周期性驱逐窗口已过期的记录，防止 records map 无限增长（修复 B1）。
    /// 攻击者轮换 X-Forwarded-For 可制造无限 key —— 无驱逐会导致内存耗尽。
    /// 清理间隔取窗口长度（至少 1 秒），在锁内调用。
    fn maybeCleanupLocked(self: *Self, now: i96) void {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;
        const interval_ns = @max(window_ns, 1_000_000_000);
        if (now - self.last_cleanup < interval_ns) return;
        self.last_cleanup = now;

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.records.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.window_start >= window_ns) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.records.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    fn getIdentifier(self: *const Self, ctx: *Context) ?[]const u8 {
        if (self.config.identifier_header) |header_name| {
            return ctx.request.getHeader(header_name);
        }
        if (self.config.per_ip) {
            // 不信任代理头时，不读 X-Forwarded-For / X-Real-IP——
            // 否则客户端可以伪造头绕过限流（fix.md §二.7）。
            // 对端 IP 只在连接层可用，中间件拿不到，所以跳过 IP 限流。
            if (!self.config.trust_proxy) {
                std.log.debug("rate limiter: per_ip=true but trust_proxy=false, skipping", .{});
                return null;
            }
            // 信任代理头：X-Real-IP 优先于 X-Forwarded-For
            if (ctx.request.getHeader("X-Real-IP")) |ip| return ip;
            if (ctx.request.getHeader("X-Forwarded-For")) |xff| {
                const comma = std.mem.indexOfScalar(u8, xff, ',') orelse xff.len;
                return std.mem.trim(u8, xff[0..comma], " \t");
            }
            return null;
        }
        return "global";
    }

    fn isRateLimitedLocked(self: *Self, identifier: []const u8, now: i96) bool {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;
        if (self.records.get(identifier)) |record| {
            if (now - record.window_start < window_ns) {
                return record.count >= self.config.max_requests;
            }
        }
        return false;
    }

    fn updateRecordLocked(self: *Self, identifier: []const u8, now: i96) !void {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;

        if (self.records.getPtr(identifier)) |record| {
            if (now - record.window_start >= window_ns) {
                record.* = .{ .count = 1, .window_start = now };
            } else {
                record.count += 1;
            }
        } else {
            const key_dup = try self.allocator.dupe(u8, identifier);
            try self.records.put(self.allocator, key_dup, .{
                .count = 1,
                .window_start = now,
            });
        }
    }

    fn addRateLimitHeadersLocked(self: *Self, res: *Response, identifier: []const u8, now: i96) !void {
        const record = self.records.get(identifier) orelse return;
        const limit = self.config.max_requests;
        const remaining = if (limit > record.count) limit - record.count else 0;
        const reset_time = now + @as(i96, self.config.window_seconds) * 1_000_000_000;

        // 用 arena 分配头值字符串
        const limit_str = try std.fmt.allocPrint(res.allocator, "{d}", .{limit});
        _ = try res.header("X-RateLimit-Limit", limit_str);
        const remain_str = try std.fmt.allocPrint(res.allocator, "{d}", .{remaining});
        _ = try res.header("X-RateLimit-Remaining", remain_str);
        const reset_str = try std.fmt.allocPrint(res.allocator, "{d}", .{reset_time});
        _ = try res.header("X-RateLimit-Reset", reset_str);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "RateLimiter within limit not rate-limited" {
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .window_seconds = 60,
        .max_requests = 5,
        .per_ip = false,
    });
    defer rl.deinit();

    // 模拟 3 次请求
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try rl.updateRecordLocked("global", std.Io.Timestamp.now(std.testing.io, .real).nanoseconds);
    }

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    try std.testing.expect(!rl.isRateLimitedLocked("global", now));
}

test "RateLimiter exceeding limit is rate-limited" {
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .window_seconds = 60,
        .max_requests = 3,
        .per_ip = false,
    });
    defer rl.deinit();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try rl.updateRecordLocked("global", std.Io.Timestamp.now(std.testing.io, .real).nanoseconds);
    }

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    try std.testing.expect(rl.isRateLimitedLocked("global", now));
}

test "RateLimiter window expiry resets limit" {
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .window_seconds = 1,
        .max_requests = 2,
        .per_ip = false,
    });
    defer rl.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    try rl.updateRecordLocked("global", now);
    try rl.updateRecordLocked("global", now);
    try std.testing.expect(rl.isRateLimitedLocked("global", now));

    // 窗口过期后（模拟 2 秒后的时间戳）
    const future_ns = now + @as(i96, 2) * 1_000_000_000;
    try std.testing.expect(!rl.isRateLimitedLocked("global", future_ns));
}

test "RateLimiter multiple identifiers are independent" {
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .window_seconds = 60,
        .max_requests = 2,
        .per_ip = false,
    });
    defer rl.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    try rl.updateRecordLocked("client_a", now);
    try rl.updateRecordLocked("client_a", now);
    try std.testing.expect(rl.isRateLimitedLocked("client_a", now));

    // client_b 不受影响
    try std.testing.expect(!rl.isRateLimitedLocked("client_b", now));
}

test {
    std.testing.refAllDecls(@This());
}

// ── trust_proxy 闸门测试（fix.md §二.7）────────────────────────

/// 构建带指定 head_bytes 的 Request，用于 getIdentifier 测试。
fn makeRateReq(head_bytes: []const u8) http_protocol.Request {
    return .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
}

/// 构建最小 Context，用于 RateLimiter.getIdentifier 测试。
/// state / config 分配在 arena 上，生命周期随 arena。
fn makeRateCtx(arena: std.mem.Allocator, req: *http_protocol.Request) Context {
    const state_ptr = arena.create(http_app.RequestState) catch unreachable;
    state_ptr.* = .{};
    const cfg_ptr = arena.create(http_app.RequestConfig) catch unreachable;
    cfg_ptr.* = .{};
    return .{
        .request = req,
        .state = state_ptr,
        .config = cfg_ptr,
        .arena = arena,
        .io = std.testing.io,
    };
}

test "trust_proxy=true: X-Real-IP 优先于 X-Forwarded-For" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Real-IP: 10.0.0.1\r\nX-Forwarded-For: 192.168.0.1, 10.0.0.2\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = true });
    defer rl.deinit();
    const id = rl.getIdentifier(&ctx);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("10.0.0.1", id.?);
}

test "trust_proxy=true: X-Forwarded-For 取第一个 IP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1, 10.0.0.2\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = true });
    defer rl.deinit();
    const id = rl.getIdentifier(&ctx);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("192.168.0.1", id.?);
}

test "trust_proxy=false: 不读代理头，返回 null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1\r\nX-Real-IP: 10.0.0.1\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = false });
    defer rl.deinit();
    // 不信任代理头 → 返回 null → process 里跳过限流
    try std.testing.expect(rl.getIdentifier(&ctx) == null);
}

test "per_ip=false: 返回 global 标识" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = false, .trust_proxy = false });
    defer rl.deinit();
    const id = rl.getIdentifier(&ctx);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("global", id.?);
}
