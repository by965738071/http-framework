//! 请求上下文
//!
//! 封装 HTTP 请求信息，支持按需延迟解析以减少不必要的内存分配。
//!
//! # 设计说明
//!
//! - 请求头：`getHeader` 线性扫描原始头部，零分配、不缓存。
//! - 查询参数：`getQuery` 首次调用时全量解析并缓存到 HashMap
//!   （key 直接引用请求缓冲区，零复制；value 为自有内存，统一释放）。
//! - 表单参数：`getForm` 与 `getQuery` 行为一致（URL 解码 + 缓存）。
//! - 路径参数：`path_params` 由路由分发写入（key/value 均为自有内存）。

const std = @import("std");
const http = std.http;
const mem = std.mem;

/// 用户数据槽位 — 按类型索引的不透明指针 + 销毁函数。
///
/// # 为什么是链表而不是单个字段
///
/// 早期版本 `user_data` 是**一个**槽位，`setUserData` 直接覆盖：
///
/// ```zig
/// self.user_data = .{ .ptr = data, .destroyFn = destroyFn };
/// ```
///
/// 于是两个中间件谁都不能同时用它——鉴权中间件写入 AuthInfo，
/// 会话中间件随后写入 Session，前者的 `destroyFn` 永远不会被调用（泄漏），
/// 而下游 `getUserData(AuthInfo)` 会把 Session 指针**当成 AuthInfo 返回**
/// （类型混淆，比泄漏更糟）。中间件链一旦超过一个消费者就是错的。
///
/// 现在按 `@typeName(T)` 索引，每个类型一个槽位，互不干扰。
/// 用单链表而不是 HashMap：实际槽位数是个位数，链表省掉哈希表的
/// 初始化分配，遍历也在缓存里。
pub const UserData = struct {
    /// `@typeName(T)`。同一个 T 在任何地方求值都得到相等的字符串。
    key: []const u8,
    ptr: *anyopaque,
    destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    next: ?*UserData = null,
};

allocator: std.mem.Allocator,
io: std.Io,

// ---- 基本信息 ----
method: http.Method,
path: []const u8,
query: []const u8,
version: http.Version,

// ---- 路径参数 — 必须用 HashMap（路由批量写入） ----
path_params: std.StringHashMapUnmanaged([]const u8),

// ---- 查询参数缓存（延迟初始化的 HashMap） ----
// key 引用请求缓冲区（零复制），value 为自有内存
query_params: ?std.StringHashMapUnmanaged([]const u8) = null,

// ---- 表单参数缓存（延迟初始化，key/value 均为自有内存） ----
form_params: ?std.StringHashMapUnmanaged([]const u8) = null,

// ---- 请求体 ----
content_type: ?[]const u8,
content_length: ?u64,
transfer_encoding: http.TransferEncoding,

// ---- 原始请求引用 ----
request: *http.Server.Request,

/// 请求头原始字节的自有副本，`null` 表示直接引用 `request.head_buffer`。
///
/// # 为什么需要这个副本
///
/// `request.head_buffer` 是**连接读缓冲区的一段切片**，std 明确写了
/// "invalidated by any subsequent consumption of the input stream"——
/// 一旦开始读 body，body 字节就会覆盖掉它。实测 64KiB 的 POST 之后
/// `ctx.path` 会变成 `"bbbbbb"`（body 的内容），而访问日志恰恰是在
/// handler 跑完之后才打印 `ctx.path`。
///
/// 所以带 body 的请求在 `init` 时就把 head 复制到请求 arena，
/// `path` / `query` / `content_type` 全部改指向副本。不带 body 的请求
/// （绝大多数 GET/HEAD）没有覆盖风险，保持零拷贝。
head_copy: ?[]const u8 = null,

// ---- 内部状态 ----
body_read: bool,
body_data: ?[]const u8,

/// 已通过 `bodyStream()` 接管 body 读取。与 `body_read` 互斥。
body_streaming: bool = false,

/// 请求体大小限制（字节），0 表示不限制
body_size_limit: u64 = 0,

/// 超过此值的请求体不再整体缓冲，`readBody()` 直接报错要求改用
/// `bodyStream()`。0 表示不启用。由 Server 从 `config.lazy_read_size` 注入。
lazy_read_size: u64 = 0,

// ---- 延迟解析标志 ----
headers_parsed: bool,

// ---- 用户数据（中间件传递），按类型索引的单链表 ----
user_data: ?*UserData = null,

// ---- 中间件拦截状态码 ----
blocked_status: ?http.Status = null,

// ---- websocket ----
is_websocket: bool = false,

/// 是否信任代理头（X-Forwarded-For / X-Real-IP）。
/// 由 Server 从 config.trust_proxy_headers 注入；默认 false（防伪造）。
trust_proxy: bool = false,

/// 匹配到的路由模式（由 Router 设置，用于 metrics 标签，避免高基数原始路径）
route_pattern: ?[]const u8 = null,

/// 请求体读取失败标记：socket 上可能残留未消费的字节，
/// keep-alive 连接不可复用，Server 在响应后必须关闭连接。
poisoned: bool = false,

const Self = @This();

/// 请求体流式读取器。
/// 提供对已缓冲请求体的增量读取接口，避免调用方直接操作原始 buffer。
/// reader 在请求体末尾返回 0（表示 EndOfStream）。
pub const BodyReader = struct {
    data: []const u8,
    pos: usize,

    /// 读取最多 buf.len 个字节。返回实际读取的字节数。
    /// 到达请求体末尾时返回 0。
    pub fn read(b: *BodyReader, buf: []u8) !usize {
        const remaining = b.data.len - b.pos;
        const n = @min(buf.len, remaining);
        if (n == 0) return 0;
        @memcpy(buf[0..n], b.data[b.pos .. b.pos + n]);
        b.pos += n;
        return n;
    }
};

// =========================================================================
// 初始化与清理
// =========================================================================

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *http.Server.Request,
) !Self {
    const head = request.head;

    // 从 target 中分离 path 和 query string
    const target = head.target;
    const query_start = mem.indexOfScalar(u8, target, '?');
    var path = if (query_start) |idx| target[0..idx] else target;
    var query = if (query_start) |idx| target[idx + 1 ..] else "";
    var content_type = head.content_type;

    // 只有「会去读 body」的请求才需要保护 head：读 body 会把 head 冲掉。
    // 无 body 的请求走零拷贝路径。
    const has_body = head.content_length != null or head.transfer_encoding != .none;
    const original_head = request.head_buffer;
    var head_copy: ?[]const u8 = null;
    if (has_body) {
        const copy = try allocator.dupe(u8, original_head);
        head_copy = copy;
        path = rebase(path, original_head, copy);
        query = rebase(query, original_head, copy);
        if (content_type) |ct| content_type = rebase(ct, original_head, copy);
    }

    return Self{
        .allocator = allocator,
        .io = io,
        .method = head.method,
        .path = path,
        .query = query,
        .version = head.version,
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = content_type,
        .content_length = head.content_length,
        .transfer_encoding = head.transfer_encoding,
        .request = request,
        .head_copy = head_copy,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
}

/// 把 `old` 里的一段切片平移到 `new`（两者内容相同、长度相同）。
/// 不落在 `old` 范围内的切片（例如空字符串字面量）原样返回。
fn rebase(slice: []const u8, old: []const u8, new: []const u8) []const u8 {
    const s = @intFromPtr(slice.ptr);
    const base = @intFromPtr(old.ptr);
    if (s < base or s + slice.len > base + old.len) return slice;
    return new[s - base ..][0..slice.len];
}

/// 释放所有堆分配的资源
pub fn deinit(self: *Self) void {
    // 释放查询参数缓存（key 是请求缓冲区的引用，只释放 value）
    if (self.query_params) |*qp| {
        freeValuesOnly(qp, self.allocator);
    }

    // 释放表单参数缓存（key/value 均为自有内存）
    if (self.form_params) |*fp| {
        freeHashMap(fp, self.allocator);
    }

    // 只有 path_params 一定需要释放
    freeHashMap(&self.path_params, self.allocator);

    // 释放 body 数据
    if (self.body_data) |data| {
        self.allocator.free(data);
    }

    // 释放 head 副本（零拷贝路径下为 null，没有东西要还）
    if (self.head_copy) |copy| {
        self.allocator.free(copy);
    }

    // 逐个调用注册的销毁函数。链表本身也是 self.allocator 分配的，
    // 顺带释放——用 arena 时这两次 free 都是 no-op，用通用分配器时才真正生效。
    var node = self.user_data;
    self.user_data = null;
    while (node) |ud| {
        const next = ud.next;
        ud.destroyFn(ud.ptr, self.allocator);
        self.allocator.destroy(ud);
        node = next;
    }
}

// =========================================================================
// 请求头访问（延迟线性扫描）
// =========================================================================

/// 获取请求头值（大小写不敏感）。
///
/// 线性扫描原始头部数据，不缓存、不分配。读过 body 之后依然可用。
pub fn getHeader(self: *const Self, key: []const u8) ?[]const u8 {
    var it = self.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, key)) {
            return header.value;
        }
    }
    return null;
}

// =========================================================================
// Query 参数访问（延迟线性扫描）
// =========================================================================

/// 获取查询参数值。
///
/// 首次调用时全量解析 query string 并缓存到 HashMap 中，
/// 后续所有 `getQuery()` 调用均为 O(1) 查询。
/// key 直接引用请求缓冲区（零复制）；value 为解码后的自有内存，
/// 在请求上下文 deinit 时统一释放。
///
/// 返回的 slice 在请求上下文的生命周期内有效。
pub fn getQuery(self: *Self, key: []const u8) ?[]const u8 {
    if (self.query.len == 0) return null;

    // 延迟初始化查询参数缓存
    if (self.query_params == null) {
        self.query_params = std.StringHashMapUnmanaged([]const u8).empty;
        var pairs = mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;

            // key 引用 query 缓冲区（与请求同生命周期），无需复制
            const eq_idx = mem.indexOfScalar(u8, pair, '=');
            const k = if (eq_idx) |idx| pair[0..idx] else pair;
            const raw_v = if (eq_idx) |idx| pair[idx + 1 ..] else "";

            // value 统一为自有内存（解码或复制），deinit 时统一释放
            const value = if (mem.indexOfAny(u8, raw_v, "%+") != null)
                (urlDecode(self.allocator, raw_v) catch continue)
            else
                (self.allocator.dupe(u8, raw_v) catch continue);

            // 重复 key（?a=1&a=2）时保持「后者覆盖」语义，但必须先释放
            // 被覆盖的旧 value——直接 put 会把它泄漏掉。
            const gop = self.query_params.?.getOrPut(self.allocator, k) catch {
                self.allocator.free(value);
                continue;
            };
            if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value;
        }
    }

    return self.query_params.?.get(key);
}

// =========================================================================
// Cookie 访问（延迟线性扫描）
// =========================================================================

/// 获取 Cookie 值。
///
/// 首次调用时在线解析 Cookie 头，不缓存、不分配。
pub fn getCookie(self: *const Self, key: []const u8) ?[]const u8 {
    // 利用 getHeader 惰性扫描 headers
    const cookie_header = self.getHeader("Cookie") orelse return null;

    var pairs = mem.splitScalar(u8, cookie_header, ';');
    while (pairs.next()) |pair| {
        const trimmed = mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, trimmed, '=');
        if (eq_idx) |idx| {
            if (mem.eql(u8, trimmed[0..idx], key)) {
                return trimmed[idx + 1 ..];
            }
        }
    }
    return null;
}

// =========================================================================
// 路径参数
// =========================================================================

/// 获取路径参数值（如 `/users/:id` 中的 `id`）。
///
/// 路径参数由路由分发时写入 HashMap，此处直接 O(1) 查询。
pub fn getParam(self: *const Self, key: []const u8) ?[]const u8 {
    return self.path_params.get(key);
}

// =========================================================================
// 兼容方法（保留 API 但移除了内部 HashMap）
// =========================================================================

/// 获取所有请求头（不常用 API，仍返回迭代器）。
/// 注意：每次调用都会重新扫描，不做缓存。
///
/// 扫描的是 `headBytes()` 而不是 `request.iterateHeaders()`——后者断言
/// `reader.state == .received_head`，读过 body 之后调用会直接崩掉进程。
pub fn iterateHeaders(self: *const Self) http.HeaderIterator {
    return http.HeaderIterator.init(self.headBytes());
}

/// 请求头原始字节：有副本用副本，没有就直接引用连接缓冲区。
fn headBytes(self: *const Self) []const u8 {
    return self.head_copy orelse self.request.head_buffer;
}

// =========================================================================
// 请求体读取
// =========================================================================

/// 读取请求体（支持 `Content-Length` 和 `Transfer-Encoding: chunked`）。
///
/// 幂等方法：多次调用返回相同数据，仅首次实际读取。
///
/// 注意：读取失败（如 BodyTooLarge、连接中断）会将连接标记为 poisoned，
/// Server 会在响应后关闭连接——因为 socket 上可能残留未消费的字节，
/// 继续复用会把残余 body 误认为下一个请求的头部。
///
/// 配了 `lazy_read_size` 且 `Content-Length` 超过它时返回
/// `error.BodyTooLargeToBuffer`，此时**一个字节都还没读**，
/// 调用方可以改用 `bodyStream()` 边收边处理。
///
/// 请求带 `Expect: 100-continue` 时会先回一句 `100 Continue` 再读
/// （客户端正等着这个才肯发 body）。头里写了别的 expect 值则返回
/// `error.HttpExpectationFailed`，Server 映射成 417。
pub fn readBody(self: *Self) ![]const u8 {
    if (self.body_read) {
        return self.body_data orelse error.BodyAlreadyRead;
    }
    if (self.body_streaming) return error.BodyIsStreaming;

    // ---- 预检查：此时 socket 还没被动过 ----
    // 这几个分支要不要 poison 得分开判断，所以不能套在下面那个
    // 统一的 errdefer 里。

    // 超过硬上限 → 413。客户端此刻还在往 socket 里灌 body，
    // 我们不打算读它，连接只能关掉。
    if (self.body_size_limit > 0) {
        if (self.content_length) |cl| {
            if (cl > self.body_size_limit) {
                self.poisoned = true;
                return error.BodyTooLarge;
            }
        }
    }

    // 超过缓冲阈值 → 提示调用方改用流式。**不 poison**：
    // handler 完全可以接着调 bodyStream() 把它读完，连接仍可复用。
    if (self.lazy_read_size > 0) {
        if (self.content_length) |cl| {
            if (cl > self.lazy_read_size) return error.BodyTooLargeToBuffer;
        }
    }

    // 没有 Content-Length 且没有 Transfer-Encoding 的请求没有 body，直接返回空
    if (self.content_length == null and self.transfer_encoding == .none) {
        self.body_read = true;
        self.body_data = &.{};
        return &.{};
    }

    // 此后任何错误都意味着 socket 上的 body 未被完整消费 → 连接不可复用
    errdefer self.poisoned = true;

    var temp_buf: [16384]u8 = undefined;
    const body_reader = try self.request.readerExpectContinue(&temp_buf);

    var result = try std.ArrayList(u8).initCapacity(self.allocator, 256);
    // BodyTooLarge / 读错误都会在这里退出，累积缓冲区必须回收，
    // 否则攻击者可以用重复的超大请求把内存打爆。
    errdefer result.deinit(self.allocator);

    var total_read: u64 = 0;
    var chunk_buf: [16384]u8 = undefined;
    while (true) {
        const n = try body_reader.readSliceShort(&chunk_buf);
        if (n == 0) break;

        total_read += n;
        if (self.body_size_limit > 0 and total_read > self.body_size_limit) {
            return error.BodyTooLarge;
        }

        try result.appendSlice(self.allocator, chunk_buf[0..n]);
    }

    self.body_read = true;
    self.body_data = try result.toOwnedSlice(self.allocator);

    return self.body_data.?;
}

/// 流式读取请求体：直接从连接上增量读，**不整体进内存**。
///
/// 这是 `readBody()` 的替代品，用于大上传（转存文件、边收边算哈希、
/// 边收边转发）。`readBody()` 会把整个 body 攒进内存，10GB 的上传就是
/// 10GB 的堆；`bodyStream()` 的内存占用只有 `buffer` 本身。
///
/// # 用法
///
/// ```zig
/// var buf: [64 * 1024]u8 = undefined;
/// const reader = try ctx.bodyStream(&buf);
/// var hasher = std.crypto.hash.sha2.Sha256.init(.{});
/// var chunk: [8192]u8 = undefined;
/// while (true) {
///     const n = try reader.readSliceShort(&chunk);
///     if (n == 0) break;
///     hasher.update(chunk[0..n]);
/// }
/// ```
///
/// # 契约
///
/// - `buffer` 的生命周期必须覆盖整个读取过程（栈数组可以，但别让它先出作用域）。
/// - 与 `readBody()` 互斥，且自身只能调用一次；违反返回 `error.BodyAlreadyRead`
///   / `error.BodyIsStreaming`（std 那边是 `assert`，直接崩，所以这里挡在前面）。
/// - **应当读到 EOF**（`readSliceShort` 返回 0）。没读完不会崩，但 socket 上
///   会残留本请求的 body 字节，框架只能关掉这条连接（丢掉 keep-alive 复用）
///   来避免残余字节被当成下一个请求的头部。
///
/// 与 `readBody()` 一样会处理 `Expect: 100-continue`。用的是
/// `readerExpectContinue` 而不是 `readerExpectNone`——后者
/// `assert(head.expect == null)`，而 curl 上传大文件时默认就会带这个头，
/// 等于任何人都能用一条 `curl --data-binary @bigfile` 把进程打崩。
pub fn bodyStream(self: *Self, buffer: []u8) !*std.Io.Reader {
    if (self.body_read) return error.BodyAlreadyRead;
    if (self.body_streaming) return error.BodyIsStreaming;
    self.body_streaming = true;
    return self.request.readerExpectContinue(buffer);
}

/// 本请求的 body 是否已从连接上完整消费干净。
///
/// 只在 `bodyStream()` 之后才有判断意义：Server 用它决定还能不能复用连接。
pub fn bodyDrained(self: *const Self) bool {
    return switch (self.request.server.reader.state) {
        .ready => true,
        else => false,
    };
}

/// 返回一个 reader，用于增量读取已缓冲的请求体数据。
///
/// 注意：这不是真正的流式读取——它读取的是 `readBody()` 已缓冲到内存的数据，
/// 因此需要先调用 `readBody()`。真正的流式（边收边处理）请用 `bodyStream()`。
pub fn bodyReader(self: *const Self) BodyReader {
    return .{
        .data = self.body_data orelse "",
        .pos = 0,
    };
}

// =========================================================================
// 用户数据（中间件传递）
// =========================================================================

/// 存入用户自定义数据，按 `data` 的指向类型索引。
///
/// 槽位是**按类型**的：鉴权中间件存 `*AuthInfo`、会话中间件存 `*SessionData`，
/// 两者互不覆盖，下游各取各的。同一个类型重复 set 才算覆盖——
/// 此时旧值的 `destroyFn` 会被立即调用，不会泄漏。
///
/// `data` 必须用 `ctx.allocator` 分配：`destroyFn` 收到的正是这个分配器。
/// （用别的分配器 create、却让框架拿 `ctx.allocator` 去 destroy，
///   是一个安静到几乎发现不了的错配。）
///
/// `destroyFn` 负责释放 data 自身及其持有的所有资源，
/// 框架在 `Self.deinit()` 时自动调用。
///
/// # 使用示例
/// ```zig
/// fn destroyMyData(ptr: *anyopaque, allocator: std.mem.Allocator) void {
///     const data: *MyData = @ptrCast(@alignCast(ptr));
///     allocator.free(data.name);
///     allocator.destroy(data);
/// }
/// const my_data = try ctx.allocator.create(MyData);
/// my_data.* = .{ .name = try ctx.allocator.dupe(u8, "x") };
/// try ctx.setUserData(my_data, destroyMyData);
/// ```
pub fn setUserData(
    self: *Self,
    data: anytype,
    destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
) !void {
    const Ptr = @typeInfo(@TypeOf(data));
    if (Ptr != .pointer or Ptr.pointer.size != .one) {
        @compileError("setUserData 需要一个单项指针 `*T`，收到的是 " ++ @typeName(@TypeOf(data)));
    }
    const T = Ptr.pointer.child;
    // 拦住旧的 `ctx.setUserData(@ptrCast(p), ...)` 写法：`*anyopaque` 能编过，
    // 但所有类型都会挤进 "anyopaque" 这一个 key，等于把刚修好的多槽又退化成单槽。
    if (T == anyopaque) {
        @compileError("setUserData 不接受 *anyopaque——请直接传 *T，槽位要靠类型来分");
    }
    const key = @typeName(T);

    // 同类型已存在 → 就地替换，先把旧值销毁掉
    var node = self.user_data;
    while (node) |ud| : (node = ud.next) {
        if (!mem.eql(u8, ud.key, key)) continue;
        ud.destroyFn(ud.ptr, self.allocator);
        ud.ptr = @ptrCast(data);
        ud.destroyFn = destroyFn;
        return;
    }

    const ud = try self.allocator.create(UserData);
    ud.* = .{
        .key = key,
        .ptr = @ptrCast(data),
        .destroyFn = destroyFn,
        .next = self.user_data,
    };
    self.user_data = ud;
}

/// 取出此前用 `setUserData` 存入的 `*T`，没有则返回 null。
///
/// 按 `@typeName(T)` 精确匹配：取错类型只会得到 null，
/// 不会像从前那样把别人的指针强转成 T 返回。
pub fn getUserData(self: *const Self, comptime T: type) ?*T {
    const key = @typeName(T);
    var node = self.user_data;
    while (node) |ud| : (node = ud.next) {
        if (mem.eql(u8, ud.key, key)) return @ptrCast(@alignCast(ud.ptr));
    }
    return null;
}

// =========================================================================
// 实用方法
// =========================================================================

/// 检查是否为 AJAX 请求（通过 X-Requested-With 头）
pub fn isAjax(self: *const Self) bool {
    const header = self.getHeader("X-Requested-With") orelse return false;
    return std.ascii.eqlIgnoreCase(header, "XMLHttpRequest");
}

/// 获取客户端 IP 地址。
///
/// 仅当 `trust_proxy = true`（由 Server 从 config.trust_proxy_headers 注入）
/// 时才解析 X-Forwarded-For / X-Real-IP 代理头——直连部署下这些头可被
/// 客户端任意伪造，默认不信任。
/// 无法确定（未启用代理信任或 std API 暂不支持取对端地址）时返回 null。
pub fn getClientIp(self: *const Self) ?[]const u8 {
    if (!self.trust_proxy) return null;

    // 尝试从常见代理头获取
    if (self.getHeader("X-Forwarded-For")) |header| {
        // X-Forwarded-For: client, proxy1, proxy2
        var it = mem.splitScalar(u8, header, ',');
        if (it.buffer.len > 0) {
            return mem.trim(u8, it.first(), " ");
        }
    }
    if (self.getHeader("X-Real-IP")) |ip| {
        return ip;
    }
    // 注意：从 std.http.Server.Request 获取直接连接 IP 需要更低层 API
    // 当前返回 null，由上层处理
    return null;
}

/// 检查请求是否包含特定 Content-Type
pub fn hasContentType(self: *const Self, expected: []const u8) bool {
    const ct = self.content_type orelse return false;
    return std.ascii.eqlIgnoreCase(ct, expected);
}

/// Case-insensitive contains check for ASCII strings.
fn ciContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// 检查是否为 JSON 请求
pub fn isJson(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return ciContains(ct, "application/json");
}

/// 检查是否为表单请求
pub fn isForm(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return ciContains(ct, "application/x-www-form-urlencoded");
}

/// 检查是否为 multipart 表单请求
pub fn isMultipartForm(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return ciContains(ct, "multipart/form-data");
}

// =========================================================================
// Form 参数（延迟解析，不缓存）
// =========================================================================

/// 获取表单字段值（application/x-www-form-urlencoded）。
///
/// 首次调用时读取请求体并全量解析（URL 解码 key 和 value），
/// 缓存到 HashMap，后续调用为 O(1) 查询。与 `getQuery` 行为一致。
///
/// 返回的 slice 在请求上下文的生命周期内有效。
pub fn getForm(self: *Self, key: []const u8) ?[]const u8 {
    if (self.form_params == null) {
        const body = self.readBody() catch return null;
        self.form_params = std.StringHashMapUnmanaged([]const u8).empty;

        var pairs = mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;

            const eq_idx = mem.indexOfScalar(u8, pair, '=');
            const raw_k = if (eq_idx) |idx| pair[0..idx] else pair;
            const raw_v = if (eq_idx) |idx| pair[idx + 1 ..] else "";

            // key/value 都做 URL 解码并持有自有内存
            const k = urlDecode(self.allocator, raw_k) catch continue;
            const v = urlDecode(self.allocator, raw_v) catch {
                self.allocator.free(k);
                continue;
            };

            // 重复 key 时 put 会保留旧 key、替换 value，于是新 key 和旧 value
            // 都成了没人释放的孤儿。用 getOrPut 显式处理这两块内存。
            const gop = self.form_params.?.getOrPut(self.allocator, k) catch {
                self.allocator.free(k);
                self.allocator.free(v);
                continue;
            };
            if (gop.found_existing) {
                self.allocator.free(k); // map 里已有等值的 key，这份多余
                self.allocator.free(gop.value_ptr.*); // 被覆盖的旧 value
            }
            gop.value_ptr.* = v;
        }
    }

    return self.form_params.?.get(key);
}

// =========================================================================
// 内部工具函数
// =========================================================================

/// 释放 `StringHashMapUnmanaged` 中所有堆分配的 key 和 value
pub fn freeHashMap(map: *std.StringHashMapUnmanaged([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}

/// 只释放 `StringHashMapUnmanaged` 中的 value（key 为外部缓冲区的引用，不释放）
fn freeValuesOnly(map: *std.StringHashMapUnmanaged([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}

/// 对 URL 编码的字符串进行百分比解码。
///
/// 将 `%XX` 序列解码为对应字节，将 `+` 解码为空格。
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 64);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '%' => {
                if (i + 2 < input.len) {
                    const hex = input[i + 1 .. i + 3];
                    const val = std.fmt.parseInt(u8, hex, 16) catch {
                        try result.append(allocator, input[i]);
                        continue;
                    };
                    try result.append(allocator, val);
                    i += 2;
                } else {
                    try result.append(allocator, input[i]);
                }
            },
            '+' => {
                try result.append(allocator, ' ');
            },
            else => {
                try result.append(allocator, input[i]);
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

// =========================================================================
// 测试
// =========================================================================

/// 用户数据测试类型。必须在文件作用域声明：Zig 里两处分别写出的匿名
/// `struct { value: u32 }` 是**两个不同的类型**，`@typeName` 也不同，
/// 写在测试函数里会让 set / get 落到不同的槽位上。
const TestUserData = struct { value: u32 };
const TestOtherData = struct { name: []const u8 };

/// 测试用的 `http.Server.Request` 载体。
///
/// 必须就地初始化：`req.server` 指向同结构里的 `server` 字段，
/// 按值返回会让这个指针指向已经消失的栈帧。
const TestRequest = struct {
    server: std.http.Server,
    req: std.http.Server.Request,

    fn init(self: *TestRequest, request_bytes: []const u8) !void {
        self.server = .{
            .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
            .out = undefined,
        };
        self.req = .{
            .server = &self.server,
            .head = try std.http.Server.Request.Head.parse(request_bytes),
            .head_buffer = request_bytes,
        };
    }
};

fn testDestroyMyData(ptr: *anyopaque, a: std.mem.Allocator) void {
    const data: *TestUserData = @ptrCast(@alignCast(ptr));
    a.destroy(data);
}

fn testDestroyOtherData(ptr: *anyopaque, a: std.mem.Allocator) void {
    const data: *TestOtherData = @ptrCast(@alignCast(ptr));
    a.free(data.name);
    a.destroy(data);
}

test "urlDecode - basic" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "hello+world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode - percent encoding" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "foo%2Fbar%3Dbaz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("foo/bar=baz", result);
}

test "urlDecode - mixed" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "hello%20world+foo%26bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world foo&bar", result);
}

test "urlDecode - no encoding" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "plain");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain", result);
}

test "BodyReader read full body" {
    const data = "Hello, World! This is a test body.";
    var reader = BodyReader{ .data = data, .pos = 0 };

    var buf: [64]u8 = undefined;
    const n = try reader.read(&buf);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, buf[0..n]);

    // Subsequent read should return 0
    const n2 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n2);
}

test "BodyReader incremental read" {
    const data = "ABCDEFGHIJ";
    var reader = BodyReader{ .data = data, .pos = 0 };

    var buf: [3]u8 = undefined;

    const n1 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n1);
    try std.testing.expectEqualStrings("ABC", buf[0..n1]);

    const n2 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n2);
    try std.testing.expectEqualStrings("DEF", buf[0..n2]);

    const n3 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n3);
    try std.testing.expectEqualStrings("GHI", buf[0..n3]);

    const n4 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 1), n4);
    try std.testing.expectEqualStrings("J", buf[0..n4]);

    const n5 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n5);
}

test "BodyReader empty body" {
    var reader = BodyReader{ .data = "", .pos = 0 };

    var buf: [16]u8 = undefined;
    const n = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "BodyReader larger buffer than remaining" {
    const data = "Hi";
    var reader = BodyReader{ .data = data, .pos = 0 };

    var buf: [1024]u8 = undefined;
    const n = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Hi", buf[0..n]);
}

test "Self.init - parses path and query" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /search?q=hello&page=1 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{
            .in = undefined,
            .state = .received_head,
            .interface = undefined,
            .max_head_len = 4096,
        },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("/search", ctx.path);
    try std.testing.expectEqualStrings("q=hello&page=1", ctx.query);
    try std.testing.expectEqual(.GET, ctx.method);
}

test "Self.init - no query string" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /static/file.html HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("/static/file.html", ctx.path);
    try std.testing.expectEqualStrings("", ctx.query);
}

test "Self.getHeader - basic lookup" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Custom: custom-value\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("example.com", ctx.getHeader("Host").?);
    try std.testing.expectEqualStrings("custom-value", ctx.getHeader("X-Custom").?);
    try std.testing.expect(ctx.getHeader("NonExistent") == null);
}

test "Self.getHeader - case insensitive" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "CONTENT-TYPE: application/json\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("application/json", ctx.getHeader("content-type").?);
    try std.testing.expectEqualStrings("application/json", ctx.getHeader("Content-Type").?);
}

test "Self.getQuery - multiple params" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /api?name=John&age=30&city=NYC HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("John", ctx.getQuery("name").?);
    try std.testing.expectEqualStrings("30", ctx.getQuery("age").?);
    try std.testing.expectEqualStrings("NYC", ctx.getQuery("city").?);
    try std.testing.expect(ctx.getQuery("missing") == null);
}

test "Self.getQuery - duplicate keys keep last value without leaking" {
    // testing.allocator 会在 deinit 后报告泄漏：
    // 旧实现用 put 覆盖 value，被覆盖的那份永远没人释放。
    const allocator = std.testing.allocator;
    const request_bytes = "GET /api?a=1&a=2&a=3 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("3", ctx.getQuery("a").?);
    try std.testing.expectEqual(@as(usize, 1), ctx.query_params.?.count());
}

test "Self.getQuery - url encoded" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /api?q=hello+world&lang=zh%2Fcn HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // Query params are URL-decoded by getQuery
    try std.testing.expectEqualStrings("hello world", ctx.getQuery("q").?);
    try std.testing.expectEqualStrings("zh/cn", ctx.getQuery("lang").?);
}

test "Self.getCookie - single cookie" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Cookie: session=abc123\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("abc123", ctx.getCookie("session").?);
    try std.testing.expect(ctx.getCookie("nonexistent") == null);
}

test "Self.getCookie - multiple cookies" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Cookie: session=abc123; theme=dark; lang=en-US\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("abc123", ctx.getCookie("session").?);
    try std.testing.expectEqualStrings("dark", ctx.getCookie("theme").?);
    try std.testing.expectEqualStrings("en-US", ctx.getCookie("lang").?);
}

test "Self.isAjax - X-Requested-With" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /api HTTP/1.1\r\n" ++
        "X-Requested-With: XMLHttpRequest\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expect(ctx.isAjax());
}

test "Self.isAjax - not ajax" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /page HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expect(!ctx.isAjax());
}

test "Self.getClientIp - X-Forwarded-For" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "X-Forwarded-For: 192.168.1.1, 10.0.0.1\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();
    ctx.trust_proxy = true;

    // Should return the first IP in the list
    try std.testing.expectEqualStrings("192.168.1.1", ctx.getClientIp().?);
}

test "Self.getClientIp - X-Real-IP" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "X-Real-IP: 10.0.0.5\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();
    ctx.trust_proxy = true;

    try std.testing.expectEqualStrings("10.0.0.5", ctx.getClientIp().?);
}

test "Self.getClientIp - no IP headers" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expect(ctx.getClientIp() == null);
}

test "Self.getClientIp - proxy headers ignored when not trusted" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "X-Forwarded-For: 1.2.3.4\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // 默认 trust_proxy = false：XFF 头被忽略（防伪造）
    try std.testing.expect(ctx.getClientIp() == null);
}

test "Self.readBody - GET request returns empty" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // GET requests have no body, readBody should return empty slice
    const body = try ctx.readBody();
    try std.testing.expectEqual(@as(usize, 0), body.len);
}

test "Self.userData - set and get" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    const my_data = try allocator.create(TestUserData);
    my_data.* = .{ .value = 42 };

    try ctx.setUserData(my_data, testDestroyMyData);

    const retrieved = ctx.getUserData(TestUserData);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.value);
}

test "userData: 两个中间件写入不同类型时互不覆盖" {
    const allocator = std.testing.allocator;
    var req_holder: TestRequest = undefined;
    try req_holder.init("GET /test HTTP/1.1\r\n\r\n");
    var ctx = try Self.init(allocator, std.testing.io, &req_holder.req);
    defer ctx.deinit();

    // 中间件 A（比如鉴权）
    const a = try allocator.create(TestUserData);
    a.* = .{ .value = 7 };
    try ctx.setUserData(a, testDestroyMyData);

    // 中间件 B（比如会话）——从前这一步会把 A 的槽位直接盖掉
    const b = try allocator.create(TestOtherData);
    b.* = .{ .name = try allocator.dupe(u8, "session-abc") };
    try ctx.setUserData(b, testDestroyOtherData);

    // 两者都还在，且各自拿到的是自己的类型
    try std.testing.expectEqual(@as(u32, 7), ctx.getUserData(TestUserData).?.value);
    try std.testing.expectEqualStrings("session-abc", ctx.getUserData(TestOtherData).?.name);
    // deinit 会调用两个 destroyFn；漏掉任何一个，testing.allocator 都会报泄漏
}

test "userData: 取未存入的类型返回 null，而不是别人的指针" {
    const allocator = std.testing.allocator;
    var req_holder: TestRequest = undefined;
    try req_holder.init("GET /test HTTP/1.1\r\n\r\n");
    var ctx = try Self.init(allocator, std.testing.io, &req_holder.req);
    defer ctx.deinit();

    const a = try allocator.create(TestUserData);
    a.* = .{ .value = 1 };
    try ctx.setUserData(a, testDestroyMyData);

    // 从前这里会把 *TestUserData 强转成 *TestOtherData 返回（类型混淆）
    try std.testing.expectEqual(@as(?*TestOtherData, null), ctx.getUserData(TestOtherData));
}

test "userData: 同类型重复写入会销毁旧值而不是泄漏" {
    const allocator = std.testing.allocator;
    var req_holder: TestRequest = undefined;
    try req_holder.init("GET /test HTTP/1.1\r\n\r\n");
    var ctx = try Self.init(allocator, std.testing.io, &req_holder.req);
    defer ctx.deinit();

    const first = try allocator.create(TestUserData);
    first.* = .{ .value = 1 };
    try ctx.setUserData(first, testDestroyMyData);

    const second = try allocator.create(TestUserData);
    second.* = .{ .value = 2 };
    try ctx.setUserData(second, testDestroyMyData); // first 在此被销毁

    try std.testing.expectEqual(@as(u32, 2), ctx.getUserData(TestUserData).?.value);
}

test "Self.blocked_status - set and get" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /test HTTP/1.1\r\n\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expect(ctx.blocked_status == null);

    ctx.blocked_status = .too_many_requests;
    try std.testing.expectEqual(.too_many_requests, ctx.blocked_status.?);

    ctx.blocked_status = null;
    try std.testing.expect(ctx.blocked_status == null);
}

test "Self.getParam - path parameters" {
    const allocator = std.testing.allocator;
    const request_bytes = "GET /users/42 HTTP/1.1\r\n\r\n";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    // No params set yet
    try std.testing.expect(ctx.getParam("id") == null);

    // Set path params manually
    const key = try allocator.dupe(u8, "id");
    const val = try allocator.dupe(u8, "42");
    ctx.path_params.put(allocator, key, val) catch unreachable;

    try std.testing.expectEqualStrings("42", ctx.getParam("id").?);
    try std.testing.expect(ctx.getParam("missing") == null);
}

test "Self - content type checks" {
    const allocator = std.testing.allocator;
    const request_bytes = "POST /api HTTP/1.1\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "Content-Length: 4\r\n" ++
        "\r\n" ++
        "test";

    const head = try std.http.Server.Request.Head.parse(request_bytes);
    var server: std.http.Server = .{
        .reader = .{ .in = undefined, .state = .received_head, .interface = undefined, .max_head_len = 4096 },
        .out = undefined,
    };
    var req: std.http.Server.Request = .{
        .server = &server,
        .head = head,
        .head_buffer = request_bytes,
    };

    var ctx = try Self.init(allocator, std.testing.io, &req);
    defer ctx.deinit();

    try std.testing.expect(ctx.isJson());
    try std.testing.expect(!ctx.isForm());
    try std.testing.expect(!ctx.isMultipartForm());

    try std.testing.expect(ctx.hasContentType("application/json; charset=utf-8"));
}

// =========================================================================
// 请求体读取测试
//
// 上面那些测试都用 `.in = undefined` 的假 server，碰不到真正的 body 读取。
// 下面这个 harness 拿 `std.Io.Reader.fixed` 喂一段完整的请求报文，
// 走 `Server.receiveHead()` 得到真 Request，body 路径就都能覆盖到了。
// =========================================================================

/// comptime 重复一段字节串。
/// （这个 Zig 版本已经没有 `**` 运算符了，`*` `*` 会被当成两个 token 解析。）
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // 放进容器作用域的 const 才有静态生命周期，可以安全取地址。
    return &struct {
        const value = blk: {
            var buf: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
            break :blk buf;
        };
    }.value;
}

/// 必须 `var h: BodyHarness = undefined; try h.init(...)` 原地初始化——
/// `server` 持有 `&self.in` / `&self.out`，harness 不能在 init 后被移动。
const BodyHarness = struct {
    in: std.Io.Reader,
    out: std.Io.Writer,
    server: http.Server,
    request: http.Server.Request,

    fn init(self: *BodyHarness, raw_request: []const u8, out_storage: []u8) !void {
        self.in = .fixed(raw_request);
        self.out = .fixed(out_storage);
        self.server = http.Server.init(&self.in, &self.out);
        self.request = try self.server.receiveHead();
    }
};

test "readBody - 读完之后 header 与 path 依然可用" {
    // 回归测试：`getHeader` 曾经直接调 `request.iterateHeaders()`，
    // 而后者断言 `reader.state == .received_head`——读过 body 就 assert 崩，
    // 任何「先读 body 再看鉴权头」的 handler 都能被远程打挂。
    const allocator = std.testing.allocator;
    const raw = "POST /upload?a=1 HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "X-Probe: hello-probe\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("hello", try ctx.readBody());

    // 崩溃回归：这一行以前会 assert failure
    try std.testing.expectEqualStrings("hello-probe", ctx.getHeader("X-Probe").?);
    try std.testing.expectEqualStrings("/upload", ctx.path);
    try std.testing.expectEqualStrings("a=1", ctx.query);
    try std.testing.expectEqualStrings("text/plain", ctx.content_type.?);
}

test "readBody - 带 body 的请求持有自己的 head 副本" {
    // std 明确写了 head_buffer「invalidated by any subsequent consumption
    // of the input stream」。带 body 的请求必须复制，否则 64KiB 的 POST
    // 之后 ctx.path 会变成 body 的内容（实测过）。
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    try std.testing.expect(ctx.head_copy != null);
    // path 必须落在副本里，而不是还指着连接缓冲区
    const copy = ctx.head_copy.?;
    const p = @intFromPtr(ctx.path.ptr);
    try std.testing.expect(p >= @intFromPtr(copy.ptr) and p < @intFromPtr(copy.ptr) + copy.len);
}

test "readBody - 无 body 的请求走零拷贝，不复制 head" {
    const allocator = std.testing.allocator;
    const raw = "GET /p HTTP/1.1\r\nHost: x\r\nX-Probe: v\r\n\r\n";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    try std.testing.expect(ctx.head_copy == null);
    try std.testing.expectEqualStrings("v", ctx.getHeader("X-Probe").?);
    try std.testing.expectEqualStrings("", try ctx.readBody());
}

test "readBody - 超过 body_size_limit 返回 413 并毒化连接" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ repeat("x", 100);

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();
    ctx.body_size_limit = 10;

    try std.testing.expectError(error.BodyTooLarge, ctx.readBody());
    // 客户端还在发那 100 字节，我们没读，连接不能复用
    try std.testing.expect(ctx.poisoned);
}

test "readBody - 超过 lazy_read_size 报错但不毒化连接" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ repeat("x", 100);

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();
    ctx.lazy_read_size = 10;

    try std.testing.expectError(error.BodyTooLargeToBuffer, ctx.readBody());
    // 关键区别：一个字节都没读，handler 还能改用 bodyStream() 接着处理
    try std.testing.expect(!ctx.poisoned);
    try std.testing.expect(!ctx.body_read);
}

test "readBody - lazy_read_size 之内的请求照常缓冲" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();
    ctx.lazy_read_size = 1024;

    try std.testing.expectEqualStrings("hello", try ctx.readBody());
}

test "bodyStream - 增量读到 EOF，body 不进内存" {
    const allocator = std.testing.allocator;
    const payload = repeat("abcdefghij", 10); // 100 字节
    const raw = "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ payload;

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    var stream_buf: [16]u8 = undefined;
    const reader = try ctx.bodyStream(&stream_buf);

    var total: usize = 0;
    var chunk: [7]u8 = undefined; // 故意用不整除的粒度
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        try std.testing.expectEqualStrings(payload[total..][0..n], chunk[0..n]);
        total += n;
    }

    try std.testing.expectEqual(@as(usize, 100), total);
    // body 从没被缓冲过
    try std.testing.expect(ctx.body_data == null);
    // 读干净了，连接可以复用
    try std.testing.expect(ctx.bodyDrained());
}

test "bodyStream - 与 readBody 互斥" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    _ = try ctx.readBody();
    var stream_buf: [16]u8 = undefined;
    // std 那边是 assert（直接崩），所以必须在框架层挡住
    try std.testing.expectError(error.BodyAlreadyRead, ctx.bodyStream(&stream_buf));
}

test "bodyStream - 开流之后 readBody 被拒绝" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    var stream_buf: [16]u8 = undefined;
    _ = try ctx.bodyStream(&stream_buf);
    try std.testing.expectError(error.BodyIsStreaming, ctx.readBody());
    try std.testing.expectError(error.BodyIsStreaming, ctx.bodyStream(&stream_buf));
}

test "bodyStream - 没读完时 bodyDrained 为 false" {
    // Server 靠这个判断决定要不要关连接：socket 上还压着本请求的 body，
    // 复用的话残余字节会被当成下一个请求的头部。
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ repeat("x", 100);

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    var stream_buf: [16]u8 = undefined;
    const reader = try ctx.bodyStream(&stream_buf);

    var chunk: [10]u8 = undefined;
    _ = try reader.readSliceShort(&chunk); // 只读一小段就撒手

    try std.testing.expect(ctx.body_streaming);
    try std.testing.expect(!ctx.bodyDrained());
}

test "readBody - Expect: 100-continue 先回 100 再读" {
    // 崩溃回归：以前用的是 readerExpectNone，它 assert(head.expect == null)。
    // curl 上传大文件默认就带这个头，一条命令就能把进程打崩。
    const allocator = std.testing.allocator;
    const raw = "POST /up HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Expect: 100-continue\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("hello", try ctx.readBody());
    // 客户端在等这一句才肯发 body
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", h.out.buffered());
}

test "bodyStream - Expect: 100-continue 同样处理" {
    const allocator = std.testing.allocator;
    const raw = "POST /up HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Expect: 100-continue\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    var stream_buf: [64]u8 = undefined;
    const reader = try ctx.bodyStream(&stream_buf);
    var chunk: [16]u8 = undefined;
    const n = try reader.readSliceShort(&chunk);

    try std.testing.expectEqualStrings("hello", chunk[0..n]);
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", h.out.buffered());
}

test "readBody - 无法满足的 expect 值返回 HttpExpectationFailed" {
    const allocator = std.testing.allocator;
    const raw = "POST /up HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Expect: something-else\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    // Server 把它映射成 417 Expectation Failed
    try std.testing.expectError(error.HttpExpectationFailed, ctx.readBody());
}

test "bodyStream - chunked 编码也能流式读" {
    const allocator = std.testing.allocator;
    const raw = "POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n\r\n";

    var out_storage: [1024]u8 = undefined;
    var h: BodyHarness = undefined;
    try h.init(raw, &out_storage);

    var ctx = try Self.init(allocator, std.testing.io, &h.request);
    defer ctx.deinit();

    var stream_buf: [64]u8 = undefined;
    const reader = try ctx.bodyStream(&stream_buf);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(allocator);
    var chunk: [4]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        try acc.appendSlice(allocator, chunk[0..n]);
    }

    try std.testing.expectEqualStrings("hello world", acc.items);
    try std.testing.expect(ctx.bodyDrained());
}
