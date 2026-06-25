//! 请求上下文
//!
//! 封装 HTTP 请求信息，支持按需延迟解析以减少不必要的内存分配。
//!
//! # 设计说明
//!
//! 用户常见的请求处理中通常只需要少数几个 header 或 query 参数（甚至一个都不需要）。
//! 如果每次请求都全量解析所有 headers 到 HashMap，会造成大量不必要的堆分配和释放。
//!
//! 优化策略：
//!
//! | 方案 | 分配 | 查询速度 | 适用场景 |
//! |------|------|---------|---------|
//! | 全量解析到 HashMap（旧方案） | 每次请求 O(n) alloc | O(1) | 需要频繁随机访问 |
//! | 每次线性扫描（当前方案） | 零分配 | O(n) | 读取少量参数 |
//! | 混合：先线性扫描，缓存命中结果 | 仅首次 O(1) alloc | 首次 O(n)，后续 O(1) | 大部分场景 |
//!
//! 当前实现采用 **线性扫描 + 结果缓存** 策略：
//! - 不预先解析 headers/query/cookies
//! - 首次 `getHeader` / `getQuery` / `getCookie` 时线性扫描
//! - 扫描结果**不缓存**（避免分配），因为同一请求中重复读取同一 key 的情况极少
//! - 路径参数（`path_params`）仍需 HashMap，因为路由分发时会批量设置多个参数
//!
//! # 零分配路径
//!
//! 如果 handler 完全不需要 header/query/cookie，则 `Self.init` 只做：
//! - 1 次 `StringHashMap.init`（path_params 用，条目为空）
//! - 无 dupe 分配
//! - `deinit` 只有一次 HashMap deinit

const std = @import("std");
const http = std.http;
const mem = std.mem;

const Multipart = @import("multipart.zig");
const deserialize = @import("deserialize.zig");

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
query_params: ?std.StringHashMapUnmanaged([]const u8) = null,

// ---- 请求体 ----
content_type: ?[]const u8,
content_length: ?u64,
transfer_encoding: http.TransferEncoding,

// ---- Multipart 解析器（延迟初始化） ----
multipart_parser: ?*Multipart.Parser = null,

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
is_websocket: bool = false, // 新增

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
    // 释放查询参数缓存
    if (self.query_params) |*qp| {
        freeHashMap(qp, self.allocator);
    }

    // 只有 path_params 一定需要释放
    freeHashMap(&self.path_params, self.allocator);

    // 释放 body 数据
    if (self.body_data) |data| {
        self.allocator.free(data);
    }

    // 释放 multipart 解析器
    if (self.multipart_parser) |parser| {
        parser.deinit();
        self.allocator.destroy(parser);
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

            const eq_idx = mem.indexOfScalar(u8, pair, '=');
            if (eq_idx) |idx| {
                const k = pair[0..idx];
                const raw_v = pair[idx + 1 ..];

                // URL 解码值只在需要时分配
                const value = if (mem.indexOfAny(u8, raw_v, "%+")) |_|
                    (urlDecode(self.allocator, raw_v) catch raw_v)
                else
                    raw_v;

                const key_dup = self.allocator.dupe(u8, k) catch continue;
                if (value.ptr != raw_v.ptr) {
                    // value 是 urlDecode 分配的新内存，所有权转移给 HashMap
                    self.query_params.?.put(self.allocator, key_dup, value) catch {
                        self.allocator.free(key_dup);
                    };
                } else {
                    // value 指向原始 query 缓冲区，需要复制一份
                    const val_dup = self.allocator.dupe(u8, value) catch {
                        self.allocator.free(key_dup);
                        continue;
                    };
                    self.query_params.?.put(self.allocator, key_dup, val_dup) catch {
                        self.allocator.free(key_dup);
                        self.allocator.free(val_dup);
                    };
                }
            } else {
                // 没有 '=' 的参数，值为空字符串
                const key_dup = self.allocator.dupe(u8, pair) catch continue;
                const val_dup = self.allocator.dupe(u8, "") catch {
                    self.allocator.free(key_dup);
                    continue;
                };
                self.query_params.?.put(self.allocator, key_dup, val_dup) catch {
                    self.allocator.free(key_dup);
                    self.allocator.free(val_dup);
                };
            }
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
pub fn readBody(self: *Self) ![]const u8 {
    if (self.body_read) {
        return self.body_data orelse error.BodyAlreadyRead;
    }

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

    var temp_buf: [65536]u8 = undefined;
    const body_reader = self.request.readerExpectNone(&temp_buf);

    var result = try std.ArrayList(u8).initCapacity(self.allocator, 256);

    var total_read: u64 = 0;
    var chunk_buf: [65536]u8 = undefined;
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

    // 通过 bodyReader 验证请求体可被流式读取
    var reader = self.bodyReader();
    if (self.body_data.?.len > 0) {
        var buf: [1]u8 = undefined;
        _ = try reader.read(&buf);
    }

    return self.body_data.?;
}

/// 返回一个 reader，用于流式读取请求体（避免一次性加载到内存）。
/// 当前 std.http.Server.Request 不直接支持流式读取，所以提供一个缓冲的 reader 包装。
/// reader 在请求体末尾返回 0（EndOfStream）。
///
/// 注意：bodyReader 返回的 reader 读取的是 `readBody()` 已缓冲的数据，
/// 因此需要先调用 `readBody()` 将请求体读入内存。
pub fn bodyReader(self: *const Self) BodyReader {
    return .{
        .data = self.body_data orelse "",
        .pos = 0,
    };
}

/// 将请求体解析为指定类型的 JSON 值
///
/// ⚠️ 已废弃：请使用 `bodyAs(T)` 替代，它提供更好的内存管理。
/// 此函数保留向后兼容，但返回的值可能包含悬挂指针（对于含 slice 字段的类型）。
pub fn json(self: *Self, comptime T: type) !T {
    const body = try self.readBody();
    const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{});
    defer parsed.deinit();
    return parsed.value;
}

/// 根据 Content-Type 自动反序列化请求体为类型 T
///
/// 支持的 Content-Type：
/// - `application/json` → JSON 解析
/// - `application/x-www-form-urlencoded` → form 解析（comptime 反射）
///
/// 返回 `Parsed(T)`，调用方需在使用完毕后调用 `parsed.deinit()` 释放内存。
///
/// # 使用示例
///
/// ```zig
/// const CreateUser = struct {
///     name: []const u8,
///     age: u32,
///     email: []const u8,
/// };
///
/// fn handler(ctx: *Self, res: *Response) !void {
///     var parsed = try ctx.bodyAs(CreateUser);
///     defer parsed.deinit();
///
///     const user = parsed.value;
///     std.log.info("name={s}, age={d}", .{ user.name, user.age });
/// }
/// ```
pub fn bodyAs(self: *Self, comptime T: type) !deserialize.Parsed(T) {
    const body = try self.readBody();

    if (body.len == 0) {
        return error.EmptyBody;
    }

    const ct = self.content_type orelse return error.NoContentType;

    if (std.ascii.indexOfIgnoreCase(ct, "application/json") != null) {
        return deserialize.parseJson(T, self.allocator, body);
    }

    if (std.ascii.indexOfIgnoreCase(ct, "application/x-www-form-urlencoded") != null) {
        return deserialize.parseForm(T, self.allocator, body);
    }

    return error.UnsupportedContentType;
}

/// 将 URL 查询参数反序列化为结构体 T
///
/// 查询字符串格式与 form-urlencoded 相同（`key=value&key=value`），
/// 直接复用 `parseForm` 的 comptime 反射逻辑。
///
/// 返回 `Parsed(T)`，调用方需在使用完毕后调用 `parsed.deinit()` 释放内存。
///
/// # 使用示例
///
/// ```zig
/// const ListQuery = struct {
///     page: u32 = 1,
///     limit: u32 = 20,
///     sort: ?[]const u8,
/// };
///
/// fn handler(ctx: *Self, res: *Response) !void {
///     var parsed = try ctx.queryAs(ListQuery);
///     defer parsed.deinit();
///
///     const q = parsed.value;
///     std.log.info("page={d}, limit={d}", .{ q.page, q.limit });
/// }
/// ```
pub fn queryAs(self: *Self, comptime T: type) !deserialize.Parsed(T) {
    if (self.query.len == 0) {
        return error.EmptyBody;
    }
    return deserialize.parseForm(T, self.allocator, self.query);
}

/// 获取 Multipart 表单解析器（延迟初始化）
pub fn getMultipart(self: *Self) !*Multipart.Parser {
    if (self.multipart_parser) |parser| {
        return parser;
    }

    // 检查是否为 multipart/form-data
    const ct = self.content_type orelse return error.NotMultipart;
    if (std.mem.indexOfIgnoreCase(u8, ct, "multipart/form-data") == null) {
        return error.NotMultipart;
    }

    // 创建解析器
    const parser = try self.allocator.create(Multipart.Parser);
    parser.* = try Multipart.Parser.init(self.allocator, ct);
    self.multipart_parser = parser;

    // 解析请求体
    const body = try self.readBody();
    try parser.parse(body);

    return parser;
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

/// 获取客户端 IP 地址（从请求头或连接信息）
pub fn getClientIp(self: *const Self) ?[]const u8 {
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

/// 获取表单字段值。
///
/// 需要先调用 `readBody()` 读取请求体。
/// 每次调用都会线性扫描 body 数据，不分配、不缓存。
pub fn getForm(self: *Self, key: []const u8) ?[]const u8 {
    const body = self.readBody() catch return null;
    if (body.len == 0) return null;

    var pairs = mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            if (mem.eql(u8, pair[0..idx], key)) {
                return pair[idx + 1 ..];
            }
        } else {
            if (mem.eql(u8, pair, key)) {
                return "";
            }
        }
    }
    return null;
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
