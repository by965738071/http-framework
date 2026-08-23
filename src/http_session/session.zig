//! Session 管理 addon — 迁移到新架构
//!
//! 基于 Cookie 的内存 Session 存储。
//!
//! 修复 bug.md Part 2 P0/P1：
//! - P0：线程不安全 — 加 std.Io.Mutex 保护 sessions map
//! - P1：setData 内存泄漏（重复 key 时旧 key/value 未释放）— 用 getOrPut + free old
//! - P1：deleteSession 内存泄漏（data map 的 key/value 未释放）— 遍历释放所有 data

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

const Context = http_app.Context;
const Response = http_protocol.Response;

/// Session 数据（键值对存储）
pub const SessionData = std.StringHashMap([]const u8);

/// Session 记录
const SessionRecord = struct {
    id: []const u8,
    data: SessionData,
    expires: i96, // 过期时间（纳秒，i96 匹配 Timestamp.nanoseconds）
    created: i96,
};

pub const SessionConfig = struct {
    cookie_name: []const u8 = "session_id",
    session_timeout_sec: u32 = 3600,
    cleanup_interval_sec: u32 = 300,
    /// 是否给 session cookie 加 Secure 属性（生产 HTTPS 下应为 true）。
    secure: bool = false,
    /// session 数量上限，防止匿名高频请求堆积 session 耗尽内存（DoS）。
    /// 达上限时先触发一次过期清理，仍满则拒绝创建。
    max_sessions: usize = 100_000,
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: SessionConfig,
    sessions: std.StringHashMap(SessionRecord),
    mutex: std.Io.Mutex = .init,
    last_cleanup: i96 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: SessionConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .sessions = std.StringHashMap(SessionRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // 释放所有 session 记录的 key/value
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var record = entry.value_ptr.*;
            self.freeSessionData(&record.data);
            self.allocator.free(record.id);
        }
        self.sessions.deinit();
    }

    /// 获取或创建 Session（线程安全）。
    /// 返回的 session_id 拷贝到 ctx.arena，生命周期随请求，不会在锁外悬空
    /// （回应审查发现 #4：不把 map 内部 key 越过锁交给调用方）。
    pub fn getOrCreate(self: *Self, ctx: *Context, res: *Response) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 1. 尝试从 Cookie 获取 session_id
        if (ctx.request.getCookie(self.config.cookie_name)) |session_id| {
            if (self.sessions.getPtr(session_id)) |record| {
                const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
                if (now < record.expires) {
                    // 滑动窗口：更新过期时间
                    record.expires = now + @as(i96, self.config.session_timeout_sec) * 1_000_000_000;
                    // Cookie 里的 session_id 生命周期随请求（head arena），本身安全，
                    // 但为统一语义也拷到 ctx.arena 返回。
                    return try ctx.arena.dupe(u8, session_id);
                } else {
                    // 过期，删除
                    self.deleteSessionLocked(session_id);
                }
            }
        }

        // 2. 创建新 Session
        const new_id = try self.createSessionLocked(res);
        return try ctx.arena.dupe(u8, new_id);
    }

    fn createSessionLocked(self: *Self, res: *Response) ![]const u8 {
        // 先尝试清理过期项，再判上限，避免匿名高频请求堆积 session 耗尽内存。
        if (self.sessions.count() >= self.config.max_sessions) {
            self.cleanupExpiredLocked();
            if (self.sessions.count() >= self.config.max_sessions) {
                return error.TooManySessions;
            }
        }

        var random_bytes: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_bytes);

        const session_id = try std.fmt.allocPrint(self.allocator, "sess{X}", .{&random_bytes});
        // 只在所有权移交给 map（put）之前有效；put 成功后正常返回不会触发。
        errdefer self.allocator.free(session_id);

        const now_ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const id_dup = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(id_dup);
        var data = SessionData.init(self.allocator);
        errdefer data.deinit();

        // 修复 A1：先写 Set-Cookie，再插 map。
        // 若 setCookieFull 失败，上面的 errdefer 会清理 session_id/id_dup/data，
        // 且此时 map 尚未持有 session_id，不会 double-free / 悬空 key。
        // Path=/ ：默认 default-path 会取请求 URI 目录，导致在 login 之外的路径丢失
        // session（RFC 6265 §5.1.4），所以显式设 Path=/。
        _ = try res.setCookieFull(.{
            .name = self.config.cookie_name,
            .value = session_id,
            .path = "/",
            .http_only = true,
            .secure = self.config.secure,
            .same_site = "Lax",
        });

        const record = SessionRecord{
            .id = id_dup,
            .data = data,
            .expires = now_ns + @as(i96, self.config.session_timeout_sec) * 1_000_000_000,
            .created = now_ns,
        };
        // put 成功后 session_id（key）与 record 的所有权移交 map；函数随后正常
        // 返回，errdefer 不触发。若 put 失败，errdefer 释放全部临时分配。
        try self.sessions.put(session_id, record);

        self.maybeCleanupLocked();
        return session_id;
    }

    /// 读取 Session 中某个键的值（线程安全）。
    ///
    /// 修复 A2：不再把内部 HashMap 结构越过锁返回给调用方（那会在并发
    /// setData/删除时悬空）。这里在持锁期间把值 dup 到调用方提供的
    /// allocator（通常是请求 arena），返回独立拷贝。
    pub fn getValue(self: *Self, session_id: []const u8, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.getPtr(session_id)) |record| {
            const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
            if (now < record.expires) {
                if (record.data.get(key)) |v| {
                    return try allocator.dupe(u8, v);
                }
            }
        }
        return null;
    }

    /// 设置 Session 数据（线程安全）
    /// 修复 P1：重复 key 时释放旧的 key/value，不再泄漏。
    /// 修复 A3：先把 key/value dup 成功，再改动 map，避免 OOM 时 map 残留
    /// undefined value 或悬空 entry。
    pub fn setData(self: *Self, session_id: []const u8, key: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const record = self.sessions.getPtr(session_id) orelse {
            std.log.warn("Session.setData: session not found: {s}", .{session_id});
            return;
        };

        // 先 dup（可能 OOM），成功后才动 map。
        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);
        const val_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_dup);

        const gop = try record.data.getOrPut(key);
        if (gop.found_existing) {
            // 重复 key：释放旧 key 和旧 value，复用槽位（key 用新 dup 覆盖）。
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.*);
        }
        // 到这里不再有可失败操作，安全接管所有权。
        gop.key_ptr.* = key_dup;
        gop.value_ptr.* = val_dup;
    }

    /// 删除 Session（线程安全）
    fn deleteSessionLocked(self: *Self, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            // fetchRemove 返回 KV 的按值拷贝，捕获 kv 是 const——需要先拷到
            // 可变局部变量才能拿 *SessionData（与 deinit 里同一模式）。
            var record = kv.value;
            // 修复 P1：释放 data map 中的所有 key/value
            self.freeSessionData(&record.data);
            self.allocator.free(record.id);
            // sessions map 的 key 已经在 fetchRemove 时移交了所有权
            self.allocator.free(kv.key);
        }
    }

    /// 释放 SessionData 中所有 key/value（修复 P1）
    fn freeSessionData(self: *Self, data: *SessionData) void {
        var it = data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        data.deinit();
    }

    fn maybeCleanupLocked(self: *Self) void {
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const interval_ns = @as(i96, self.config.cleanup_interval_sec) * 1_000_000_000;
        if (now - self.last_cleanup < interval_ns) return;
        self.last_cleanup = now;
        self.cleanupExpiredLocked();
    }

    fn cleanupExpiredLocked(self: *Self) void {
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.*.expires) {
                const key_dup = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(self.allocator, key_dup) catch {
                    self.allocator.free(key_dup);
                    continue;
                };
            }
        }

        for (to_remove.items) |key| {
            self.deleteSessionLocked(key);
            self.allocator.free(key);
        }
    }

    /// 公开销毁指定 session（登出）。线程安全。找不到则静默返回。
    /// 修复：原先只有私有 deleteSessionLocked，应用层无法真正登出。
    pub fn invalidate(self: *Self, session_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.deleteSessionLocked(session_id);
    }

    /// 从 Cookie 读取 session 并销毁（登出便捷方法）。线程安全。
    pub fn destroyFromRequest(self: *Self, ctx: *Context) void {
        if (ctx.request.getCookie(self.config.cookie_name)) |sid| {
            self.invalidate(sid);
        }
    }

    pub const Stats = struct {
        total: u32,
        active: u32,
        expired: u32,
    };

    pub fn getStats(self: *Self) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
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
// Tests
// ===========================================================================

test "SessionManager.init creates empty manager" {
    var sm = SessionManager.init(std.testing.allocator, std.testing.io, .{});
    defer sm.deinit();
    try std.testing.expect(sm.sessions.count() == 0);
}

test "SessionManager.setData/getData round trip" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io, .{});
    defer sm.deinit();

    // 手动插入一条 session（绕过 createSessionLocked 避免设置 cookie）
    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    const id_dup = try allocator.dupe(u8, "test_session");
    const record = SessionRecord{
        .id = try allocator.dupe(u8, "test_session"),
        .data = SessionData.init(allocator),
        .expires = now + @as(i96, 3600) * 1_000_000_000,
        .created = now,
    };
    try sm.sessions.put(id_dup, record);

    try sm.setData("test_session", "username", "alice");
    try sm.setData("test_session", "role", "admin");

    const username = (try sm.getValue("test_session", "username", allocator)) orelse @panic("data should exist");
    defer allocator.free(username);
    const role = (try sm.getValue("test_session", "role", allocator)) orelse @panic("data should exist");
    defer allocator.free(role);
    try std.testing.expectEqualStrings("alice", username);
    try std.testing.expectEqualStrings("admin", role);
}

test "SessionManager.setData overwrites without leak" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io, .{});
    defer sm.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    const id_dup = try allocator.dupe(u8, "overwrite_test");
    const record = SessionRecord{
        .id = try allocator.dupe(u8, "overwrite_test"),
        .data = SessionData.init(allocator),
        .expires = now + @as(i96, 3600) * 1_000_000_000,
        .created = now,
    };
    try sm.sessions.put(id_dup, record);

    // 第一次设置
    try sm.setData("overwrite_test", "key", "value1");
    // 覆盖（旧 key/value 应被释放——不泄漏）
    try sm.setData("overwrite_test", "key", "value2");

    const val = (try sm.getValue("overwrite_test", "key", allocator)) orelse @panic("data should exist");
    defer allocator.free(val);
    try std.testing.expectEqualStrings("value2", val);
}

test "SessionManager.setData on non-existent session does not crash" {
    var sm = SessionManager.init(std.testing.allocator, std.testing.io, .{});
    defer sm.deinit();
    try sm.setData("non_existent", "key", "value");
}

test "SessionManager.getStats with sessions" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io, .{});
    defer sm.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;

    // Active
    const id1 = try allocator.dupe(u8, "active_1");
    try sm.sessions.put(id1, .{
        .id = try allocator.dupe(u8, "active_1"),
        .data = SessionData.init(allocator),
        .expires = now + @as(i96, 3600) * 1_000_000_000,
        .created = now,
    });

    // Expired
    const id2 = try allocator.dupe(u8, "expired_1");
    try sm.sessions.put(id2, .{
        .id = try allocator.dupe(u8, "expired_1"),
        .data = SessionData.init(allocator),
        .expires = now - @as(i96, 3600) * 1_000_000_000,
        .created = now - @as(i96, 7200) * 1_000_000_000,
    });

    const stats = sm.getStats();
    try std.testing.expectEqual(@as(u32, 2), stats.total);
    try std.testing.expectEqual(@as(u32, 1), stats.active);
    try std.testing.expectEqual(@as(u32, 1), stats.expired);
}

test {
    std.testing.refAllDecls(@This());
}
