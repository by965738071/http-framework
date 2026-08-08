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
//!
//! # 内存所有权
//!
//! `header()` / `setCookie()` 会在内部复制 name/value，
//! 调用者传入的切片无需保持存活（栈缓冲区也安全）。
//! 所有内部复制在 `deinit()` 时统一释放。

const std = @import("std");
const http = std.http;

allocator: std.mem.Allocator,
request: *http.Server.Request,
status: http.Status,
headers: std.ArrayList(http.Header),
cookies: std.ArrayList(Cookie),
enable_compression: bool = false,

/// 客户端的 Accept-Encoding 头（由 Server 注入），用于压缩协商
accept_encoding: ?[]const u8 = null,

/// Server 响应头的值（由 Server 从 config.server_name 注入），null 表示不发送
server_name: ?[]const u8 = null,

/// 是否已发送响应（防止同一请求重复 respond 导致协议错乱）
responded: bool = false,

/// 内部持有的字符串（header name/value、cookie 字符串等），deinit 时统一释放
owned_strings: std.ArrayList([]u8) = .empty,

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
    };
}

pub fn deinit(self: *Self) void {
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.headers.deinit(self.allocator);
    self.cookies.deinit(self.allocator);
}

/// 启用或禁用压缩。
/// 注意：仅当客户端 `Accept-Encoding` 包含 gzip 时才会真正压缩。
pub fn compression(self: *Self, enabled: bool) *Self {
    self.enable_compression = enabled;
    return self;
}

// =========================================================================
// 压缩支持
// =========================================================================

/// 真实 gzip 压缩（std.compress.flate），使用动态增长缓冲区
fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // gzip 输出通常小于输入，但不可压缩数据（如已压缩的图片）
    // 可能略大于原始数据（最多约 0.1% + 20 字节开销）
    const overhead = (data.len / 8) + 128;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    // 预分配: items.len=0, capacity ≥ data.len+overhead
    try out.ensureTotalCapacity(allocator, data.len + overhead);

    var writer = std.Io.Writer.fixed(out.unusedCapacitySlice());
    var cbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var c = std.compress.flate.Compress.init(&writer, &cbuf, .gzip, .default) catch return error.CompressionFailed;
    c.writer.writeAll(data) catch return error.CompressionFailed;
    c.finish() catch return error.CompressionFailed;

    // writer.end 记录了写入多少字节，更新 items.len
    out.items.len += writer.end;

    // toOwnedSlice 将 items 所有权转移给调用者，零拷贝
    return out.toOwnedSlice(allocator);
}

/// 检查客户端是否接受 gzip 编码
fn clientAcceptsGzip(self: *const Self) bool {
    const ae = self.accept_encoding orelse return false;
    var it = std.mem.splitScalar(u8, ae, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        // 可能带 q 值：gzip;q=1.0
        const name_end = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        if (std.ascii.eqlIgnoreCase(trimmed[0..name_end], "gzip")) return true;
    }
    return false;
}

// =========================================================================
// 头部管理
// =========================================================================

/// 复制字符串到内部持有列表，返回稳定的切片
fn dupeOwned(self: *Self, s: []const u8) ![]const u8 {
    const copy = try self.allocator.dupe(u8, s);
    errdefer self.allocator.free(copy);
    try self.owned_strings.append(self.allocator, copy);
    return copy;
}

/// 检查是否已存在同名响应头（大小写不敏感）
fn hasHeader(self: *const Self, name: []const u8) bool {
    for (self.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

/// 仅当不存在同名头时追加（内部使用，value 会被复制）
fn appendHeaderIfAbsent(self: *Self, name: []const u8, value: []const u8) !void {
    if (self.hasHeader(name)) return;
    _ = try self.header(name, value);
}

/// 追加 Server 响应头（如果配置了 server_name 且尚未设置）
fn appendServerHeader(self: *Self) !void {
    const name = self.server_name orelse return;
    try self.appendHeaderIfAbsent("Server", name);
}

/// 统一的响应发送辅助函数。
/// 自动处理 Cookie 序列化、Content-Type 设置、Server 头和可选的 gzip 压缩。
fn sendResponse(self: *Self, content: []const u8, content_type: []const u8) !void {
    if (self.responded) return error.AlreadyResponded;

    try self.addCookiesToHeaders();
    try self.appendHeaderIfAbsent("Content-Type", content_type);
    try self.appendServerHeader();

    const use_gzip = self.enable_compression and self.clientAcceptsGzip();

    self.responded = true;
    if (use_gzip) {
        const compressed = try compressGzip(self.allocator, content);
        defer self.allocator.free(compressed);
        try self.appendHeaderIfAbsent("Content-Encoding", "gzip");
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

/// 拒绝头部字段里的 CR/LF/NUL。
///
/// 这些字符会被下游当作头部分隔符，从而让用户可控的值（Location、Cookie、
/// 自定义头）注入额外的响应头甚至整个响应体（HTTP response splitting）。
fn validateHeaderValue(s: []const u8) !void {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeaderValue;
    }
}

/// 添加响应头。
///
/// name 和 value 会被内部复制，调用者无需保证传入切片的存活期。
/// 含 CR/LF 的取值会被拒绝（防止响应头注入）。
pub fn header(self: *Self, name: []const u8, value: []const u8) !*Self {
    try validateHeaderValue(name);
    try validateHeaderValue(value);
    const owned_name = try self.dupeOwned(name);
    const owned_value = try self.dupeOwned(value);
    try self.headers.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    return self;
}

/// 设置 Cookie。
///
/// name 和 value 会被内部复制（与 `header()` 一致）：Cookie 直到响应发送时
/// 才被序列化，若此处只存切片，调用者的栈上临时字符串会先一步失效。
pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !*Self {
    try validateHeaderValue(name);
    try validateHeaderValue(value);
    const owned_name = try self.dupeOwned(name);
    const owned_value = try self.dupeOwned(value);
    try self.cookies.append(self.allocator, .{
        .name = owned_name,
        .value = owned_value,
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
    if (self.responded) return error.AlreadyResponded;

    try self.addCookiesToHeaders();
    _ = try self.header("Location", location);
    try self.appendServerHeader();

    const status = if (permanent) http.Status.moved_permanently else http.Status.found;

    self.responded = true;
    try self.request.respond("", .{
        .status = status,
        .extra_headers = self.headers.items,
    });
}

// =========================================================================
// 内部辅助
// =========================================================================

/// 将所有 Cookie 转换为 `Set-Cookie` 响应头并追加到 headers 中。
/// cookie_str 的所有权由 owned_strings 持有，deinit 时统一释放。
fn addCookiesToHeaders(self: *Self) !void {
    for (self.cookies.items) |cookie| {
        const cookie_str = try self.buildCookieString(cookie);
        // 只在所有权尚未转移前负责释放。若这里用 errdefer 覆盖到下面的
        // headers.append，append 失败时会释放一块 owned_strings 已经持有的内存，
        // deinit 时就是二次释放。
        self.owned_strings.append(self.allocator, cookie_str) catch |e| {
            self.allocator.free(cookie_str);
            return e;
        };
        try self.headers.append(self.allocator, .{
            .name = "Set-Cookie",
            .value = cookie_str,
        });
    }
    // 防止重复添加（sendResponse/redirect 只应调用一次，但保险起见清空）
    self.cookies.clearRetainingCapacity();
}

/// 将 `Cookie` 结构序列化为 `Set-Cookie` 头值字符串
fn buildCookieString(self: *Self, cookie: Cookie) ![]u8 {
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

test "init creates Response with defaults" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    try std.testing.expectEqual(allocator, res.allocator);
    try std.testing.expectEqual(@as(http.Status, .ok), res.status);
    try std.testing.expectEqual(false, res.enable_compression);
    try std.testing.expectEqual(false, res.responded);
    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.items.len);
}

test "statusCode sets status and returns self for chaining" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    try std.testing.expectEqual(@as(http.Status, .ok), res.status);

    const returned = res.statusCode(.not_found);
    try std.testing.expectEqual(@as(http.Status, .not_found), res.status);
    try std.testing.expectEqual(@as(http.Status, .not_found), returned.*.status);
    // Verify it's the same object
    try std.testing.expectEqual(@as(usize, @intFromPtr(&res)), @intFromPtr(returned));
}

test "header copies name and value (stack buffer safe)" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    // 栈缓冲区：旧实现会悬空，新实现内部复制
    var buf: [32]u8 = undefined;
    const dynamic_value = try std.fmt.bufPrint(&buf, "value-{d}", .{42});
    _ = try res.header("X-Dynamic", dynamic_value);

    // 修改原缓冲区，header 中存储的副本不受影响
    @memset(&buf, 'x');

    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
    try std.testing.expectEqualStrings("X-Dynamic", res.headers.items[0].name);
    try std.testing.expectEqualStrings("value-42", res.headers.items[0].value);
}

test "header appends multiple and supports chaining" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    const returned = try res.header("Content-Type", "application/json");
    _ = try res.header("X-Custom", "value");

    try std.testing.expectEqual(@as(usize, 2), res.headers.items.len);
    try std.testing.expectEqualStrings("X-Custom", res.headers.items[1].name);
    try std.testing.expectEqualStrings("value", res.headers.items[1].value);

    // Chaining returns self
    try std.testing.expectEqual(@as(usize, @intFromPtr(&res)), @intFromPtr(returned));
}

test "appendHeaderIfAbsent skips duplicates case-insensitively" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    _ = try res.header("content-type", "application/json");
    try res.appendHeaderIfAbsent("Content-Type", "text/html");

    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
    try std.testing.expectEqualStrings("application/json", res.headers.items[0].value);
}

test "setCookie appends cookies and supports chaining" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    const returned = try res.setCookie("session", "abc123");
    _ = try res.setCookie("theme", "dark");

    try std.testing.expectEqual(@as(usize, 2), res.cookies.items.len);
    try std.testing.expectEqualStrings("theme", res.cookies.items[1].name);

    // Chaining returns self
    try std.testing.expectEqual(@as(usize, @intFromPtr(&res)), @intFromPtr(returned));
}

test "setCookie copies name and value (no dangling caller slices)" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    {
        // 模拟调用方用栈上临时缓冲区构造 cookie 值后立刻离开作用域
        var buf: [16]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "uid-{d}", .{42});
        _ = try res.setCookie("session", value);
        @memset(&buf, 0xAA); // 调用方缓冲区失效
    }

    try res.addCookiesToHeaders();
    try std.testing.expectEqualStrings("session=uid-42", res.headers.items[0].value);
}

test "header/setCookie reject CRLF injection" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    try std.testing.expectError(error.InvalidHeaderValue, res.header("X-Foo", "bar\r\nX-Admin: 1"));
    try std.testing.expectError(error.InvalidHeaderValue, res.header("X-Foo\r\nX-Admin: 1", "bar"));
    try std.testing.expectError(error.InvalidHeaderValue, res.setCookie("sid", "abc\r\nSet-Cookie: admin=1"));
    try std.testing.expectError(error.InvalidHeaderValue, res.header("X-Foo", "bar\x00baz"));

    // 被拒绝的头不应留下任何痕迹
    try std.testing.expectEqual(@as(usize, 0), res.headers.items.len);
    try std.testing.expectEqual(@as(usize, 0), res.cookies.items.len);
}

test "addCookiesToHeaders produces Set-Cookie headers owned by response" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    _ = try res.setCookie("session", "abc123");
    try res.addCookiesToHeaders();

    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
    try std.testing.expectEqualStrings("Set-Cookie", res.headers.items[0].name);
    try std.testing.expectEqualStrings("session=abc123", res.headers.items[0].value);
    // owned_strings 持有：cookie 的 name、value（setCookie 时复制）
    // 以及序列化后的 "name=value" 字符串
    try std.testing.expectEqual(@as(usize, 3), res.owned_strings.items.len);
    // cookies 已清空，重复调用不会重复添加
    try res.addCookiesToHeaders();
    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
}

test "clientAcceptsGzip" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    try std.testing.expect(!res.clientAcceptsGzip());

    res.accept_encoding = "deflate, br";
    try std.testing.expect(!res.clientAcceptsGzip());

    res.accept_encoding = "gzip, deflate";
    try std.testing.expect(res.clientAcceptsGzip());

    res.accept_encoding = "gzip;q=1.0, br";
    try std.testing.expect(res.clientAcceptsGzip());

    res.accept_encoding = "GZIP";
    try std.testing.expect(res.clientAcceptsGzip());
}

test "compression enables compression flag and supports chaining" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);
    defer res.deinit();

    try std.testing.expectEqual(false, res.enable_compression);

    const returned = res.compression(true);
    try std.testing.expectEqual(true, res.enable_compression);
    try std.testing.expectEqual(true, returned.*.enable_compression);

    // Can disable too
    _ = res.compression(false);
    try std.testing.expectEqual(false, res.enable_compression);

    // Chaining returns self
    try std.testing.expectEqual(@as(usize, @intFromPtr(&res)), @intFromPtr(returned));
}

test "deinit cleanup doesn't crash" {
    const allocator = std.testing.allocator;
    var res = Self.init(allocator, undefined);

    // Add some data so deinit has work to do
    _ = try res.header("X-Test", "survive");
    _ = try res.setCookie("test", "cookie");
    try res.addCookiesToHeaders();

    // Should clean up without crashing or leaking (testing.allocator 会检测泄漏)
    res.deinit();
}
