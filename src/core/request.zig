//! 请求上下文
//!
//! 封装 HTTP 请求的完整信息，包括路径、查询参数、请求头、Cookie、
//! 路径参数、请求体等。提供便捷的解析和访问方法。
//!
//! # 生命周期
//!
//! 1. `init` — 在 `receiveHead` 后立即调用
//! 2. 解析 query / headers / cookies
//! 3. （可选）`readBody` — 按需读取请求体
//! 4. `deinit` — 在响应发送后调用，释放所有资源

const std = @import("std");
const http = std.http;
const mem = std.mem;

allocator: std.mem.Allocator,
io: std.Io,

// ---- 基本信息 ----
method: http.Method,
path: []const u8,
query: []const u8,
version: http.Version,

// ---- 解析后的数据 ----
query_params: std.StringHashMap([]const u8),
form_params: std.StringHashMap([]const u8),
headers: std.StringHashMap([]const u8),
cookies: std.StringHashMap([]const u8),
path_params: std.StringHashMap([]const u8),

// ---- 请求体 ----
content_type: ?[]const u8,
content_length: ?u64,
transfer_encoding: http.TransferEncoding,

// ---- 原始请求引用 ----
request: *http.Server.Request,

// ---- 内部状态 ----
body_read: bool,
body_data: ?[]const u8,

// ---- 用户数据（中间件传递） ----
user_data: ?*anyopaque,

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

    var ctx = Self{
        .allocator = allocator,
        .io = io,
        .method = head.method,
        .path = path,
        .query = query,
        .version = head.version,
        .query_params = std.StringHashMap([]const u8).init(allocator),
        .form_params = std.StringHashMap([]const u8).init(allocator),
        .headers = std.StringHashMap([]const u8).init(allocator),
        .cookies = std.StringHashMap([]const u8).init(allocator),
        .path_params = std.StringHashMap([]const u8).init(allocator),
        .content_type = head.content_type,
        .content_length = head.content_length,
        .transfer_encoding = head.transfer_encoding,
        .request = request,
        .body_read = false,
        .body_data = null,
        .user_data = null,
    };

    // 解析各类数据
    try ctx.parseQueryParams();
    try ctx.parseHeaders();
    try ctx.parseCookies();

    return ctx;
}

/// 释放所有堆分配的资源
pub fn deinit(self: *Self) void {
    freeHashMap(&self.query_params, self.allocator);
    freeHashMap(&self.form_params, self.allocator);
    freeHashMap(&self.headers, self.allocator);
    freeHashMap(&self.cookies, self.allocator);
    freeHashMap(&self.path_params, self.allocator);

    // 释放 body 数据
    if (self.body_data) |data| {
        self.allocator.free(data);
    }
}

// =========================================================================
// 数据解析
// =========================================================================

/// 解析 Query 字符串（`key=value&key2=value2`）
fn parseQueryParams(self: *Self) !void {
    if (self.query.len == 0) return;

    var pairs = mem.splitScalar(u8, self.query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            const key = try self.allocator.dupe(u8, pair[0..idx]);
            const value = try urlDecode(self.allocator, pair[idx + 1 ..]);
            try self.query_params.put(key, value);
        } else {
            const key = try self.allocator.dupe(u8, pair);
            try self.query_params.put(key, try self.allocator.dupe(u8, ""));
        }
    }
}

/// 解析 HTTP 请求头
fn parseHeaders(self: *Self) !void {
    var it = self.request.iterateHeaders();
    while (it.next()) |header| {
        const key = try self.allocator.dupe(u8, header.name);
        const value = try self.allocator.dupe(u8, header.value);
        try self.headers.put(key, value);
    }
}

/// 解析 Cookie 请求头
fn parseCookies(self: *Self) !void {
    const cookie_header = self.getHeader("Cookie") orelse return;

    var pairs = mem.splitScalar(u8, cookie_header, ';');
    while (pairs.next()) |pair| {
        const trimmed = mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, trimmed, '=');
        if (eq_idx) |idx| {
            const key = try self.allocator.dupe(u8, trimmed[0..idx]);
            const value = try self.allocator.dupe(u8, trimmed[idx + 1 ..]);
            try self.cookies.put(key, value);
        }
    }
}

// =========================================================================
// 公共访问方法
// =========================================================================

/// 获取查询参数值
pub fn getQuery(self: *const Self, key: []const u8) ?[]const u8 {
    return self.query_params.get(key);
}

/// 获取请求头值（大小写不敏感）
pub fn getHeader(self: *const Self, key: []const u8) ?[]const u8 {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

/// 获取 Cookie 值
pub fn getCookie(self: *const Self, key: []const u8) ?[]const u8 {
    return self.cookies.get(key);
}

/// 获取路径参数值（如 `/users/:id` 中的 `id`）
pub fn getParam(self: *const Self, key: []const u8) ?[]const u8 {
    return self.path_params.get(key);
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

    // 使用 Zig 标准库的 body reader
    var temp_buf: [4096]u8 = undefined;
    const body_reader = self.request.readerExpectNone(&temp_buf);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(self.allocator);

    // 持续读取直到流结束
    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = try body_reader.readSliceShort(&chunk_buf);
        if (n == 0) break;
        try result.appendSlice(self.allocator, chunk_buf[0..n]);
    }

    self.body_read = true;
    self.body_data = try result.toOwnedSlice(self.allocator);

    // 如果是 URL-encoded form 数据，自动解析 form 参数
    if (self.content_type) |ct| {
        if (mem.indexOf(u8, ct, "application/x-www-form-urlencoded") != null) {
            try self.parseFormParams(self.body_data.?);
        }
    }

    return self.body_data.?;
}

// =========================================================================
// Form / JSON 辅助
// =========================================================================

/// 解析 URL-encoded 表单数据
fn parseFormParams(self: *Self, data: []const u8) !void {
    var pairs = mem.splitScalar(u8, data, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            const key = try urlDecode(self.allocator, pair[0..idx]);
            const value = try urlDecode(self.allocator, pair[idx + 1 ..]);
            try self.form_params.put(key, value);
        } else {
            const key = try urlDecode(self.allocator, pair);
            try self.form_params.put(key, try self.allocator.dupe(u8, ""));
        }
    }
}

/// 获取表单字段值（需先调用 `readBody`）
pub fn getForm(self: *const Self, key: []const u8) ?[]const u8 {
    return self.form_params.get(key);
}

/// 将请求体解析为指定类型的 JSON 值
pub fn json(self: *Self, comptime T: type) !T {
    const body = try self.readBody();
    const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{});
    defer parsed.deinit();
    return parsed.value;
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
// 内部工具函数
// =========================================================================

/// 释放 `StringHashMap` 中所有堆分配的 key 和 value
fn freeHashMap(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
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
                        // 无效的百分比编码，保留原字符
                        try result.append(allocator, input[i]);
                        continue;
                    };
                    try result.append(allocator, val);
                    i += 2;
                } else {
                    // 不完整的百分比序列，保留原字符
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
