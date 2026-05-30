//! 性能监控和指标收集
//! 支持请求计数、延迟统计、活跃连接数等。

const std = @import("std");

pub const RequestMetrics = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    latency_ns: u64,
    timestamp: i128,
};

pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    total_requests: u64 = 0,
    active_connections: u32 = 0,
    latencies: std.ArrayList(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .latencies = .{ .items = &.{}, .capacity = 0 } };
    }

    pub fn deinit(self: *Self) void {
        self.latencies.deinit(self.allocator);
    }

    pub fn recordRequest(self: *Self, metrics: RequestMetrics) !void {
        self.total_requests += 1;
        if (self.latencies.items.len < 10000) {
            try self.latencies.append(self.allocator, metrics.latency_ns);
        }
    }

    pub fn connectionOpened(self: *Self) void {
        self.active_connections += 1;
    }
    pub fn connectionClosed(self: *Self) void {
        if (self.active_connections > 0) self.active_connections -= 1;
    }

    pub fn getP50(self: *const Self) u64 {
        return self.getPercentile(50);
    }
    pub fn getP95(self: *const Self) u64 {
        return self.getPercentile(95);
    }
    pub fn getP99(self: *const Self) u64 {
        return self.getPercentile(99);
    }

    fn getPercentile(self: *const Self, percentile: u8) u64 {
        const items = self.latencies.items;
        if (items.len == 0) return 0;
        const sorted = try self.allocator.alloc(u64, items.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, items);
        std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));
        const idx = (percentile * items.len + 99) / 100;
        return sorted[if (idx > 0) idx - 1 else 0];
    }

    pub fn generateReport(self: *const Self, buffer: []u8) ![]u8 {
        var fbs = std.Io.FixedBufferStream([]u8){ .buf = buffer, .pos = 0 };
        const w = fbs.writer();
        try w.print("requests: {d}\n", .{self.total_requests});
        try w.print("active_conn: {d}\n", .{self.active_connections});
        try w.print("p50_ns: {d}\n", .{self.getP50()});
        try w.print("p95_ns: {d}\n", .{self.getP95()});
        try w.print("p99_ns: {d}\n", .{self.getP99()});
        return fbs.getWritten();
    }
};

// =========================================================================
// 测试
// =========================================================================

test "MetricsCollector.init initializes with zero counters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = MetricsCollector.init(allocator);
    defer collector.deinit();

    try std.testing.expectEqual(@as(u64, 0), collector.total_requests);
    try std.testing.expectEqual(@as(u32, 0), collector.active_connections);
    try std.testing.expectEqual(@as(usize, 0), collector.latencies.items.len);
}

test "MetricsCollector.recordRequest increments counter and stores latency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = MetricsCollector.init(allocator);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = MetricsCollector.init(allocator);
    defer collector.deinit();

    try collector.recordRequest(.{ .method = "GET", .path = "/a", .status = 200, .latency_ns = 100, .timestamp = 1 });
    try collector.recordRequest(.{ .method = "POST", .path = "/b", .status = 201, .latency_ns = 200, .timestamp = 2 });
    try collector.recordRequest(.{ .method = "GET", .path = "/c", .status = 404, .latency_ns = 300, .timestamp = 3 });

    try std.testing.expectEqual(@as(u64, 3), collector.total_requests);
    try std.testing.expectEqual(@as(usize, 3), collector.latencies.items.len);
}

test "MetricsCollector getP50/P95/P99 with empty data returns zero" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = MetricsCollector.init(allocator);
    defer collector.deinit();

    // Empty latency list → early return 0 from getPercentile
    try std.testing.expectEqual(@as(u64, 0), collector.getP50());
    try std.testing.expectEqual(@as(u64, 0), collector.getP95());
    try std.testing.expectEqual(@as(u64, 0), collector.getP99());
}

test "MetricsCollector.generateReport with empty data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = MetricsCollector.init(allocator);
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
    var m = MetricsCollector.init(std.testing.allocator);
    defer m.deinit();

    try m.recordRequest(.{ .method = "GET", .path = "/", .status = 200, .latency_ns = 1000, .timestamp = 0 });
    try m.recordRequest(.{ .method = "POST", .path = "/users", .status = 201, .latency_ns = 2000, .timestamp = 0 });
    try std.testing.expectEqual(@as(u64, 2), m.total_requests);

    var buf: [256]u8 = undefined;
    const report = try m.generateReport(&buf);
    try std.testing.expect(report.len > 0);
}

test "MetricsCollector - connection tracking" {
    var m = MetricsCollector.init(std.testing.allocator);
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
    var m = MetricsCollector.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(u64, 0), m.getP50());
    for (0..100) |i| {
        try m.recordRequest(.{ .method = "GET", .path = "/", .status = 200, .latency_ns = @as(u64, i) * 10, .timestamp = 0 });
    }
    const p50 = m.getP50();
    try std.testing.expect(p50 > 0);
}
