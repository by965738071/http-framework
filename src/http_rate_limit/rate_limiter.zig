//! 速率限制中间件 — 迁移到新架构
//!
//! **注意**：实现是「固定窗口 + 窗口过期重置」，不是滑动窗口——窗口边界处可以打出
//! 2× max_requests 的突发（例如第 59 秒把窗口用满、第 61 秒又满）。若业务需要严格
//! 平滑的速率，请改用加权固定窗口或真滑动窗口（当前 API 不保证平滑上限）。
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
    /// 从自定义头（如网关注入的可信 client id）读取限流标识。
    /// 仅在 trust_proxy=true 时生效——否则客户端可任意伪造该头绕过限流（P2-22）。
    identifier_header: ?[]const u8 = null,
    limit_message: []const u8 = "Rate limit exceeded",
    /// 是否信任 X-Forwarded-For / X-Real-IP 头。
    /// false 时不读代理头——但 per_ip 仍会退化为内核 accept 得到的对端 IP
    /// （H3：默认配置不再静默失效）。
    /// true 时按 X-Real-IP → X-Forwarded-For（从右向左跳过可信代理）取真实客户端。
    trust_proxy: bool = false,
    /// trust_proxy=true 时的可信代理 IP 列表。X-Forwarded-For 从右向左扫描时，
    /// 跳过这些地址，返回第一个不可信地址（真正客户端）。为空列表则取最右值。
    /// 条目是 IP 字面量（如 "203.0.113.10"），精确匹配。
    trusted_proxies: []const []const u8 = &.{},
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

    /// 一次限流判定的结果快照。在锁内填好，锁外用于写响应头 —— 这样
    /// `next.call` 就不必在持锁状态下执行。
    const Snapshot = struct {
        limit: u32,
        remaining: u32,
        reset_unix_sec: i64,
        retry_after_s: u64,
    };

    /// 中间件入口：检查速率限制
    /// - 超限 → 写 429 响应，short-circuit
    /// - 未超限 → 更新记录，调 next
    ///
    /// **临界区绝不能包住 `next.call`**：旧实现是
    /// `lockUncancelable(); defer unlock(); ...; try next.call(ctx, res);`，
    /// 意味着整条下游管道（后续中间件、handler、DB IO、socket 写出）都在这一把
    /// 全局互斥锁里跑 —— 服务器并发度被压成 1，一个慢读客户端就能让全服停摆；
    /// handler 里再进一次限流器（嵌套 dispatch / 重试）会直接自死锁。
    /// 一个为了防 DoS 而存在的中间件，反而制造了一个更好的 DoS。
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        // ip_buf 供 peerIpString 格式化对端 IP；identifier 的生命周期只到本次
        // updateRecordLocked（内部会 dup 成键），栈缓冲足够。
        var ip_buf: [64]u8 = undefined;
        const identifier = self.getIdentifier(ctx, &ip_buf) orelse {
            try next.call(ctx, res);
            return;
        };

        // 单调时钟：墙钟（.real）被 NTP 校正/手工改时间会重置或冻结限流窗口。
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;

        // 临界区：只做「判定 + 计数 + 驱逐 + 取快照」，全部是纯内存操作。
        var snap: Snapshot = undefined;
        var limited: bool = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            limited = self.isRateLimitedLocked(identifier, now);
            if (!limited) try self.updateRecordLocked(identifier, now);
            self.maybeCleanupLocked(now);
            snap = self.snapshotLocked(identifier, now);
        }

        // 锁已释放，下面全部是锁外操作。
        try writeRateLimitHeaders(res, snap);

        if (!limited) {
            try next.call(ctx, res);
            return;
        }

        _ = res.statusCode(.too_many_requests);
        // Retry-After = 距当前窗口重置还剩多少秒（RFC 9110 §10.2.3）。
        const retry_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{snap.retry_after_s});
        _ = try res.header("Retry-After", retry_str);
        try res.text(self.config.limit_message);
    }

    /// 在锁内取一份限流状态快照（调用方必须已持锁）。
    fn snapshotLocked(self: *Self, identifier: []const u8, now: i96) Snapshot {
        const limit = self.config.max_requests;
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;
        // X-RateLimit-Reset 是 Unix 秒时间戳，必须用墙钟（.real）算；判定/计数用
        // 单调钟（.awake）。旧实现拿 .awake 当 Unix 秒，客户端解析出 1970 年附近
        // 的无意义值。
        const real_now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const record = self.records.get(identifier) orelse return .{
            .limit = limit,
            .remaining = limit,
            .reset_unix_sec = @intCast(@divTrunc(real_now + @as(i96, self.config.window_seconds) * 1_000_000_000, 1_000_000_000)),
            .retry_after_s = self.config.window_seconds,
        };
        const remaining_ns = window_ns - (now - record.window_start);
        return .{
            .limit = limit,
            .remaining = if (limit > record.count) limit - record.count else 0,
            .reset_unix_sec = @intCast(@divTrunc(real_now + @max(remaining_ns, 0), 1_000_000_000)),
            .retry_after_s = if (remaining_ns <= 0)
                1
            else
                @intCast(@divTrunc(remaining_ns + 999_999_999, 1_000_000_000)),
        };
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

    /// 解析客户端标识。返回的切片生命期：
    ///   - 头值 → 指向请求 head 字节（updateRecordLocked 会 dup 成键，安全）；
    ///   - peerIpString → 指向 `buf`（调用方栈上，同样只在本次判定内使用，安全）。
    fn getIdentifier(self: *const Self, ctx: *Context, buf: []u8) ?[]const u8 {
        if (self.config.identifier_header) |header_name| {
            // P2-22：identifier_header 模式直接返回客户端可控的头值——
            // 攻击者任意伪造该头即能为每个请求换一个新 identifier，直接绕过限流。
            // 只有在信任上游代理（trust_proxy=true）时才该信这个头；否则跳过，
            // 交给下方 per_ip / global 逻辑处理。
            if (self.config.trust_proxy) {
                if (ctx.request.getHeader(header_name)) |v| {
                    if (v.len > 0) return v;
                }
            } else {
                std.log.debug("rate limiter: identifier_header set but trust_proxy=false, ignoring client-controlled header", .{});
            }
        }
        if (self.config.per_ip) {
            if (self.config.trust_proxy) {
                // 信任代理头的场景：X-Real-IP 由最近一跳可信代理写入。
                if (ctx.request.getHeader("X-Real-IP")) |ip| {
                    if (ip.len > 0) return ip;
                }
                // M8：X-Forwarded-For 是「客户端, 代理1, 代理2, …」链，最左是原始
                // 客户端、最右是最近一跳代理。旧实现取最左值，客户端自报地址即可
                // 每请求生成新键绕过限流——必须从右向左跳过可信代理再取第一个
                // 不可信地址，才是真正的客户端。
                if (ctx.request.getHeader("X-Forwarded-For")) |xff| {
                    if (xff.len > 0) return proxyChainClient(xff, self.config.trusted_proxies);
                }
                // 没有代理头：退回对端 IP。
            }
            // 非信任代理场景（默认 trust_proxy=false）：不读任何代理头（客户端可
            // 伪造），用内核 accept 得到的对端 IP——这是架构上唯一不可伪造的地址
            // （修复 H3：per_ip 默认配置不再静默失效）。
            if (ctx.peerIpString(buf)) |ip| return ip;
            // 无对端地址（Unix socket / 单元测试手工构造的 Context）：返回 null，
            // process 跳过限流（此时无从识别客户端，全局限流会误伤所有连接）。
            return null;
        }
        return "global";
    }

    /// X-Forwarded-For 从右向左扫描：跳过可信代理集合，返回第一个不可信地址。
    /// 全部地址都在可信集合内（或只有代理一跳）时回退到最右值。无逗号时即整体。
    fn proxyChainClient(xff: []const u8, trusted: []const []const u8) []const u8 {
        var fallback: []const u8 = "";
        var end: usize = xff.len;
        while (true) {
            const comma = std.mem.lastIndexOfScalar(u8, xff[0..end], ',');
            const start = if (comma) |c| c + 1 else 0;
            const entry = std.mem.trim(u8, xff[start..end], " \t");
            if (fallback.len == 0) fallback = entry;
            var is_trusted = false;
            for (trusted) |t| {
                if (std.mem.eql(u8, t, entry)) {
                    is_trusted = true;
                    break;
                }
            }
            if (!is_trusted) return entry;
            if (comma == null) break;
            end = comma.?;
        }
        return fallback;
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
            errdefer self.allocator.free(key_dup);
            try self.records.put(self.allocator, key_dup, .{
                .count = 1,
                .window_start = now,
            });
        }
    }

    /// 距当前窗口重置还剩多少秒（向上取整，至少 1）。
    fn secondsUntilResetLocked(self: *Self, identifier: []const u8, now: i96) u64 {
        const window_ns = @as(i96, self.config.window_seconds) * 1_000_000_000;
        if (self.records.get(identifier)) |record| {
            const elapsed = now - record.window_start;
            const remaining_ns = window_ns - elapsed;
            if (remaining_ns <= 0) return 1;
            return @intCast(@divTrunc(remaining_ns + 999_999_999, 1_000_000_000));
        }
        return self.config.window_seconds;
    }
};

/// 写 X-RateLimit-* 响应头。**锁外**调用（入参是锁内取好的快照）。
fn writeRateLimitHeaders(res: *Response, snap: RateLimiter.Snapshot) !void {
    var buf: [24]u8 = undefined;
    _ = try res.header("X-RateLimit-Limit", std.fmt.bufPrint(&buf, "{d}", .{snap.limit}) catch "0");
    var buf2: [24]u8 = undefined;
    _ = try res.header("X-RateLimit-Remaining", std.fmt.bufPrint(&buf2, "{d}", .{snap.remaining}) catch "0");
    var buf3: [24]u8 = undefined;
    _ = try res.header("X-RateLimit-Reset", std.fmt.bufPrint(&buf3, "{d}", .{snap.reset_unix_sec}) catch "0");
}

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
fn makeRateCtx(arena: std.mem.Allocator, req: *http_protocol.Request, peer_ip: ?std.Io.net.IpAddress) Context {
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
        .peer_ip = peer_ip,
    };
}

const v4 = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 203, 0, 113, 195 }, .port = 4321 } };

test "trust_proxy=true: X-Real-IP 优先于 X-Forwarded-For" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Real-IP: 10.0.0.1\r\nX-Forwarded-For: 192.168.0.1, 10.0.0.2\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = true });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("10.0.0.1", id.?);
}

test "M8: X-Forwarded-For 从右向左取（不再取最左易伪造值）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1, 10.0.0.2\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = true });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    // 无可信代理列表：取最右值（最近一跳代理写入的唯一可信地址）
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("10.0.0.2", id.?);
}

test "M8: X-Forwarded-For 跳过可信代理取真正客户端" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1, 203.0.113.10, 10.0.0.2\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .per_ip = true,
        .trust_proxy = true,
        .trusted_proxies = &.{"10.0.0.2"},
    });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    // 从右向左：10.0.0.2 可信跳过，203.0.113.10 不可信 -> 真正的客户端
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("203.0.113.10", id.?);
}

test "proxyChainClient 全部可信时回退最右值" {
    // 模拟客户端、两级代理都在可信集合内（内网最简部署）
    try std.testing.expectEqualStrings("10.0.0.2", RateLimiter.proxyChainClient("10.0.0.1, 10.0.0.2", &.{ "10.0.0.1", "10.0.0.2" }));
}

test "H3: trust_proxy=false 且带内核 peer_ip 时按对端 IP 限流" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1\r\nX-Real-IP: 10.0.0.1\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, v4);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = false });
    defer rl.deinit();
    // 不信任代理头 → 不用 X-Real-IP/Forwarded-For，用内核 accept 的对端 IP（H3 修复）
    var buf: [64]u8 = undefined;
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("203.0.113.195", id.?);
}

test "trust_proxy=false 且无对端地址：返回 null（跳过限流）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1\r\nX-Real-IP: 10.0.0.1\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = true, .trust_proxy = false });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expect(rl.getIdentifier(&ctx, &buf) == null);
}

test "per_ip=false: 返回 global 标识" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Forwarded-For: 192.168.0.1\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{ .per_ip = false, .trust_proxy = false });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("global", id.?);
}

test "P2-22: identifier_header 在 trust_proxy=false 时被忽略（防伪造绕过）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Client-Id: attacker-rotating-value\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    // identifier_header 设了，但 trust_proxy=false → 不信客户端头，回退到 global
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .identifier_header = "X-Client-Id",
        .per_ip = false,
        .trust_proxy = false,
    });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("global", id.?);
}

test "P2-22: identifier_header 在 trust_proxy=true 时生效" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = makeRateReq("GET / HTTP/1.1\r\nX-Client-Id: tenant-42\r\n\r\n");
    var ctx = makeRateCtx(arena.allocator(), &req, null);
    var rl = RateLimiter.init(std.testing.allocator, std.testing.io, .{
        .identifier_header = "X-Client-Id",
        .per_ip = false,
        .trust_proxy = true,
    });
    defer rl.deinit();
    var buf: [64]u8 = undefined;
    const id = rl.getIdentifier(&ctx, &buf);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("tenant-42", id.?);
}
test {
    std.testing.refAllDecls(@This());
}
