//! 小工具集：业务代码里反复出现、但放 std 又不合算的胶水。

const std = @import("std");

/// 当前 Unix 时间，毫秒（墙钟，`.real`）。
///
/// FRICTION F-22：业务代码里原本到处是
/// `@intCast(std.Io.Timestamp.now(io, .real).nanoseconds / std.time.ns_per_ms)`
/// 这一类样板（且容易把 `.real` 写成 `.monotonic` 得到与 Unix 纪元无关的值）。
/// 统一收口：
/// - `framework.nowMs(io)` —— 没有 ctx 的地方用；
/// - `ctx.nowMs()` —— handler / middleware 里用。
///
/// 返回值会随系统时钟回拨变小；只用于业务展示/字段存储，限流等需要单调性
/// 的场景请直接用 `Timestamp.now(io, .awake)`。
pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

test nowMs {
    const ms = nowMs(std.testing.io);
    // 与 2026-01-01(1767225600000) ~ 2100-01-01(4102444800001) 之间的 Unix 毫秒比较，
    // 换算单位错的实现（nanoseconds 直接透传等）必然超出这个窗口。
    try std.testing.expect(ms > 1_767_225_600_000);
    try std.testing.expect(ms < 4_102_444_800_001);
}
