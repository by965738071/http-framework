//! 性能监控和指标收集
//! 支持请求计数、延迟统计（P50/P95/P99）、活跃连接数等。

const std = @import("std");
const time = std.time;

const Allocator = std.mem.Allocator;

/// 延迟统计配置
const MAX_LATENCY_SAMPLES: usize = 10000;

/// 单个请求的指标
pub const RequestMetrics = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    latency_ns: u64, // 纳秒
    timestamp: i128, // 纳秒时间戳
};

/// 指标收集器
pub const MetricsCollector = struct {
    allocator: Allocator,

    // 计数器
    total_requests: u64 = 0,
    active_connections: u32 = 0,

    // 延迟统计（滑动窗口）
    latencies: std.ArrayList(u64) = .empty,

    // 状态码计数
    status_counts: std.StringHashMap(u32) = .empty,

    // 路径计数
    path_counts: std.StringHashMap(u32) = .empty,

    const Self = @This();

    /// 初始化指标收集器
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .latencies = std.ArrayList(u64).empty,
            .status_counts = std.StringHashMap(u32).empty,
            .path_counts = std.StringHashMap(u32).empty,
        };
    }

    /// 释放资源
    pub fn deinit(self: *Self) void {
        self.latencies.deinit(self.allocator);

        // 释放 status_counts
        var it = self.status_counts.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.status_counts.deinit(self.allocator);

        // 释放 path_counts
        it = self.path_counts.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_counts.deinit(self.allocator);
    }

    /// 记录请求
    pub fn recordRequest(self: *Self, metrics: RequestMetrics) !void {
        self.total_requests += 1;

        // 记录延迟
        if (self.latencies.items.len < MAX_LATENCY_SAMPLES) {
            try self.latencies.append(self.allocator, metrics.latency_ns);
        }

        // 记录状态码
        const status_key = try std.fmt.allocPrint(self.allocator, "{d}", .{metrics.status});
        if (self.status_counts.get(status_key)) |*count| {
            count.* += 1;
            self.allocator.free(status_key);
        } else {
            try self.status_counts.put(self.allocator, status_key, 1);
        }

        // 记录路径
        const path_dup = try self.allocator.dupe(u8, metrics.path);
        if (self.path_counts.get(path_dup)) |*count| {
            count.* += 1;
            self.allocator.free(path_dup);
        } else {
            try self.path_counts.put(self.allocator, path_dup, 1);
        }
    }

    /// 获取 P50 延迟（纳秒）
    pub fn getP50(self: *const Self) u64 {
        return self.getPercentile(50);
    }

    /// 获取 P95 延迟（纳秒）
    pub fn getP95(self: *const Self) u64 {
        return self.getPercentile(95);
    }

    /// 获取 P99 延迟（纳秒）
    pub fn getP99(self: *const Self) u64 {
        return self.getPercentile(99);
    }

    /// 计算百分位延迟
    fn getPercentile(self: *const Self, percentile: u8) u64 {
        if (self.latencies.items.len == 0) return 0;

        // 复制并排序延迟数据
        var sorted = std.ArrayList(u64).empty;
        defer sorted.deinit(self.allocator);
        sorted.appendSlice(self.allocator, self.latencies.items) catch return 0;

        std.sort.insertion(u64, sorted.items, {}, struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lessThan);

        const idx = @as(usize, @intCast((@as(u64, percentile) * sorted.items.len + 99) / 100));
        const clamped_idx = if (idx > 0) idx - 1 else 0;
        if (clamped_idx >= sorted.items.len) return sorted.getLast();
        return sorted.items[clamped_idx];
    }

    /// 增加活跃连接数
    pub fn connectionOpened(self: *Self) void {
        self.active_connections += 1;
    }

    /// 减少活跃连接数
    pub fn connectionClosed(self: *Self) void {
        if (self.active_connections > 0) {
            self.active_connections -= 1;
        }
    }

    /// 生成指标报告（文本格式）
    pub fn generateReport(self: *const Self, buffer: []u8) ![]u8 {
        var fbuf: std.Io.FixedBufferStream([]u8) = .{ .buf = buffer };
        const writer = fbuf.writer();

        try writer.print("Total Requests: {d}\n", .{self.total_requests});
        try writer.print("Active Connections: {d}\n", .{self.active_connections});
        try writer.print("P50 Latency: {d} ns\n", .{self.getP50()});
        try writer.print("P95 Latency: {d} ns\n", .{self.getP95()});
        try writer.print("P99 Latency: {d} ns\n", .{self.getP99()});

        try writer.writeAll("Status Codes:\n");
        var it = self.status_counts.iterator();
        while (it.next()) |entry| {
            try writer.print("  {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        return fbuf.getWritten();
    }
};
