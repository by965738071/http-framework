//! 性能监控和指标收集
//! 支持请求计数、延迟统计、活跃连接数等。
//! 线程安全：所有公共方法都通过互斥锁保护。
//!
//! `MetricsCollector` 实现 `core.RequestObserver`——把它交给 Server：
//!
//! ```zig
//! var metrics = MetricsCollector.init(allocator, io);
//! defer metrics.deinit();
//! server.setObserver(metrics.observer());
//! ```

const std = @import("std");
const core = @import("core");

pub const RequestMetrics = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    latency_ns: u64,
    timestamp: i128,
};

pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    total_requests: u64 = 0,
    active_connections: u32 = 0,
    latencies: std.ArrayList(u64),
    /// 标记数据是否已被修改，需要重新排序才能计算百分位数
    sorted: bool = true,
    /// 最近一次 `server.stats()` 快照（由 `recordServerStats` 写入）。
    /// 从没记录过时为 null，报告里相应段落整段省略。
    server_stats: ?core.Server.Stats = null,
    /// 线程安全互斥锁（使用 std.Io.Mutex，需要 io 参数）
    mutex: std.Io.Mutex = .{ .state = .init(.unlocked) },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io, .latencies = .{ .items = &.{}, .capacity = 0 } };
    }

    pub fn deinit(self: *Self) void {
        self.latencies.deinit(self.allocator);
    }

    pub fn recordRequest(self: *Self, metrics: RequestMetrics) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.total_requests += 1;
        if (self.latencies.items.len < 10000) {
            try self.latencies.append(self.allocator, metrics.latency_ns);
            self.sorted = false;
        }
    }

    // ---- core.RequestObserver 实现 ----

    /// 由 Server 在每个请求结束时调用。
    /// 观测失败（如内存不足）静默丢弃——绝不能影响请求处理。
    pub fn record(self: *Self, info: core.RequestInfo) void {
        self.recordRequest(.{
            .method = @tagName(info.method),
            .path = info.route_pattern orelse "unmatched",
            .status = @backingInt(info.status),
            .latency_ns = info.latency_ns,
            .timestamp = 0,
        }) catch {};
    }

    /// 取得可注入 `server.setObserver()` 的接口句柄。
    pub fn observer(self: *Self) core.RequestObserver {
        return core.RequestObserver.init(Self, self);
    }

    /// 记录一次 `server.stats()` 快照，并入 `generateReport` 的输出。
    ///
    /// 这是**拉**模型，不是观察者回调：这些计数是服务器的连续状态，
    /// 不挂在任何单个请求上。典型用法是在后台 Worker 的 tick 里
    /// 或者 `/metrics` 路由的 handler 里调一次：
    ///
    /// ```zig
    /// metrics.recordServerStats(server.stats());
    /// ```
    ///
    /// 只保留最近一次快照，不做时间序列——序列该由 Prometheus 那一侧攒。
    pub fn recordServerStats(self: *Self, s: core.Server.Stats) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.server_stats = s;
    }

    pub fn connectionOpened(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active_connections += 1;
    }
    pub fn connectionClosed(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_connections > 0) self.active_connections -= 1;
    }

    pub fn getP50(self: *Self) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.getPercentile(50);
    }
    pub fn getP95(self: *Self) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.getPercentile(95);
    }
    pub fn getP99(self: *Self) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.getPercentile(99);
    }

    fn getPercentile(self: *Self, percentile: u8) u64 {
        // 调用者必须已经持有 mutex 锁
        const items = self.latencies.items;
        if (items.len == 0) return 0;

        // 仅在数据被修改时重新排序（惰性排序优化）
        if (!self.sorted) {
            const sorted = self.allocator.alloc(u64, items.len) catch {
                std.log.warn("Metrics: failed to allocate memory for percentile calculation", .{});
                return 0;
            };
            @memcpy(sorted, items);
            std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));
            // 将排序结果写回（仅当分配成功时）
            @memcpy(self.latencies.items.ptr[0..items.len], sorted);
            self.allocator.free(sorted);
            self.sorted = true;
        }

        const idx = (percentile * items.len + 99) / 100;
        return items[if (idx > 0) idx - 1 else 0];
    }

    pub fn generateReport(self: *Self, buffer: []u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var w = std.Io.Writer.fixed(buffer);
        try w.print("requests: {d}\nactive_conn: {d}\np50_ns: {d}\np95_ns: {d}\np99_ns: {d}\n", .{
            self.total_requests,
            self.active_connections,
            self.getPercentile(50),
            self.getPercentile(95),
            self.getPercentile(99),
        });

        // 快路径失效计数。三个 0 才是稳态；任何一个持续增长都指向
        // 一处具体的配置错配（见 core.Server.Stats 的字段注释）。
        if (self.server_stats) |s| {
            try w.print(
                \\srv_total_conn: {d}
                \\srv_active_req: {d}
                \\srv_accept_errors: {d}
                \\srv_inline_fallbacks: {d}
                \\srv_conn_state_failures: {d}
                \\pool_hits: {d}
                \\pool_misses: {d}
                \\pool_discarded: {d}
                \\pool_idle: {d}
                \\
            , .{
                s.total_connections,
                s.active_requests,
                s.accept_errors,
                s.inline_fallbacks,
                s.conn_state_failures,
                s.pool.pool_hits,
                s.pool.pool_misses,
                s.pool.discarded,
                s.pool.idle,
            });
        }

        return w.buffered();
    }
};

// =========================================================================
// 测试
// =========================================================================

test "MetricsCollector.init initializes with zero counters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var collector = MetricsCollector.init(allocator, io);
    defer collector.deinit();

    try std.testing.expectEqual(@as(u64, 0), collector.total_requests);
    try std.testing.expectEqual(@as(u32, 0), collector.active_connections);
    try std.testing.expectEqual(@as(usize, 0), collector.latencies.items.len);
}

test "generateReport: 没记录过服务器快照时不输出 srv_/pool_ 段" {
    const allocator = std.testing.allocator;
    var collector = MetricsCollector.init(allocator, std.testing.io);
    defer collector.deinit();

    var buf: [1024]u8 = undefined;
    const report = try collector.generateReport(&buf);

    try std.testing.expect(std.mem.indexOf(u8, report, "requests: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "pool_hits") == null);
}

test "generateReport: 服务器快照里的快路径失效计数会出现在报告里" {
    const allocator = std.testing.allocator;
    var collector = MetricsCollector.init(allocator, std.testing.io);
    defer collector.deinit();

    collector.recordServerStats(.{
        .active_connections = 3,
        .active_requests = 2,
        .total_connections = 100,
        .accept_errors = 1,
        .inline_fallbacks = 7,
        .conn_state_failures = 0,
        .pool = .{ .pool_hits = 90, .pool_misses = 10, .discarded = 4, .idle = 12 },
    });

    var buf: [1024]u8 = undefined;
    const report = try collector.generateReport(&buf);

    // 这三个是定位配置错配的关键信号，必须能被抓到
    try std.testing.expect(std.mem.indexOf(u8, report, "srv_inline_fallbacks: 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "pool_misses: 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "srv_conn_state_failures: 0") != null);
}

test "MetricsCollector.recordRequest increments counter and stores latency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var collector = MetricsCollector.init(allocator, io);
    defer collector.deinit();

    try collector.recordRequest(.{
        .method = "GET",
        .path = "/api/test",
        .status = 200,
        .latency_ns = 1_500_000,
        .timestamp = 1000,
    });
    try std.testing.expectEqual(@as(u64, 1), collector.total_requests);
    try std.testing.expectEqual(@as(usize, 1), collector.latencies.items.len);
    try std.testing.expectEqual(@as(u64, 1_500_000), collector.latencies.items[0]);
}

test "MetricsCollector.recordRequest with multiple requests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var collector = MetricsCollector.init(allocator, io);
    defer collector.deinit();

    try collector.recordRequest(.{ .method = "GET", .path = "/a", .status = 200, .latency_ns = 100, .timestamp = 1 });
    try collector.recordRequest(.{ .method = "POST", .path = "/b", .status = 201, .latency_ns = 200, .timestamp = 2 });
    try collector.recordRequest(.{ .method = "GET", .path = "/c", .status = 404, .latency_ns = 300, .timestamp = 3 });

    try std.testing.expectEqual(@as(u64, 3), collector.total_requests);
    try std.testing.expectEqual(@as(usize, 3), collector.latencies.items.len);
}

test "MetricsCollector getP50/P95/P99 with empty data returns zero" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var collector = MetricsCollector.init(allocator, io);
    defer collector.deinit();

    // Empty latency list → early return 0 from getPercentile
    try std.testing.expectEqual(@as(u64, 0), collector.getP50());
    try std.testing.expectEqual(@as(u64, 0), collector.getP95());
    try std.testing.expectEqual(@as(u64, 0), collector.getP99());
}

test "MetricsCollector.generateReport with empty data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var collector = MetricsCollector.init(allocator, io);
    defer collector.deinit();

    var buf: [512]u8 = undefined;
    const report = try collector.generateReport(&buf);

    try std.testing.expect(std.mem.indexOf(u8, report, "requests: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "active_conn: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "p50_ns: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "p95_ns: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "p99_ns: 0") != null);
}

// ===========================================================================
// Tests
// ===========================================================================

test "MetricsCollector - record and report" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var m = MetricsCollector.init(allocator, io);
    defer m.deinit();

    try m.recordRequest(.{ .method = "GET", .path = "/", .status = 200, .latency_ns = 1000, .timestamp = 0 });
    try m.recordRequest(.{ .method = "POST", .path = "/users", .status = 201, .latency_ns = 2000, .timestamp = 0 });
    try std.testing.expectEqual(@as(u64, 2), m.total_requests);

    var buf: [256]u8 = undefined;
    const report = try m.generateReport(&buf);
    try std.testing.expect(report.len > 0);
}

test "MetricsCollector - connection tracking" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var m = MetricsCollector.init(allocator, io);
    defer m.deinit();

    m.connectionOpened();
    m.connectionOpened();
    try std.testing.expectEqual(@as(u32, 2), m.active_connections);
    m.connectionClosed();
    try std.testing.expectEqual(@as(u32, 1), m.active_connections);
    m.connectionClosed();
    try std.testing.expectEqual(@as(u32, 0), m.active_connections);
    m.connectionClosed(); // should not underflow
    try std.testing.expectEqual(@as(u32, 0), m.active_connections);
}

test "MetricsCollector - percentiles" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var m = MetricsCollector.init(allocator, io);
    defer m.deinit();

    try std.testing.expectEqual(@as(u64, 0), m.getP50());
    for (0..100) |i| {
        try m.recordRequest(.{ .method = "GET", .path = "/", .status = 200, .latency_ns = @as(u64, i) * 10, .timestamp = 0 });
    }
    const p50 = m.getP50();
    try std.testing.expect(p50 > 0);
}
