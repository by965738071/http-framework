//! 响应构建器
//!
//! 提供链式调用的 API 来构建 HTTP 响应，支持设置状态码、响应头、
//! Cookie，以及发送 JSON / HTML / 文本 / 文件 / 重定向等多种响应格式。
//!
//! # 使用示例
//! ```zig
//! var res = Response.init(allocator, &request);
//! defer res.deinit();
//! try res.statusCode(.ok).json(.{ .message = "Hello" });
//! ```

const std = @import("std");
const http = std.http;

allocator: std.mem.Allocator,
request: *http.Server.Request,
status: http.Status,
headers: std.ArrayList(http.Header),
cookies: std.ArrayList(Cookie),
enable_compression: bool = false,

/// 底层原始 writer（用于 chunked transfer encoding）
raw_writer: ?RawWriter = null,

pub const RawWriter = struct {
    ctx: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!usize,

    pub fn write(self: RawWriter, data: []const u8) !usize {
        return self.writeFn(self.ctx, data);
    }
};

const Self = @This();

/// Cookie 结构
const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age: ?i64 = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null,
};

/// 流式响应写入器。
/// 支持两种模式：
/// - raw_writer 存在时：使用 HTTP chunked transfer encoding，实时发送（真流式）
/// - raw_writer 为 null 时：收集所有 chunk，finish() 时一次性发送
pub const StreamWriter = struct {
    response: *Self,
    content_type: []const u8,
    chunks: std.ArrayList([]const u8),
    headers_sent: bool = false,

    /// 写入一个数据块。
    /// 如果 raw_writer 可用，立即以 chunked 编码发送。
    /// 否则暂存到内存。
    pub fn write(self: *StreamWriter, data: []const u8) !void {
        if (self.response.raw_writer) |rw| {
            if (!self.headers_sent) {
                try self.sendChunkedHeaders(rw);
                self.headers_sent = true;
            }
            try writeChunk(rw, data);
        } else {
            const owned = try self.response.allocator.dupe(u8, data);
            errdefer self.response.allocator.free(owned);
            try self.chunks.append(self.response.allocator, owned);
        }
    }

    /// 发送响应头（Transfer-Encoding: chunked）
    fn sendChunkedHeaders(self: *StreamWriter, rw: RawWriter) !void {
        try self.response.addCookiesToHeaders();
        // 手动构造状态行和响应头
        var buf: [512]u8 = undefined;
        const status_text = http.Status.text(self.response.status) orelse "OK";
        const status_line = try std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.response.status), status_text });
        _ = try rw.write(status_line);

        try self.response.headers.append(self.response.allocator, .{ .name = "Content-Type", .value = self.content_type });
        try self.response.headers.append(self.response.allocator, .{ .name = "Transfer-Encoding", .value = "chunked" });

        for (self.response.headers.items) |h| {
            const line = try std.fmt.allocPrint(self.response.allocator, "{s}: {s}\r\n", .{ h.name, h.value });
            defer self.response.allocator.free(line);
            _ = try rw.write(line);
        }
        _ = try rw.write("\r\n");
    }

    /// 完成流式响应。
    /// raw_writer 模式：发送终止 chunk（0\r\n\r\n）。
    /// 缓冲模式：拼接所有 chunk 后通过 respond() 发送。
    pub fn finish(self: *StreamWriter) !void {
        if (self.response.raw_writer) |rw| {
            if (!self.headers_sent) try self.sendChunkedHeaders(rw);
            _ = try rw.write("0\r\n\r\n");
        } else {
            var total_size: usize = 0;
            for (self.chunks.items) |chunk| total_size += chunk.len;
            const result = try self.response.allocator.alloc(u8, total_size);
            defer self.response.allocator.free(result);
            var offset: usize = 0;
            for (self.chunks.items) |chunk| {
                @memcpy(result[offset .. offset + chunk.len], chunk);
                offset += chunk.len;
            }
            try self.response.sendResponse(result, self.content_type);
        }
    }

    /// 释放已收集的内存数据。
    pub fn deinit(self: *StreamWriter) void {
        for (self.chunks.items) |chunk| self.response.allocator.free(chunk);
        self.chunks.deinit(self.response.allocator);
    }
};

/// 写入一个 HTTP chunk：hex_size\r\ndata\r\n
fn writeChunk(rw: RawWriter, data: []const u8) !void {
    var size_buf: [16]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
    _ = try rw.write(size_str);
    _ = try rw.write(data);
    _ = try rw.write("\r\n");
}

// =========================================================================
// 初始化与清理
// =========================================================================

pub fn init(allocator: std.mem.Allocator, request: *http.Server.Request) Self {
    return .{
        .allocator = allocator,
        .request = request,
        .status = .ok,
        .headers = std.ArrayList(http.Header).empty,
        .cookies = std.ArrayList(Cookie).empty,
        .enable_compression = false,
    };
}

pub fn deinit(self: *Self) void {
    self.headers.deinit(self.allocator);
    self.cookies.deinit(self.allocator);
}

/// 启用或禁用压缩
pub fn compression(self: *Self, enabled: bool) *Self {
    self.enable_compression = enabled;
    return self;
}

// =========================================================================
// 压缩支持
// =========================================================================

/// 真实 gzip 压缩（std.compress.flate）
fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out_buf: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var c = std.compress.flate.Compress.init(&writer, &cbuf, .gzip, .default) catch return error.CompressionFailed;
    c.writer.writeAll(data) catch return error.CompressionFailed;
    c.finish() catch return error.CompressionFailed;
    return allocator.dupe(u8, out_buf[0..writer.end]);
}

/// 统一的响应发送辅助函数。
/// 自动处理 Cookie 序列化、Content-Type 设置和可选的 gzip 压缩。
fn sendResponse(self: *Self, content: []const u8, content_type: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Content-Type",
        .value = content_type,
    });

    if (self.enable_compression) {
        const compressed = try compressGzip(self.allocator, content);
        defer self.allocator.free(compressed);
        try self.headers.append(self.allocator, .{
            .name = "Content-Encoding",
            .value = "gzip",
        });
        try self.request.respond(compressed, .{
            .status = self.status,
            .extra_headers = self.headers.items,
        });
    } else {
        try self.request.respond(content, .{
            .status = self.status,
            .extra_headers = self.headers.items,
        });
    }
}

// =========================================================================
// 响应构建（链式 API）
// =========================================================================

/// 设置 HTTP 状态码
pub fn statusCode(self: *Self, code: http.Status) *Self {
    self.status = code;
    return self;
}

/// 添加响应头
pub fn header(self: *Self, name: []const u8, value: []const u8) !*Self {
    try self.headers.append(self.allocator, .{ .name = name, .value = value });
    return self;
}

/// 设置 Cookie
pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !*Self {
    try self.cookies.append(self.allocator, .{
        .name = name,
        .value = value,
    });
    return self;
}

// =========================================================================
// 响应发送
// =========================================================================

/// 发送纯文本响应（`Content-Type: text/plain`）
pub fn text(self: *Self, content: []const u8) !void {
    try self.sendResponse(content, "text/plain; charset=utf-8");
}

/// 发送 HTML 响应（`Content-Type: text/html`）
pub fn html(self: *Self, content: []const u8) !void {
    try self.sendResponse(content, "text/html; charset=utf-8");
}

/// 发送 JSON 响应（`Content-Type: application/json`）
pub fn json(self: *Self, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    try stringify.write(value);
    const json_output = out.written();

    try self.sendResponse(json_output, "application/json");
}

/// 发送文件内容（指定 `Content-Type`）
pub fn file(self: *Self, content: []const u8, content_type: []const u8) !void {
    try self.sendResponse(content, content_type);
}

/// 发送重定向响应
pub fn redirect(self: *Self, location: []const u8, permanent: bool) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Location",
        .value = location,
    });

    const status = if (permanent) http.Status.moved_permanently else http.Status.found;

    try self.request.respond("", .{
        .status = status,
        .extra_headers = self.headers.items,
    });
}

/// 启动一个流式响应，返回 StreamWriter。
/// 调用者通过返回的 writer 分块写入数据，最后调用 finish() 发送。
pub fn streamWriter(self: *Self, content_type: []const u8) !StreamWriter {
    return .{
        .response = self,
        .content_type = content_type,
        .chunks = try std.ArrayList([]const u8).initCapacity(self.allocator, 8),
    };
}

// =========================================================================
// 内部辅助
// =========================================================================

/// 将所有 Cookie 转换为 `Set-Cookie` 响应头并追加到 headers 中。
/// cookie_str 的所有权转移给 headers，由 deinit 统一释放。
fn addCookiesToHeaders(self: *Self) !void {
    for (self.cookies.items) |cookie| {
        const cookie_str = try self.buildCookieString(cookie);
        errdefer self.allocator.free(cookie_str);
        try self.headers.append(self.allocator, .{
            .name = "Set-Cookie",
            .value = cookie_str,
        });
    }
}

/// 将 `Cookie` 结构序列化为 `Set-Cookie` 头值字符串
fn buildCookieString(self: *Self, cookie: Cookie) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(self.allocator);

    // name=value
    try buf.appendSlice(self.allocator, cookie.name);
    try buf.append(self.allocator, '=');
    try buf.appendSlice(self.allocator, cookie.value);

    // 可选属性
    if (cookie.max_age) |age| {
        try buf.appendSlice(self.allocator, "; Max-Age=");
        try buf.print(self.allocator, "{d}", .{age});
    }
    if (cookie.path) |p| {
        try buf.appendSlice(self.allocator, "; Path=");
        try buf.appendSlice(self.allocator, p);
    }
    if (cookie.domain) |d| {
        try buf.appendSlice(self.allocator, "; Domain=");
        try buf.appendSlice(self.allocator, d);
    }
    if (cookie.secure) {
        try buf.appendSlice(self.allocator, "; Secure");
    }
    if (cookie.http_only) {
        try buf.appendSlice(self.allocator, "; HttpOnly");
    }
    if (cookie.same_site) |ss| {
        try buf.appendSlice(self.allocator, "; SameSite=");
        try buf.appendSlice(self.allocator, ss);
    }

    return buf.toOwnedSlice(self.allocator);
}

// ===========================================================================
// Tests
// ===========================================================================

test "Cookie struct" {
    const c = Cookie{
        .name = "session",
        .value = "abc123",
        .max_age = 3600,
        .path = "/",
        .secure = true,
        .http_only = true,
    };
    try std.testing.expectEqualStrings("session", c.name);
    try std.testing.expectEqualStrings("abc123", c.value);
    try std.testing.expectEqual(@as(?i64, 3600), c.max_age);
    try std.testing.expect(c.secure);
    try std.testing.expect(c.http_only);
}

test "compressGzip produces valid gzip data" {
    const allocator = std.testing.allocator;
    const input = "Hello, World! This is a test string for gzip compression.";

    const compressed = try compressGzip(allocator, input);
    defer allocator.free(compressed);

    // gzip magic bytes: 0x1F 0x8B
    try std.testing.expect(compressed.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1F), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8B), compressed[1]);

    // Compressed data should not equal input
    try std.testing.expect(!std.mem.eql(u8, input, compressed));
}

test "compressGzip small input" {
    const allocator = std.testing.allocator;
    const input = "hi";

    const compressed = try compressGzip(allocator, input);
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1F), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8B), compressed[1]);
}

test "compressGzip empty input" {
    const allocator = std.testing.allocator;
    const input = "";

    const compressed = try compressGzip(allocator, input);
    defer allocator.free(compressed);

    // gzip header should still be present
    try std.testing.expect(compressed.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1F), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8B), compressed[1]);
}

test "StreamWriter basic" {
    const allocator = std.testing.allocator;
    var sw = StreamWriter{
        .response = undefined,
        .content_type = "text/plain",
        .chunks = try std.ArrayList([]const u8).initCapacity(allocator, 4),
    };
    defer sw.deinit();

    try sw.write("Hello, ");
    try sw.write("World!");

    try std.testing.expectEqual(@as(usize, 2), sw.chunks.items.len);
    try std.testing.expectEqualStrings("Hello, ", sw.chunks.items[0]);
    try std.testing.expectEqualStrings("World!", sw.chunks.items[1]);
}

test "StreamWriter empty finish" {
    const allocator = std.testing.allocator;
    var sw = StreamWriter{
        .response = undefined,
        .content_type = "",
        .chunks = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
    defer sw.deinit();

    try std.testing.expectEqual(@as(usize, 0), sw.chunks.items.len);
}
