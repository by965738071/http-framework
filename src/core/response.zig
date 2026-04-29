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

/// 压缩数据（gzip格式）
/// 使用 std.Io.Writer.Allocating 捕获压缩后的数据
fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // 使用 Allocating writer 来捕获压缩输出
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    // 初始化 gzip 压缩器，输出到 out.writer
    var gzip_compressor = std.compress.gzip.Compress.init(allocator, .gzip);
    defer gzip_compressor.deinit();

    // 获取压缩器的写入接口
    const writer = gzip_compressor.writer();

    // 写入数据
    try writer.writeAll(data);

    // 关闭压缩器，确保所有数据被刷新
    try gzip_compressor.close();

    // 返回压缩后的数据
    return out.toOwnedSlice();
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
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Content-Type",
        .value = "text/plain; charset=utf-8",
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 发送 HTML 响应（`Content-Type: text/html`）
pub fn html(self: *Self, content: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Content-Type",
        .value = "text/html; charset=utf-8",
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
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

    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Content-Type",
        .value = "application/json",
    });

    try self.request.respond(json_output, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 发送文件内容（指定 `Content-Type`）
pub fn file(self: *Self, content: []const u8, content_type: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator, .{
        .name = "Content-Type",
        .value = content_type,
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
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

// =========================================================================
// 内部辅助
// =========================================================================

/// 将所有 Cookie 转换为 `Set-Cookie` 响应头并追加到 headers 中
fn addCookiesToHeaders(self: *Self) !void {
    for (self.cookies.items) |cookie| {
        const cookie_str = try self.buildCookieString(cookie);
        defer self.allocator.free(cookie_str);
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
