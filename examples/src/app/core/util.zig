//! 通用小工具：时间、参数解析、字符串。

const std = @import("std");
const framework = @import("http_framework");
const errors = @import("errors.zig");

pub fn nowMs(io: std.Io) u64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// query 里的正整数，缺省或非法时返回 `default`。
pub fn queryInt(ctx: *const framework.Context, key: []const u8, default: u64) u64 {
    const raw = ctx.query(key) orelse return default;
    return std.fmt.parseInt(u64, raw, 10) catch default;
}

/// query 里的字符串（原始值，未解码）。缺省返回 `default`。
pub fn queryStr(ctx: *const framework.Context, key: []const u8, default: []const u8) []const u8 {
    return ctx.query(key) orelse default;
}

/// query 里可选字符串的解码版本。
pub fn queryStrDecoded(allocator: std.mem.Allocator, ctx: *framework.Context, key: []const u8) !?[]const u8 {
    return ctx.request.getQueryDecoded(allocator, key);
}

/// 解析路径参数为 u64；缺失/非法直接 fail 400。
pub fn pathId(ctx: *framework.Context, name: []const u8) !?u64 {
    const raw = ctx.param(name) orelse {
        try errors.fail(ctx, errors.ApiError.badRequest(errors.codes.validation_error, "missing path param"));
        return null;
    };
    return std.fmt.parseInt(u64, raw, 10) catch {
        try errors.fail(ctx, errors.ApiError.badRequest(errors.codes.validation_error, "path param must be an integer"));
        return null;
    };
}

/// 解析 "1,2,3" 形式的 id 列表。空串返回空切片。
pub fn parseIdList(allocator: std.mem.Allocator, raw: []const u8) ![]u64 {
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        try out.append(allocator, std.fmt.parseInt(u64, t, 10) catch 0);
    }
    return out.toOwnedSlice(allocator);
}

pub fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// 大小写不敏感的子串匹配（审计日志关键字检索用）。
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const limit = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= limit) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 把毫秒时间戳格式化成 "YYYY-MM-DD HH:MM:SS"（UTC）。导出日志用它。
pub fn formatTimestamp(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    if (ms <= 0) return allocator.dupe(u8, "");
    const secs = @divTrunc(ms, std.time.ms_per_s);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const hms = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            hms.getHoursIntoDay(),
            hms.getMinutesIntoHour(),
            hms.getSecondsIntoMinute(),
        },
    );
}

/// 会话里读出来的 user_id。
pub fn sessionUserId(ctx: *framework.Context) !?u64 {
    const sessions = ctx.service(framework.SessionManager) orelse return null;
    const sid = ctx.request.getCookie("sid") orelse return null;
    const raw = (try sessions.getValue(sid, "uid", ctx.arena)) orelse return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

// ── 测试 ────────────────────────────────────────────────────────────────

test "parseIdList 解析并跳过空段" {
    const ids = try parseIdList(std.testing.allocator, "1, 2,,3");
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
    try std.testing.expectEqual(@as(u64, 3), ids[2]);
}

test "parseIdList 空串返回空" {
    const ids = try parseIdList(std.testing.allocator, "");
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try std.testing.expect(!containsIgnoreCase("Hello", "bye"));
    try std.testing.expect(containsIgnoreCase("abc", ""));
}

test "contains 在字符串切片中查找" {
    try std.testing.expect(contains(&.{ "a", "b" }, "b"));
    try std.testing.expect(!contains(&.{ "a", "b" }, "c"));
}

test "formatTimestamp 输出 UTC 时间" {
    const s = try formatTimestamp(std.testing.allocator, 0);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test {
    std.testing.refAllDecls(@This());
}
