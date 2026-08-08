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

/// 用户数据容器 — 包含不透明指针和销毁函数
/// 任何模块都可以存入自定义数据，框架会通过 destroyFn 自动释放
pub const UserData = struct {
    ptr: *anyopaque,
    destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
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

// ---- 内部状态 ----
body_read: bool,
body_data: ?[]const u8,

/// 请求体大小限制（字节），0 表示不限制
body_size_limit: u64 = 0,

// ---- 延迟解析标志 ----
headers_parsed: bool,

// ---- 用户数据（中间件传递） ----
user_data: ?UserData = null,

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
    const path = if (query_start) |idx| target[0..idx] else target;
    const query = if (query_start) |idx| target[idx + 1 ..] else "";

    return Self{
        .allocator = allocator,
        .io = io,
        .method = head.method,
        .path = path,
        .query = query,
        .version = head.version,
        .path_params = std.StringHashMapUnmanaged([]const u8).empty,
        .content_type = head.content_type,
        .content_length = head.content_length,
        .transfer_encoding = head.transfer_encoding,
        .request = request,
        .body_read = false,
        .body_data = null,
        .headers_parsed = false,
        .user_data = null,
    };
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

    // 通过注册的销毁函数释放用户数据（通用、类型安全）
    if (self.user_data) |ud| {
        ud.destroyFn(ud.ptr, self.allocator);
    }
}

// =========================================================================
// 请求头访问（延迟线性扫描）
// =========================================================================

/// 获取请求头值（大小写不敏感）。
///
/// 首次调用时线性扫描原始头部数据，不缓存、不分配。
pub fn getHeader(self: *const Self, key: []const u8) ?[]const u8 {
    var it = self.request.iterateHeaders();
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
pub fn iterateHeaders(self: *const Self) http.HeaderIterator {
    return self.request.iterateHeaders();
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
pub fn readBody(self: *Self) ![]const u8 {
    if (self.body_read) {
        return self.body_data orelse error.BodyAlreadyRead;
    }

    // 此后任何错误都意味着 socket 上的 body 未被完整消费 → 连接不可复用
    errdefer self.poisoned = true;

    // 检查 Content-Length 是否超过限制
    if (self.body_size_limit > 0) {
        if (self.content_length) |cl| {
            if (cl > self.body_size_limit) {
                return error.BodyTooLarge;
            }
        }
    }

    // 没有 Content-Length 且没有 Transfer-Encoding 的请求没有 body，直接返回空
    if (self.content_length == null and self.transfer_encoding == .none) {
        self.body_read = true;
        self.body_data = &.{};
        return &.{};
    }

    var temp_buf: [16384]u8 = undefined;
    const body_reader = self.request.readerExpectNone(&temp_buf);

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

/// 返回一个 reader，用于增量读取已缓冲的请求体数据。
///
/// 注意：这不是真正的流式读取——它读取的是 `readBody()` 已缓冲到内存的数据，
/// 因此需要先调用 `readBody()`。真正的流式（边收边处理）当前不支持，
/// 大文件上传请使用 `multipart` 模块。
pub fn bodyReader(self: *const Self) BodyReader {
    return .{
        .data = self.body_data orelse "",
        .pos = 0,
    };
}

// =========================================================================
// 用户数据（中间件传递）
// =========================================================================

/// 设置用户自定义数据（需同时提供销毁函数）
///
/// `destroyFn` 负责释放在 data 中持有的所有堆分配资源。
/// 框架会在 Self.deinit() 时自动调用它。
///
/// # 使用示例
/// ```zig
/// fn destroyMyData(ptr: *anyopaque, allocator: std.mem.Allocator) void {
///     const data: *MyData = @ptrCast(@alignCast(ptr));
///     allocator.free(data.name);
///     allocator.destroy(data);
/// }
/// ctx.setUserData(@ptrCast(my_data), destroyMyData);
/// ```
pub fn setUserData(
    self: *Self,
    data: *anyopaque,
    destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
) void {
    self.user_data = .{ .ptr = data, .destroyFn = destroyFn };
}

/// 获取用户自定义数据
/// 调用方需知道具体的类型 T，通过 comptime 参数进行指针转换
pub fn getUserData(self: *const Self, comptime T: type) ?*T {
    const data = self.user_data orelse return null;
    return @ptrCast(@alignCast(data.ptr));
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

fn testDestroyMyData(ptr: *anyopaque, a: std.mem.Allocator) void {
    const T = struct { value: u32 };
    const data: *T = @ptrCast(@alignCast(ptr));
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

    const MyData = struct { value: u32 };
    const my_data = try allocator.create(MyData);
    my_data.* = .{ .value = 42 };

    ctx.setUserData(@ptrCast(my_data), testDestroyMyData);

    const retrieved = ctx.getUserData(MyData);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.value);
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
