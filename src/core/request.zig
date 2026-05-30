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
//! 如果 handler 完全不需要 header/query/cookie，则 `RequestContext.init` 只做：
//! - 1 次 `StringHashMap.init`（path_params 用，条目为空）
//! - 无 dupe 分配
//! - `deinit` 只有一次 HashMap deinit

const std = @import("std");
const http = std.http;
const mem = std.mem;

const Multipart = @import("multipart.zig");

allocator: std.mem.Allocator,
io: std.Io,

// ---- 基本信息 ----
method: http.Method,
path: []const u8,
query: []const u8,
version: http.Version,

// ---- 路径参数 — 必须用 HashMap（路由批量写入） ----
path_params: std.StringHashMapUnmanaged([]const u8),

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

// ---- 延迟解析标志 ----
headers_parsed: bool,

// ---- 用户数据（中间件传递） ----
user_data: ?*anyopaque,

// ---- 中间件拦截状态码 ----
blocked_status: ?http.Status = null,

// ---- websocket ----
is_websocket: bool = false, // 新增

const Self = @This();

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
    // 只有 path_params 一定需要释放
    freeHashMap(&self.path_params, self.allocator);

    // 释放 body 数据
    if (self.body_data) |data| {
        self.allocator.free(data);
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
/// 首次调用时在线解析 query string，不缓存、不分配。
/// 返回的 slice 指向**请求头缓冲区**中的原始数据，生命周期到下一个请求头解析。
pub fn getQuery(self: *const Self, key: []const u8) ?[]const u8 {
    if (self.query.len == 0) return null;

    var pairs = mem.splitScalar(u8, self.query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            if (mem.eql(u8, pair[0..idx], key)) {
                // URL 解码只在有 % 或 + 字符时分配
                if (mem.indexOfAny(u8, pair[idx + 1 ..], "%+")) |_| {
                    return urlDecode(self.allocator, pair[idx + 1 ..]) catch return null;
                }
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

    var temp_buf: [65536]u8 = undefined;
    const body_reader = self.request.readerExpectNone(&temp_buf);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(self.allocator);

    var chunk_buf: [65536]u8 = undefined;
    while (true) {
        const n = try body_reader.readSliceShort(&chunk_buf);
        if (n == 0) break;
        try result.appendSlice(self.allocator, chunk_buf[0..n]);
    }

    self.body_read = true;
    self.body_data = try result.toOwnedSlice(self.allocator);

    return self.body_data.?;
}

/// 将请求体解析为指定类型的 JSON 值
pub fn json(self: *Self, comptime T: type) !T {
    const body = try self.readBody();
    const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{});
    defer parsed.deinit();
    return parsed.value;
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

/// 设置用户自定义数据
pub fn setUserData(self: *Self, data: *anyopaque) void {
    self.user_data = data;
}

/// 获取用户自定义数据
pub fn getUserData(self: *const Self, comptime T: type) ?*T {
    const data = self.user_data orelse return null;
    return @ptrCast(@alignCast(data));
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

/// 检查是否为 JSON 请求
pub fn isJson(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return mem.indexOfIgnoreCase(u8, ct, "application/json") != null;
}

/// 检查是否为表单请求
pub fn isForm(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return mem.indexOfIgnoreCase(u8, ct, "application/x-www-form-urlencoded") != null;
}

/// 检查是否为 multipart 表单请求
pub fn isMultipartForm(self: *const Self) bool {
    const ct = self.content_type orelse return false;
    return mem.indexOfIgnoreCase(u8, ct, "multipart/form-data") != null;
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
fn freeHashMap(map: *std.StringHashMapUnmanaged([]const u8), allocator: std.mem.Allocator) void {
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
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

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
