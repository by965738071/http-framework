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
