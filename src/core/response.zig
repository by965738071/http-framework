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

/// 流式响应已发出响应头但尚未收尾（`stream()` 调过、`Stream.end()` 没调过）。
///
/// chunked 编码的报文没有 `0\r\n\r\n` 结束块就是不完整的，客户端会一直等下去。
/// Server 在请求收尾时据此强制关闭连接，而不是把半截报文留在 keep-alive 连接上
/// 污染下一个请求。
stream_open: bool = false,

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
// 流式响应
// =========================================================================

/// `stream()` 的选项。
pub const StreamOptions = struct {
    /// 响应体总长度。
    ///
    /// - 给值 → 走 `Content-Length`，必须精确写满这么多字节，否则 `end()` 触发断言。
    /// - null → 走 `Transfer-Encoding: chunked`，长度未知时用这个。
    content_length: ?u64 = null,

    /// `Content-Type`。仅在调用方没有通过 `header()` 显式设置过时才生效。
    content_type: []const u8 = "application/octet-stream",
};

/// 流式响应句柄。
///
/// # 不可移动
///
/// 内部的 `std.Io.BodyWriter` 靠 `@fieldParentPtr` 从 writer 反查自身，
/// 因此 `Stream` 一旦创建就**不能再被复制或移动**——必须放在一个稳定地址上：
///
/// ```zig
/// var s = try res.stream(&buf, .{});   // ok：s 是稳定的局部变量
/// const s2 = s;                        // 错：s2.writer 的 fieldParentPtr 指向 s
/// ```
///
/// 把 `*Stream` 传给别的函数是安全的。
pub const Stream = struct {
    body: http.BodyWriter,
    response: *Self,

    /// 底层 writer，可直接交给 `std.json.Stringify`、`std.fmt` 等任何
    /// 接受 `*std.Io.Writer` 的 API。
    pub fn writer(self: *Stream) *std.Io.Writer {
        return &self.body.writer;
    }

    pub fn writeAll(self: *Stream, bytes: []const u8) !void {
        try self.body.writer.writeAll(bytes);
    }

    pub fn print(self: *Stream, comptime fmt: []const u8, args: anytype) !void {
        try self.body.writer.print(fmt, args);
    }

    /// 把已缓冲的数据推给客户端。SSE / 长轮询这类需要"立刻可见"的场景要显式调。
    pub fn flush(self: *Stream) !void {
        try self.body.flush();
    }

    /// 当前请求是 HEAD——响应体会被底层丢弃。
    ///
    /// 返回 true 时可以跳过生成响应体的昂贵工作（读文件、查库），
    /// 但**仍然要照常调用 `end()`**。
    ///
    /// 指定了 `content_length` 时跳过写入也是安全的：`end()` 会把长度计数
    /// 补平。响应头里的 `Content-Length` 保持原值不变——HEAD 的语义就是
    /// "告诉我 GET 会拿到什么"，这个值必须照实给。
    pub fn isEliding(self: *const Stream) bool {
        return self.body.isEliding();
    }

    /// 收尾：写结束块（chunked）或校验长度（content-length），并 flush。
    ///
    /// 必须调用，否则连接会被 Server 判定为不可复用而关闭。
    pub fn end(self: *Stream) !void {
        // HEAD + content_length 的坑：`isEliding()` 的用法就是"跳过昂贵的
        // 响应体生成"，可 std 的 `BodyWriter.end()` 会断言剩余长度已被写满
        // （eliding 模式下写入只是丢弃，但仍然在扣这个计数）。照文档提示
        // 跳过写入的 handler 会把整个进程 assert 掉——一个合法的 HEAD 请求
        // 不该能打崩服务器。
        //
        // 响应体本来就一个字节都不会发出去，这里直接把计数清零。
        if (self.body.isEliding()) {
            // 先走完缓冲区（eliding 下只是丢弃并扣减），否则清零后再 flush
            // 会把计数减成负数（u64 下溢）
            try self.body.writer.flush();
            switch (self.body.state) {
                .content_length => |*len| len.* = 0,
                else => {},
            }
        }
        try self.body.end();
        self.response.stream_open = false;
    }
};

/// 开始一个流式响应，用于大文件下载、SSE、流式 JSON 等响应体不宜整个进内存的场景。
///
/// `buffer` 由调用方提供（通常是栈数组），框架不分配：分块头部的十六进制长度由
/// `std.Io.BodyWriter` 直接写进连接的输出缓冲，全程零堆分配。
/// buffer 越大，`drain` 调用越少；几 KiB 通常够用。
///
/// `buffer` 必须活到 `Stream.end()` 返回为止。
///
/// # 与 `compression()` 的关系
///
/// 流式响应**不做自动 gzip**——那需要把整个响应体攒起来才能压。
/// 需要压缩就自己设 `Content-Encoding` 并写入已压缩的字节。
///
/// # 示例
///
/// ```zig
/// var buf: [4096]u8 = undefined;
/// var s = try res.statusCode(.ok).stream(&buf, .{ .content_type = "text/plain" });
/// for (0..1000) |i| try s.print("line {d}\n", .{i});
/// try s.end();
/// ```
pub fn stream(self: *Self, buffer: []u8, options: StreamOptions) !Stream {
    if (self.responded) return error.AlreadyResponded;

    try self.addCookiesToHeaders();
    try self.appendHeaderIfAbsent("Content-Type", options.content_type);
    try self.appendServerHeader();

    // 先置位再发头：respondStreaming 一旦写出状态行，这个响应就已经开始了，
    // 即使它中途失败也不能让上层再 respond 一次。
    self.responded = true;
    self.stream_open = true;

    const body = try self.request.respondStreaming(buffer, .{
        .content_length = options.content_length,
        .respond_options = .{
            .status = self.status,
            .extra_headers = self.headers.items,
        },
    });

    return .{ .body = body, .response = self };
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

/// 流式响应测试脚手架。
///
/// 用两个固定缓冲区伪造一条连接：`Reader.fixed` 喂请求头，`Writer.fixed`
/// 接住服务端写出的全部字节（它的 flush 是 no-op，所以 `wire()` 能拿到完整报文）。
/// 这样测试断言的是真实 wire 格式，而不是内部状态。
///
/// 必须 `var h: StreamHarness = undefined; try h.init(...)` 原地初始化——
/// `server` 持有 `&self.in` / `&self.out`，harness 不能在 init 后被移动。
const StreamHarness = struct {
    in: std.Io.Reader,
    out: std.Io.Writer,
    server: http.Server,
    request: http.Server.Request,

    fn init(self: *StreamHarness, raw_head: []const u8, out_storage: []u8) !void {
        self.in = .fixed(raw_head);
        self.out = .fixed(out_storage);
        self.server = http.Server.init(&self.in, &self.out);
        self.request = try self.server.receiveHead();
    }

    fn wire(self: *const StreamHarness) []const u8 {
        return self.out.buffered();
    }

    /// 报文头尾分割处之后的内容（即响应体部分）
    fn bodyPart(self: *const StreamHarness) []const u8 {
        const w = self.wire();
        const idx = std.mem.indexOf(u8, w, "\r\n\r\n") orelse return "";
        return w[idx + 4 ..];
    }
};

test "stream - chunked framing and terminator" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("GET /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.statusCode(.ok).stream(&body_buf, .{ .content_type = "text/plain" });
    try s.writeAll("hello");
    try s.print(" {s}", .{"world"});
    try s.end();

    const w = h.wire();
    try std.testing.expect(std.mem.startsWith(u8, w, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, w, "transfer-encoding: chunked\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "Content-Type: text/plain\r\n") != null);
    // 没有 content-length：长度未知才用 chunked
    try std.testing.expect(std.mem.indexOf(u8, w, "content-length:") == null);

    // 全部内容缓冲在 body_buf 里，end() 时一次冲出，所以是单个 chunk（0xa = 10 字节）
    const body = h.bodyPart();
    try std.testing.expect(std.mem.indexOf(u8, body, "hello world") != null);
    // 结束块必须在，否则客户端会一直等
    try std.testing.expect(std.mem.endsWith(u8, body, "0\r\n\r\n"));
}

test "stream - content_length path omits chunked framing" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("GET /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{ .content_length = 11, .content_type = "text/plain" });
    try s.writeAll("hello ");
    try s.writeAll("world");
    try s.end();

    const w = h.wire();
    try std.testing.expect(std.mem.indexOf(u8, w, "content-length: 11\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "transfer-encoding") == null);
    // 定长模式下响应体就是裸字节，没有分块头
    try std.testing.expectEqualStrings("hello world", h.bodyPart());
}

test "stream - end() clears stream_open so connection stays reusable" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("GET /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    try std.testing.expect(!res.responded);
    try std.testing.expect(!res.stream_open);

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{});
    // 发头之后：已响应，且流还开着
    try std.testing.expect(res.responded);
    try std.testing.expect(res.stream_open);

    try s.writeAll("x");
    try s.end();

    try std.testing.expect(!res.stream_open);
}

test "stream - second send attempt is rejected" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("GET /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{});
    try s.writeAll("x");
    try s.end();

    // 流已经发完，再走普通响应会写出第二份报文 → 必须拒绝
    try std.testing.expectError(error.AlreadyResponded, res.text("again"));

    var body_buf2: [64]u8 = undefined;
    try std.testing.expectError(error.AlreadyResponded, res.stream(&body_buf2, .{}));
}

test "stream - HEAD request elides body but keeps headers" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("HEAD /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{ .content_length = 5, .content_type = "text/plain" });
    // handler 可以据此跳过昂贵的响应体生成
    try std.testing.expect(s.isEliding());
    try s.writeAll("hello");
    try s.end();

    const w = h.wire();
    // 头部照常（含 content-length，客户端要靠它知道 GET 会拿到多大）
    try std.testing.expect(std.mem.indexOf(u8, w, "content-length: 5\r\n") != null);
    // 响应体被丢弃
    try std.testing.expectEqualStrings("", h.bodyPart());
}

test "stream - HEAD with content_length may skip writing entirely" {
    // 回归测试：handler 按 isEliding() 的提示跳过响应体生成，同时又声明了
    // content_length。std 的 BodyWriter.end() 在这种组合下会 assert 崩掉
    // 整个进程（曾经真的把 example server 打挂过）。
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("HEAD /report HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{ .content_length = 8000 });
    try std.testing.expect(s.isEliding());
    // 一个字节都不写，直接收尾
    try s.end();

    // Content-Length 照实声明（HEAD 要如实告知 GET 会拿到多大）
    try std.testing.expect(std.mem.indexOf(u8, h.wire(), "content-length: 8000\r\n") != null);
    try std.testing.expectEqualStrings("", h.bodyPart());
    // 正常收尾 → 连接仍可复用
    try std.testing.expect(!res.stream_open);
}

test "stream - HEAD with content_length and partial write still ends cleanly" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("HEAD /report HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{ .content_length = 8000 });
    // 写了一部分就放弃：清零逻辑必须先把缓冲区走完，否则计数会下溢
    try s.writeAll("partial");
    try s.end();

    try std.testing.expectEqualStrings("", h.bodyPart());
    try std.testing.expect(!res.stream_open);
}

test "stream - cookies and Server header are emitted like normal responses" {
    const allocator = std.testing.allocator;

    var out_storage: [4096]u8 = undefined;
    var h: StreamHarness = undefined;
    try h.init("GET /dl HTTP/1.1\r\nHost: x\r\n\r\n", &out_storage);

    var res = Self.init(allocator, &h.request);
    defer res.deinit();
    res.server_name = "test-server";
    _ = try res.setCookie("sid", "abc");

    var body_buf: [64]u8 = undefined;
    var s = try res.stream(&body_buf, .{});
    try s.end();

    const w = h.wire();
    try std.testing.expect(std.mem.indexOf(u8, w, "Set-Cookie: sid=abc\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "Server: test-server\r\n") != null);
    // 未指定 content_type 时用默认值
    try std.testing.expect(std.mem.indexOf(u8, w, "Content-Type: application/octet-stream\r\n") != null);
}

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
