//! 会话管理（Session Management）
//! 基于 Cookie 的 Session 存储，支持内存、文件或 Redis 后端。
//! 当前实现内存存储，支持过期时间。

const std = @import("std");
const mem = std.mem;
const time = std.time;

const Allocator = std.mem.Allocator;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

/// Session 数据
pub const SessionData = std.StringHashMap([]const u8);

/// Session 记录
const SessionRecord = struct {
    id: []const u8,
    data: SessionData,
    expires: i128, // 过期时间（纳秒时间戳）
};

/// Session 管理器
pub const SessionManager = struct {
    allocator: Allocator,
    sessions: std.StringHashMap(SessionRecord) = .empty,
    cookie_name: []const u8 = "session_id",
    session_timeout_sec: u32 = 3600, // 1 小时

    const Self = @This();

    /// 初始化 Session 管理器
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .sessions = std.StringHashMap(SessionRecord).empty,
        };
    }

    /// 释放资源
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

    /// 获取或创建 Session
    pub fn getOrCreate(self: *Self, ctx: *RequestContext, res: *Response) ![]const u8 {
        // 尝试从 Cookie 获取 session_id
        if (ctx.getCookie(self.cookie_name)) |session_id| {
            if (self.sessions.get(session_id)) |*record| {
                // 检查是否过期
                const now = time.nanoTimestamp();
                if (now < record.expires) {
                    // 更新过期时间
                    record.expires = now + @as(i128, self.session_timeout_sec) * 1_000_000_000;
                    return session_id;
                } else {
                    // 过期，删除
                    self.deleteSession(session_id);
                }
            }
        }

        // 创建新 Session
        return try self.createSession(res);
    }

    /// 创建新 Session
    fn createSession(self: *Self, res: *Response) ![]const u8 {
        // 生成 session_id（使用 Io.randomSecure）
        var random_bytes: [32]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.ioBasic();
        io.randomSecure(&random_bytes);
        const session_id = try std.fmt.allocPrint(self.allocator, "sess_{x}", .{std.fmt.fmtSliceHexUpper(&random_bytes)});

        // 创建 Session 记录
        const record = SessionRecord{
            .id = try self.allocator.dup(session_id),
            .data = SessionData.init(self.allocator),
            .expires = time.nanoTimestamp() + @as(i128, self.session_timeout_sec) * 1_000_000_000,
        };

        try self.sessions.put(self.allocator, session_id, record);

        // 设置 Cookie
        try res.setCookie(self.cookie_name, session_id);

        return session_id;
    }

    /// 获取 Session 数据
    pub fn getData(self: *Self, session_id: []const u8) ?*SessionData {
        if (self.sessions.get(session_id)) |*record| {
            return &record.data;
        }
        return null;
    }

    /// 设置 Session 数据
    pub fn setData(self: *Self, session_id: []const u8, key: []const u8, value: []const u8) !void {
        if (self.sessions.getPtr(session_id)) |*record| {
            try record.data.put(self.allocator, try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
        }
    }

    /// 删除 Session
    fn deleteSession(self: *Self, session_id: []const u8) void {
        if (self.sessions.get(session_id)) |record| {
            self.allocator.free(record.id);
            record.data.deinit(self.allocator);
        }
        _ = self.sessions.remove(session_id);
    }
};
