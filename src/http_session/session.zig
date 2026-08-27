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
const Request = http_app.Request;
const RequestState = http_app.RequestState;
const RequestConfig = http_app.RequestConfig;
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
    /// 是否给 session cookie 加 Secure 属性（只经 TLS 传输）。
    /// 默认 true（M9：明文 HTTP 下 cookie 可被网络嗅探窃取，登录会话一旦泄露
    /// 等于鉴权全没了）。纯本机开发用明文 HTTP 时请显式设为 false。
    secure: bool = true,
    /// session 数量上限，防止匿名高频请求堆积 session 耗尽内存（DoS）。
    /// 达上限时先触发一次过期清理，仍满则驱逐采样中最旧的一条。
    max_sessions: usize = 100_000,
};

/// 满员驱逐时的采样条数（M7）。用「采样 K 条中最旧」近似 LRU 代替全表 O(n)
/// 扫描——哈希表桶遍历近似随机，取前 K 条足够给出一个合理旧候选。
const EVICT_SAMPLE_K: usize = 32;

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

        // M6：读路径也触发（有节流的）过期清理——否则存量全是既有会话回访时，
        // 过期条目会无限滞留到 max_sessions 上限。代价受 cleanup_interval_sec 节流。
        self.maybeCleanupLocked();

        // 1. 尝试从 Cookie 获取 session_id
        if (ctx.request.getCookie(self.config.cookie_name)) |session_id| {
            if (self.sessions.getPtr(session_id)) |record| {
                // 单调时钟（.awake）：墙钟（.real）被 NTP 回跳/手工改时间会让
                // session 永不过期（安全问题）或全部立即过期（可用性问题）。
                const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
        // 先尝试清理过期项（节流版，M7：满员时也不能每个请求做 O(n) 全表扫），
        // 再处理上限。
        if (self.sessions.count() >= self.config.max_sessions) {
            self.maybeCleanupLocked();
            // 仍超上限：驱逐采样中最旧的一条（近似 LRU），而不是拒绝新建。
            // 旧实现直接 return error.TooManySessions：匹名请求不带 cookie 时每次都
            // 新建一条 session，攻击者不带 cookie 打满 max_sessions 后，所有人（含
            // 合法登录）都拿到 500，且要等 session_timeout_sec（默认 1 小时）才恢复
            // —— 把限额变成了一个长达 1 小时的完全拒绝服务。LRU 驱逐把“永久 DoS”
            // 降级为“旧 session 被提前注销”。
            if (self.sessions.count() >= self.config.max_sessions) {
                self.evictSampledLocked();
            }
        }

        var random_bytes: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_bytes);

        const session_id = try std.fmt.allocPrint(self.allocator, "sess{X}", .{&random_bytes});
        // 只在所有权移交给 map（put）之前有效；put 成功后正常返回不会触发。
        errdefer self.allocator.free(session_id);

        const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
            const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
    ///
    /// session 不存在时返回 `error.SessionNotFound`。旧实现只 `std.log.warn`
    /// 然后静默返回 —— 调用方无法得知写入是否落地。这不是理论问题：
    /// `examples/src/admin.zig` 登录成功后写 username/role，若 session 在
    /// getOrCreate 与 setData 之间过期，写入被静默丢弃，用户会以「已登录但无角色」
    /// 的状态继续，是一个鉴权缺陷。
    pub fn setData(self: *Self, session_id: []const u8, key: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const record = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;

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

    /// 驱逐最旧会话（近似 LRU）。在 max_sessions 达到上限且没有可清理的过期项时
    /// 调用，避免把限额变成永久拒绝服务。
    ///
    /// M7：旧实现全表 O(n) 扫描找最早 created——满员后每个无 cookie 的请求都在
    /// 全局锁里做一次 O(n)，等于给 DoS 攻击者一个大放大器。改为「采样驱动」：
    /// 哈希表桶遍历的顺序与创建时间无关、近似随机，取前 EVICT_SAMPLE_K 条中的
    /// 最旧者即可给出一个合理的替换候选，代价 O(EVICT_SAMPLE_K)。
    fn evictSampledLocked(self: *Self) void {
        var best_key: ?[]const u8 = null;
        var best_created: i96 = std.math.maxInt(i96);
        var scanned: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.created < best_created) {
                best_created = entry.value_ptr.*.created;
                best_key = entry.key_ptr.*;
            }
            scanned += 1;
            if (scanned >= EVICT_SAMPLE_K) break;
        }
        if (best_key) |key| {
            // deleteSessionLocked 会 free 掉 map 的 key，而我们传的正是 map 内部的
            // key 指针；fetchRemove 会先把 key 所有权移交出来，不会在查找中途失效。
            self.deleteSessionLocked(key);
        }
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
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const interval_ns = @as(i96, self.config.cleanup_interval_sec) * 1_000_000_000;
        if (now - self.last_cleanup < interval_ns) return;
        self.last_cleanup = now;
        self.cleanupExpiredLocked();
    }

    fn cleanupExpiredLocked(self: *Self) void {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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

    /// 轮换会话（M5，防会话固定 Session Fixation）。
    ///
    /// 攻击者可预取一个合法 session ID，诱导受害者带上它登录，之后用同一个
    /// cookie 即可复用已登录会话 —— 前提是登录后框架仍复用原 ID（getOrCreate
    /// 对已存在且未过期的 cookie 原样返回）。
    /// **登录成功 / 改密 / 角色变更后必须调用本函数**：先销毁旧会话（预取的 ID
    /// 立即失效），再签发全新 ID 并覆写 Set-Cookie。
    ///
    /// 返回新 session_id（已拷入 ctx.arena，生命周期随请求）。
    pub fn rotate(self: *Self, ctx: *Context, res: *Response) ![]const u8 {
        if (ctx.request.getCookie(self.config.cookie_name)) |old_id| {
            self.invalidate(old_id);
        }
        return self.getOrCreate(ctx, res);
    }

    pub const Stats = struct {
        total: u32,
        active: u32,
        expired: u32,
    };

    pub fn getStats(self: *Self) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
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
    const now = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
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

    const now = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
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

test "SessionManager.setData on non-existent session reports SessionNotFound" {
    var sm = SessionManager.init(std.testing.allocator, std.testing.io, .{});
    defer sm.deinit();
    // 旧行为是 std.log.warn + 静默返回（调用方无法得知写入丢了，
    // 且在 build runner 的 --listen 协议下这条 stderr 输出会让测试步骤间歇性失败）。
    try std.testing.expectError(error.SessionNotFound, sm.setData("non_existent", "key", "value"));
}

test "SessionManager.getStats with sessions" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io, .{});
    defer sm.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;

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

test "SessionManager.rotate 轮换会话（M5，防会话固定）" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var sm = SessionManager.init(allocator, std.testing.io, .{ .cookie_name = "sid" });
    defer sm.deinit();

    // 构造一个带 sid cookie 的请求：模拟攻击者用浏览器提前拿到的一个合法会话。
    const head = "GET / HTTP/1.1\r\nCookie: sid=attacker_preset\r\n\r\n";
    var request = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var state = RequestState{};
    defer state.deinit(arena_alloc);
    const cfg = RequestConfig{};
    var ctx = Context{
        .request = &request,
        .state = &state,
        .config = &cfg,
        .arena = arena_alloc,
        .io = std.testing.io,
    };

    // 预置攻击者预取的会话（规避 createSessionLocked 的 Set-Cookie 开销）。
    const now = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    _ = try sm.sessions.put(try allocator.dupe(u8, "attacker_preset"), .{
        .id = try allocator.dupe(u8, "attacker_preset"),
        .data = SessionData.init(allocator),
        .expires = now + @as(i96, 3600) * 1_000_000_000,
        .created = now,
    });

    var buf: [256]u8 = undefined;
    var sink_writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&sink_writer));
    defer res.deinit();

    // 登录成功后轮换：旧 ID 应立即失效，新 ID 应覆盖 cookie。
    const new_id = try sm.rotate(&ctx, &res);
    try std.testing.expect(!std.mem.eql(u8, "attacker_preset", new_id));
    try std.testing.expect(sm.sessions.get("attacker_preset") == null);
    try std.testing.expect(sm.sessions.get(new_id) != null);
    // 新 ID 是返回给调用方（登录 handler）去 setData 用的，可继续持有。
    try sm.setData(new_id, "username", "alice");
    const val = (try sm.getValue(new_id, "username", allocator)).?;
    defer allocator.free(val);
    try std.testing.expectEqualStrings("alice", val);
}

test "SessionManager 满员时采样驱逐而非拒绝（M7）" {
    const allocator = std.testing.allocator;
    var sm = SessionManager.init(allocator, std.testing.io, .{
        .max_sessions = 3,
        // cleanup_interval 归零，使 createSessionLocked 内的 maybeCleanupLocked 每次执行，
        // 确保测试脚本可控；随后靠采样驱逐兜底。
        .cleanup_interval_sec = 0,
        .session_timeout_sec = 3600,
    });
    defer sm.deinit();

    const now = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    for ([_][]const u8{ "a", "b", "c" }) |id| {
        _ = try sm.sessions.put(try allocator.dupe(u8, id), .{
            .id = try allocator.dupe(u8, id),
            .data = SessionData.init(allocator),
            .expires = now + @as(i96, 3600) * 1_000_000_000,
            .created = now,
        });
    }

    // 无 cookie 请求：满员不报错，而是驱逐一条后成功创建。
    const head = "GET / HTTP/1.1\r\n\r\n";
    var request = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var state = RequestState{};
    defer state.deinit(allocator);
    const cfg = RequestConfig{};
    var ctx = Context{
        .request = &request,
        .state = &state,
        .config = &cfg,
        .arena = allocator,
        .io = std.testing.io,
    };

    var buf: [256]u8 = undefined;
    var sink_writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, @import("http_protocol").Sink.testSink(&sink_writer));
    defer res.deinit();

    const new_id = try sm.getOrCreate(&ctx, &res);
    // getOrCreate 把结果拷进了 ctx.arena；本测试 arena 直接用 std.testing.allocator，
    // 需手动释放这个 dup。
    defer allocator.free(new_id);
    try std.testing.expectEqual(@as(usize, 3), sm.sessions.count());
    try std.testing.expect(sm.sessions.get(new_id) != null);
}

test {
    std.testing.refAllDecls(@This());
}
