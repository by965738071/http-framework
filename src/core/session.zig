//! 生产级会话管理（Session Management）
//! 基于 Cookie 的 Session 存储，支持内存、文件或 Redis 后端。
//! 使用 Zig 0.17.0-dev API 规范。

const std = @import("std");
const mem = std.mem;
const io = std.Io;

const Allocator = std.mem.Allocator;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

/// Session 数据（键值对存储）
pub const SessionData = std.StringHashMap([]const u8);

/// Session 记录
const SessionRecord = struct {
    id: []const u8,
    data: SessionData,
    expires: i128, // 过期时间（纳秒时间戳）
    created: i128, // 创建时间（用于统计）
};

/// Session 管理器（生产级）
pub const SessionManager = struct {
    allocator: Allocator,
    io_ctx: std.Io,
    sessions: std.StringHashMap(SessionRecord),
    cookie_name: []const u8 = "session_id",
    session_timeout_sec: u32 = 3600, // 1 小时
    cleanup_interval_sec: u32 = 300, // 5 分钟清理一次
    last_cleanup: i128 = 0, // 上次清理时间

    const Self = @This();

    /// 初始化 Session 管理器
    pub fn init(allocator: Allocator, io_ctx: std.Io) Self {
        return Self{
            .allocator = allocator,
            .io_ctx = io_ctx,
            .sessions = std.StringHashMap(SessionRecord).init(allocator),
        };
    }

    /// 释放所有资源
    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var record = entry.value_ptr.*;
            // Free all keys and values in the data hashmap
            var data_it = record.data.iterator();
            while (data_it.next()) |data_entry| {
                self.allocator.free(data_entry.key_ptr.*);
                self.allocator.free(data_entry.value_ptr.*);
            }
            record.data.deinit();
            self.allocator.free(record.id);
        }
        self.sessions.deinit();
    }

    /// 获取或创建 Session（生产级）
    pub fn getOrCreate(self: *Self, ctx: *RequestContext, res: *Response) ![]const u8 {
        // 1. 尝试从 Cookie 获取 session_id
        if (ctx.getCookie(self.cookie_name)) |session_id| {
            if (self.sessions.get(session_id)) |*record| {
                const now = std.Io.Clock.now(.real, self.io_ctx).nanoseconds;

                // 检查是否过期
                if (now < record.expires) {
                    // 更新过期时间（滑动窗口）
                    record.expires = now + @as(i128, self.session_timeout_sec) * 1_000_000_000;
                    return session_id;
                } else {
                    // 过期，删除
                    self.deleteSession(session_id);
                }
            }
        }

        // 2. 创建新 Session
        return try self.createSession(res);
    }

    /// 创建新 Session（使用安全随机数）
    fn createSession(self: *Self, res: *Response) ![]const u8 {
        // 使用 std.Io.randomSecure 生成安全随机数（遵循 SKILL.md）
        // 注意：需要传入 io 实例，通过 SessionManager.init 传入
        var random_bytes: [32]u8 = undefined;
        self.io_ctx.randomSecure(&random_bytes);

        // 生成 session_id（使用十六进制表示）
        const session_id = try std.fmt.allocPrint(
            self.allocator,
            "sess_{s}",
            .{std.fmt.fmtSliceHexUpper(&random_bytes)},
        );

        // 创建 Session 记录
        const now_ns = std.Io.Clock.now(.real, self.io_ctx).nanoseconds;
        const record = SessionRecord{
            .id = try self.allocator.dupe(u8, session_id),
            .data = SessionData.init(self.allocator),
            .expires = now_ns + @as(i128, self.session_timeout_sec) * 1_000_000_000,
            .created = now_ns,
        };

        try self.sessions.put(session_id, record);

        // 设置 Cookie（遵循标准格式）
        try res.setCookie(self.cookie_name, session_id);

        // 触发清理（如果到了清理时间）
        self.maybeCleanup();

        return session_id;
    }

    /// 获取 Session 数据
    pub fn getData(self: *const Self, session_id: []const u8) ?*const SessionData {
        const entry = self.sessions.getEntry(session_id) orelse return null;
        return &entry.value_ptr.data;
    }

    /// 设置 Session 数据
    pub fn setData(self: *Self, session_id: []const u8, key: []const u8, value: []const u8) !void {
        const entry = self.sessions.getEntry(session_id) orelse {
            std.log.warn("Session.setData: session_id not found (may have expired): {s}", .{session_id});
            return;
        };
        const key_dup = try self.allocator.dupe(u8, key);
        const val_dup = try self.allocator.dupe(u8, value);
        try entry.value_ptr.data.put(key_dup, val_dup);
    }

    /// 删除 Session
    fn deleteSession(self: *Self, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            self.allocator.free(kv.value.id);
            kv.value.data.deinit();
        }
    }

    /// 定期清理过期 Session
    fn maybeCleanup(self: *Self) void {
        const now = std.Io.Clock.now(.real, self.io_ctx).nanoseconds;
        const cleanup_interval_ns = @as(i128, self.cleanup_interval_sec) * 1_000_000_000;

        if (now - self.last_cleanup < cleanup_interval_ns) {
            return; // 还没到清理时间
        }

        self.last_cleanup = now;
        self.cleanupExpired();
    }

    /// 清理所有过期的 Session
    fn cleanupExpired(self: *Self) void {
        const now = std.Io.Clock.now(.real, self.io_ctx).nanoseconds;
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.*.expires) {
                // 记录需要删除的 key
                const key_dup = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(self.allocator, key_dup) catch continue;
            }
        }

        // 删除过期的 Session
        for (to_remove.items) |key| {
            self.deleteSession(key);
            self.allocator.free(key);
        }
    }

    /// 获取 Session 统计信息
    pub const Stats = struct {
        total: u32,
        active: u32,
        expired: u32,
    };

    pub fn getStats(self: *const Self) Stats {
        const now = std.Io.Clock.now(.real, self.io_ctx).nanoseconds;
        var stats = Stats{ .total = 0, .active = 0, .expired = 0 };

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            stats.total += 1;
            if (now < entry.value_ptr.*.expires) {
                stats.active += 1;
            } else {
                stats.expired += 1;
            }
        }

        return stats;
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "SessionManager.init - creates empty manager" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    try std.testing.expectEqualStrings("session_id", sm.cookie_name);
    try std.testing.expectEqual(@as(u32, 3600), sm.session_timeout_sec);
    try std.testing.expect(sm.sessions.count() == 0);
}

test "SessionManager.getData - returns null for non-existent session" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    const data = sm.getData("non_existent");
    try std.testing.expect(data == null);
}

test "SessionManager.setData - warns on non-existent session (no crash)" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    // Should not crash, just log a warning
    try sm.setData("non_existent", "key", "value");
}

test "SessionManager.setData/getData - round trip" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    // 手动创建一个 session 记录
    const session_id = try std.fmt.allocPrint(allocator, "test_session", .{});
    defer allocator.free(session_id);

    const now = std.Io.Clock.now(.real, std.testing.io).nanoseconds;
    const record = SessionRecord{
        .id = try allocator.dupe(u8, session_id),
        .data = SessionData.init(allocator),
        .expires = now + @as(i128, 3600) * 1_000_000_000,
        .created = now,
    };
    try sm.sessions.put(try allocator.dupe(u8, session_id), record);

    // setData
    try sm.setData(session_id, "username", "alice");
    try sm.setData(session_id, "role", "admin");

    // getData
    const data = sm.getData(session_id) orelse @panic("data should exist");
    try std.testing.expectEqualStrings("alice", data.get("username").?);
    try std.testing.expectEqualStrings("admin", data.get("role").?);
}

test "SessionManager.getStats - empty manager" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    const stats = sm.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total);
    try std.testing.expectEqual(@as(u32, 0), stats.active);
    try std.testing.expectEqual(@as(u32, 0), stats.expired);
}

test "SessionManager.getStats - with sessions" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io);
    defer sm.deinit();

    const now = std.Io.Clock.now(.real, std.testing.io).nanoseconds;

    // Active session
    {
        const id = try std.fmt.allocPrint(allocator, "active_1", .{});
        defer allocator.free(id);
        const record = SessionRecord{
            .id = try allocator.dupe(u8, id),
            .data = SessionData.init(allocator),
            .expires = now + @as(i128, 3600) * 1_000_000_000,
            .created = now,
        };
        try sm.sessions.put(try allocator.dupe(u8, id), record);
    }

    // Expired session (set timeout in the past)
    {
        const id = try std.fmt.allocPrint(allocator, "expired_1", .{});
        defer allocator.free(id);
        const record = SessionRecord{
            .id = try allocator.dupe(u8, id),
            .data = SessionData.init(allocator),
            .expires = now - @as(i128, 3600) * 1_000_000_000, // 1 hour ago
            .created = now - @as(i128, 7200) * 1_000_000_000,
        };
        try sm.sessions.put(try allocator.dupe(u8, id), record);
    }

    const stats = sm.getStats();
    try std.testing.expectEqual(@as(u32, 2), stats.total);
    try std.testing.expectEqual(@as(u32, 1), stats.active);
    try std.testing.expectEqual(@as(u32, 1), stats.expired);
}
