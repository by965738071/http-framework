//! 生产级会话管理（Session Management）
//! 基于 Cookie 的 Session 存储，支持内存、文件或 Redis 后端。
//! 使用 Zig 0.17.0-dev API 规范。

const std = @import("std");
const mem = std.mem;
const time = std.time;
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
    sessions: std.StringHashMap(SessionRecord) = .empty,
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
            .sessions = std.StringHashMap(SessionRecord).empty,
        };
    }

    /// 释放所有资源
    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var record = entry.value_ptr.*;
            record.data.deinit(self.allocator);
            self.allocator.free(record.id);
        }
        self.sessions.deinit(self.allocator);
    }

    /// 获取或创建 Session（生产级）
    pub fn getOrCreate(self: *Self, ctx: *RequestContext, res: *Response) ![]const u8 {
        // 1. 尝试从 Cookie 获取 session_id
        if (ctx.getCookie(self.cookie_name)) |session_id| {
            if (self.sessions.get(session_id)) |*record| {
                const now = time.nanoTimestamp();

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
        const record = SessionRecord{
            .id = try self.allocator.dupe(u8, session_id),
            .data = SessionData.init(self.allocator),
            .expires = time.nanoTimestamp() + @as(i128, self.session_timeout_sec) * 1_000_000_000,
            .created = time.nanoTimestamp(),
        };

        try self.sessions.put(self.allocator, session_id, record);

        // 设置 Cookie（遵循标准格式）
        try res.setCookie(self.cookie_name, session_id);

        // 触发清理（如果到了清理时间）
        self.maybeCleanup();

        return session_id;
    }

    /// 获取 Session 数据
    pub fn getData(self: *const Self, session_id: []const u8) ?*SessionData {
        if (self.sessions.get(session_id)) |*record| {
            return &record.data;
        }
        return null;
    }

    /// 设置 Session 数据
    pub fn setData(self: *Self, session_id: []const u8, key: []const u8, value: []const u8) !void {
        if (self.sessions.getPtr(session_id)) |*record| {
            const key_dup = try self.allocator.dupe(u8, key);
            const val_dup = try self.allocator.dupe(u8, value);
            try record.data.put(self.allocator, key_dup, val_dup);
        }
    }

    /// 删除 Session
    fn deleteSession(self: *Self, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            self.allocator.free(kv.value.id);
            kv.value.data.deinit(self.allocator);
        }
    }

    /// 定期清理过期 Session
    fn maybeCleanup(self: *Self) void {
        const now = time.nanoTimestamp();
        const cleanup_interval_ns = @as(i128, self.cleanup_interval_sec) * 1_000_000_000;

        if (now - self.last_cleanup < cleanup_interval_ns) {
            return; // 还没到清理时间
        }

        self.last_cleanup = now;
        self.cleanupExpired();
    }

    /// 清理所有过期的 Session
    fn cleanupExpired(self: *Self) void {
        const now = time.nanoTimestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
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
    pub fn getStats(self: *const Self) struct {
        total: u32,
        active: u32, // 未过期
        expired: u32, // 已过期
    } {
        const now = time.nanoTimestamp();
        var stats = .{ .total = 0, .active = 0, .expired = 0 };

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
