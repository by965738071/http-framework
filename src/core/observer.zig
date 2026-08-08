//! 请求观察者接口（核心侧）
//!
//! 核心在每个请求结束时把一份不可变的摘要交出去，至于对方是算 P99、
//! 打点到 Prometheus 还是丢进 tracing，核心一概不管。
//!
//! 这条接口的存在是为了让 `core` 不必 `@import` 任何具体的 metrics 实现——
//! 依赖方向必须是 observability → core，而不是反过来。

const std = @import("std");
const http = std.http;

/// 一个已完成请求的摘要。
pub const RequestInfo = struct {
    method: http.Method,
    /// 命中的路由 **pattern**（如 `/users/:id`），未命中时为 null。
    ///
    /// 刻意不给原始路径：用 `/users/123`、`/users/124` 这样的具体路径做指标
    /// 标签会导致基数爆炸，把时序数据库打垮。
    route_pattern: ?[]const u8,
    status: http.Status,
    latency_ns: u64,
};

/// 请求观察者。
pub const RequestObserver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 记录一个已完成的请求。
        /// 不得返回错误——观测失败绝不能影响请求处理。
        record: *const fn (ptr: *anyopaque, info: RequestInfo) void,
    };

    /// 由具体实现构造。`T` 需提供 `fn record(*T, RequestInfo) void`。
    pub fn init(comptime T: type, impl: *T) RequestObserver {
        const gen = struct {
            fn record(ptr: *anyopaque, info: RequestInfo) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                T.record(self, info);
            }
        };
        return .{
            .ptr = impl,
            .vtable = &.{ .record = gen.record },
        };
    }

    pub fn record(self: RequestObserver, info: RequestInfo) void {
        self.vtable.record(self.ptr, info);
    }
};

// =========================================================================
// 测试
// =========================================================================

const CountingObserver = struct {
    count: usize = 0,
    last: ?RequestInfo = null,

    fn record(self: *CountingObserver, info: RequestInfo) void {
        self.count += 1;
        self.last = info;
    }
};

test "RequestObserver dispatches through vtable" {
    var obs = CountingObserver{};
    const o = RequestObserver.init(CountingObserver, &obs);

    o.record(.{
        .method = .GET,
        .route_pattern = "/users/:id",
        .status = .ok,
        .latency_ns = 1234,
    });

    try std.testing.expectEqual(@as(usize, 1), obs.count);
    try std.testing.expectEqualStrings("/users/:id", obs.last.?.route_pattern.?);
    try std.testing.expectEqual(http.Status.ok, obs.last.?.status);
}
