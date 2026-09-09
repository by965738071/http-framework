//! HTTP 响应构建器
//!
//! 设计原则（回应 bug.md §8）：
//! - Response 只持有 `*std.Io.Writer`，不持有 `*http.Server.Request`。
//!   这让 Response 可以脱离 std.http 单独测试、可以换后端（HTTP/3、mock）。
//! - 测试时传 `std.Io.Writer.fixed(buf)` 即可，不需要起 http.Server harness。
//!
//! 注意：当前实现通过 `Sink` 接口抽象了"如何写响应行+头"和"如何写 body"，
//! 让 Response 不绑死 std.http 的 respond API。生产使用时由
//! ConnectionRunner 提供包装了 `request.respond()` 的 Sink。

const std = @import("std");
const http = std.http;
const mem = std.mem;

/// 响应输出接口 — 把 std.http 的 respond/respondStreaming 抽象出来。
///
/// Response 通过这个 trait 写响应，不知道背后是 std.http 还是别的后端。
/// 回应 bug.md §8："Response 绑死 std.http" 的问题。
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 发送完整响应（状态行 + 头 + body）。
        /// keep_alive=false 时底层应写 `Connection: close`（HTTP/1.1）。
        respond: *const fn (
            ptr: *anyopaque,
            status: http.Status,
            headers: []const http.Header,
            body: []const u8,
            keep_alive: bool,
        ) anyerror!void,

        /// 开始流式响应，返回 body writer。
        startStream: *const fn (
            ptr: *anyopaque,
            status: http.Status,
            headers: []const http.Header,
            content_length: ?u64,
            buffer: []u8,
            keep_alive: bool,
        ) anyerror!http.BodyWriter,
    };

    pub fn fromHttp(request: *http.Server.Request) Sink {
        const ctx = struct {
            fn respond(ptr: *anyopaque, status: http.Status, headers: []const http.Header, body: []const u8, keep_alive: bool) anyerror!void {
                const req: *http.Server.Request = @ptrCast(@alignCast(ptr));
                prepareBodyNone(req);
                try req.respond(body, .{
                    .status = status,
                    .extra_headers = headers,
                    .keep_alive = keep_alive,
                });
            }
            fn startStream(ptr: *anyopaque, status: http.Status, headers: []const http.Header, content_length: ?u64, buffer: []u8, keep_alive: bool) anyerror!http.BodyWriter {
                const req: *http.Server.Request = @ptrCast(@alignCast(ptr));
                prepareBodyNone(req);
                return req.respondStreaming(buffer, .{
                    .content_length = content_length,
                    .respond_options = .{
                        .status = status,
                        .extra_headers = headers,
                        .keep_alive = keep_alive,
                    },
                });
            }
        };
        return .{
            .ptr = @ptrCast(request),
            .vtable = &.{
                .respond = ctx.respond,
                .startStream = ctx.startStream,
            },
        };
    }

    /// std.http.Server.respond 内部的 discardBody（std/http/Server.zig）对
    /// "method 声明可带 body、但请求既没有 Content-Length 也没有
    /// Transfer-Encoding"的请求（如无 body 的 POST）会直接 assert 崩溃：
    ///   assert(transfer_encoding != .none or content_length != null)
    /// 这类请求实际上没有 body。respond 前先把 reader 状态标记为 body_none，
    /// 让 std 跳过 body 丢弃逻辑（std 对 body_none 状态直接返回 true）。
    fn prepareBodyNone(request: *http.Server.Request) void {
        const r = &request.server.reader;
        if (r.state != .received_head) return;
        if (!request.head.method.requestHasBody()) return;
        if (request.head.transfer_encoding == .none and request.head.content_length == null) {
            r.state = .body_none;
        }
    }

    /// 测试用 Sink：把响应写到固定缓冲区（不做 HTTP 编码，只记录 body）。
    /// 回应 bug.md §8：Response 不需要 http.Server harness 就能测试。
    pub fn testSink(writer: *std.Io.Writer) Sink {
        const ctx = struct {
            fn respond(ptr: *anyopaque, status: http.Status, headers: []const http.Header, body: []const u8, keep_alive: bool) anyerror!void {
                _ = headers;
                _ = keep_alive;
                const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
                // 简化：只写状态行 + body，不做 HTTP 编码
                try w.print("{s} {d}\r\n", .{ @tagName(status), @backingInt(status) });
                try w.writeAll(body);
            }
            fn startStream(ptr: *anyopaque, status: http.Status, headers: []const http.Header, content_length: ?u64, buffer: []u8, keep_alive: bool) anyerror!http.BodyWriter {
                _ = ptr;
                _ = status;
                _ = headers;
                _ = content_length;
                _ = buffer;
                _ = keep_alive;
                return error.NotSupportedInTestSink;
            }
        };
        return .{
            .ptr = @ptrCast(writer),
            .vtable = &.{
                .respond = ctx.respond,
                .startStream = ctx.startStream,
            },
        };
    }

    pub fn respond(self: Sink, status: http.Status, headers: []const http.Header, body: []const u8, keep_alive: bool) !void {
        return self.vtable.respond(self.ptr, status, headers, body, keep_alive);
    }

    pub fn startStream(self: Sink, status: http.Status, headers: []const http.Header, content_length: ?u64, buffer: []u8, keep_alive: bool) !http.BodyWriter {
        return self.vtable.startStream(self.ptr, status, headers, content_length, buffer, keep_alive);
    }
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age: ?i64 = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null,
};

pub const Response = struct {
    allocator: mem.Allocator,
    sink: Sink,
    status: http.Status = .ok,
    headers: std.ArrayList(http.Header) = .empty,
    cookies: std.ArrayList(Cookie) = .empty,
    sent: bool = false,
    /// 是否已真正写入 sink（flush 或直接 send 之后置位）。防止缓冲模式下
    /// 中间件 flush 一次、ConnectionRunner 再 flush 一次导致 double-send（wire 错帧）。
    flushed: bool = false,
    owned_strings: std.ArrayList([]u8) = .empty,
    /// 缓冲模式：sendResponse 只存不发送，flush() 才真正写入 sink。
    /// 中间件在 next() 之后添加的头能进入最终响应。
    buffered: bool = false,
    pending_body: ?[]const u8 = null,
    /// 是否保持 keep-alive。由 ConnectionRunner（唯一的 keep-alive 决策者）
    /// 在提交前设置。为 false 时底层 std 会写 `Connection: close`（P1-3）：
    /// 服务端主动断连（handler 报错 / 优雅关机）时不告知客户端，连接池
    /// 会把死连接当可复用 → 下一个请求 ECONNRESET。
    keep_alive: bool = true,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, sink: Sink) Self {
        return .{
            .allocator = allocator,
            .sink = sink,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
        self.headers.deinit(self.allocator);
        self.cookies.deinit(self.allocator);
    }

    // ── 缓冲模式（回应 bug.md §3：中间件在 handler 之后能修改响应）──────

    /// 启用缓冲模式：后续 text()/html()/json() 只存不发送。
    /// 必须在 next() 之前调用。next() 之后添加头，然后调 flush()。
    pub fn setBuffered(self: *Self) void {
        self.buffered = true;
    }

    /// 获取缓冲模式下的待发送 body。非缓冲模式或未设置返回 null。
    /// 中间件（如压缩）在 next() 之后用它检查 body。
    pub fn pendingBody(self: *const Self) ?[]const u8 {
        if (!self.buffered) return null;
        return self.pending_body;
    }

    /// 替换缓冲模式下的待发送 body。
    /// 用于中间件在 next() 之后修改 body（如压缩、签名）。
    /// 必须在 flush() 之前调用。返回旧 body（如有）。
    /// 非缓冲模式下与 `pendingBody` 对称：no-op 返回 null（R8）——直发模式下
    /// pending_body 永远不会被写出，静默写入只会造成「以为替换了」的假象。
    pub fn replacePendingBody(self: *Self, body: []const u8) ?[]const u8 {
        if (!self.buffered) return null;
        const old = self.pending_body;
        self.pending_body = body;
        return old;
    }

    /// 在缓冲模式下，把暂存的响应真正写入 sink。
    /// 非缓冲模式下，如果已经发送，什么都不做。
    pub fn flush(self: *Self) !void {
        // `flushed` 检查必须在最前面。它覆盖三种「已经上过 wire」的情况：
        //   1. 缓冲模式下已 flush 过（幂等）；
        //   2. 直发模式（sendResponse 已写 sink）；
        //   3. **流式响应**（stream() 已把状态行+头写进 sink）。
        // 第 3 种是关键：旧代码只在 !buffered 时提前返回，而 stream() 只置 sent
        // 不置 flushed。于是「缓冲中间件（compress/timing 会 setBuffered）+ 流式
        // handler（静态大文件 / Range）」的组合会走到下面的 `pending_body == null`
        // 分支，看到 sent==true 就再发一个空响应 —— 同一个请求两个 HTTP 响应，
        // keep-alive 客户端/反代会把第二个当成下一个请求的响应（响应队列投毒）。
        if (self.flushed) return;
        if (!self.buffered) return;
        // P2-7：缓冲模式下，中间件在 next() 之后调用 setCookie 设的 cookie 也要
        // 进入最终响应。sendResponse/redirect/stream 各自只在提交那一刻 addCookies
        // 一次，晚于它们的 setCookie（典型是外层中间件在 next() 返回后）会被静默丢弃。
        // flush 是缓冲响应真正上 wire 的唯一出口，在此补一次即可（addCookiesToHeaders
        // 会 clear cookies，幂等安全）。
        try self.addCookiesToHeaders();
        // 缓冲模式下，即使 handler 只设了 status/头而没写 body（pending_body
        // == null），只要响应已被标记发送（sent）也应发一个空 body 响应。
        const body = self.pending_body orelse {
            if (!self.sent) return; // 从未产生任何响应，不发
            self.flushed = true;
            try self.sink.respond(self.status, self.headers.items, "", self.keep_alive);
            return;
        };
        self.pending_body = null;
        self.flushed = true;
        try self.sink.respond(self.status, self.headers.items, body, self.keep_alive);
    }

    // ── 链式构建 ──────────────────────────────────────────────

    pub fn statusCode(self: *Self, code: http.Status) *Self {
        self.status = code;
        return self;
    }

    pub fn header(self: *Self, name: []const u8, value: []const u8) !*Self {
        // R1：name 必须是 RFC 9110 token——std 写头时 assert name 非空且不含 ':'
        // （Server.zig:340-341），违规不是返回错误而是**进程 panic**。框架层前置拦截。
        try validateHeaderName(name);
        try validateHeaderValue(value);
        const owned_name = try self.dupeOwned(name);
        const owned_value = try self.dupeOwned(value);
        try self.headers.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        return self;
    }

    /// 设置响应头（去重替换，bug.md §6 security_headers.zig:58-60）。
    /// 与 `header()`（追加）不同：同名头（大小写不敏感）已存在时覆盖其值，
    /// 而不是追加成一堆重复行。CSP 等多行叠加是「交集」语义，重复行会意外收紧
    /// 策略；`Server` 头重复会漏出后端实现。
    ///
    /// 所有权说明：新值用 `dupeOwned`（计入 owned_strings，deinit 统一释放）；
    /// 旧值指针替换后仍留在 owned_strings 中，deinit 时会一并释放，无 double-free。
    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !*Self {
        try validateHeaderName(name);
        try validateHeaderValue(value);
        // R6：替换第一条并删除其余同名头——只改第一条的话，经 header() 追加的
        // 重复行仍会原样上 wire，违背「去重替换」承诺（重复 CSP/Server 头）。
        var replaced = false;
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (std.ascii.eqlIgnoreCase(self.headers.items[i].name, name)) {
                if (!replaced) {
                    self.headers.items[i].value = try self.dupeOwned(value);
                    replaced = true;
                    i += 1;
                } else {
                    _ = self.headers.orderedRemove(i);
                }
            } else i += 1;
        }
        if (replaced) return self;
        return self.header(name, value);
    }

    pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !*Self {
        try validateCookieName(name);
        try validateCookieToken(value);
        const owned_name = try self.dupeOwned(name);
        const owned_value = try self.dupeOwned(value);
        try self.cookies.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        return self;
    }

    /// 设置完整 Cookie（带属性）。
    pub fn setCookieFull(self: *Self, cookie: Cookie) !*Self {
        try validateCookieName(cookie.name);
        try validateCookieToken(cookie.value);
        const owned_name = try self.dupeOwned(cookie.name);
        const owned_value = try self.dupeOwned(cookie.value);
        var c = cookie;
        c.name = owned_name;
        c.value = owned_value;
        // path/domain/same_site 也必须校验 CRLF，否则可注入响应头。
        if (c.path) |p| {
            try validateHeaderValue(p);
            c.path = try self.dupeOwned(p);
        }
        if (c.domain) |d| {
            try validateHeaderValue(d);
            c.domain = try self.dupeOwned(d);
        }
        if (c.same_site) |ss| {
            try validateHeaderValue(ss);
            c.same_site = try self.dupeOwned(ss);
        }
        try self.cookies.append(self.allocator, c);
        return self;
    }

    // ── 响应发送 ──────────────────────────────────────────────

    pub fn text(self: *Self, content: []const u8) !void {
        try self.sendResponse(content, "text/plain; charset=utf-8");
    }

    pub fn html(self: *Self, content: []const u8) !void {
        try self.sendResponse(content, "text/html; charset=utf-8");
    }

    /// 用指定 Content-Type 发送原始字节。
    pub fn raw(self: *Self, content: []const u8, content_type: []const u8) !void {
        try self.sendResponse(content, content_type);
    }

    pub fn json(self: *Self, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{},
        };
        try stringify.write(value);
        try self.sendResponse(out.written(), "application/json");
    }

    /// 重定向。status 可为 301/302/303/307/308（默认 302 found）。
    /// 303 用于 POST 后重定向到 GET；307/308 保留方法。
    pub fn redirectStatus(self: *Self, location: []const u8, status: http.Status) !void {
        if (self.sent) return error.AlreadyResponded;
        try self.addCookiesToHeaders();
        _ = try self.header("Location", location);
        self.sent = true;
        // R5：status 同步进 self.status——lifecycle 的 request_end 读 res.status，
        // 旧代码直发分支不改，导致 302/303 在日志里显示为默认 200。
        self.status = status;
        if (self.buffered) {
            self.pending_body = "";
            return;
        }
        try self.sink.respond(status, self.headers.items, "", self.keep_alive);
        // R3：直发已上 wire，与 sendResponse 同样置 flushed。
        self.flushed = true;
    }

    /// 便捷：permanent=true → 301，false → 302。
    pub fn redirect(self: *Self, location: []const u8, permanent: bool) !void {
        return self.redirectStatus(location, if (permanent) .moved_permanently else .found);
    }

    /// 开始流式响应。
    /// `buffer` 由调用方提供（通常栈数组），框架不分配。
    pub fn stream(self: *Self, buffer: []u8, options: StreamOptions) !Stream {
        if (self.sent) return error.AlreadyResponded;
        // 缓冲中间件（Compress/Timing 会 setBuffered）假设能在 next() 返回后再改头，
        // 但流式响应会把状态行+头立即写进 sink —— 此后追加的头（如 Timing 的
        // X-Response-Time-ns）永远上不了 wire（P1-7）。安全头（CSP/HSTS）不受影响，
        // 因为 SecurityHeaders 在 next() 之前加头（已在 self.headers 里）。这里记一条 warn
        // 方便定位“流式响应丢了 handler 之后追加的头”这类可观测性问题。
        if (self.buffered) {
            std.log.warn("Response.stream() called in buffered mode: headers added after the handler (e.g. timing) will not reach the wire (bug.md P1-7)", .{});
        }
        try self.addCookiesToHeaders();
        try self.appendHeaderIfAbsent("Content-Type", options.content_type);

        // 注意：sent/flushed 必须在调 startStream **之前**置位（P0-2 回归测试依赖）——
        // startStream 失败时状态行/头可能已部分上 wire；若留 sent==false，
        // ErrorRenderer / connection 层兜底会再补一个 500 → 双响应投毒。
        self.sent = true;
        // 流式响应已经把状态行 + 头直接交给 sink（startStream）。此后任何 flush()
        // 都必须是 no-op：缓冲中间件（CompressMiddleware / TimingMiddleware 会
        // setBuffered）在 next() 返回后会调 flush()，而 ConnectionRunner 结尾还会
        // 再调一次。不置位 flushed 的话它们会补发一个完整的空响应
        // → 同一请求两个 HTTP 响应 → keep-alive 响应队列投毒。
        self.flushed = true;

        const body = try self.sink.startStream(
            self.status,
            self.headers.items,
            options.content_length,
            buffer,
            self.keep_alive,
        );
        return .{ .body = body };
    }

    pub const StreamOptions = struct {
        content_length: ?u64 = null,
        content_type: []const u8 = "application/octet-stream",
    };

    pub const Stream = struct {
        body: http.BodyWriter,

        pub fn writer(self: *Stream) *std.Io.Writer {
            return &self.body.writer;
        }

        pub fn writeAll(self: *Stream, bytes: []const u8) !void {
            try self.body.writer.writeAll(bytes);
        }

        pub fn print(self: *Stream, comptime fmt: []const u8, args: anytype) !void {
            try self.body.writer.print(fmt, args);
        }

        pub fn flush(self: *Stream) !void {
            try self.body.flush();
        }

        pub fn isEliding(self: *const Stream) bool {
            return self.body.isEliding();
        }

        pub fn end(self: *Stream) !void {
            if (self.body.isEliding()) {
                try self.body.writer.flush();
                switch (self.body.state) {
                    .content_length => |*len| len.* = 0,
                    else => {},
                }
            }
            try self.body.end();
        }
    };

    // ── 内部辅助 ──────────────────────────────────────────────

    fn sendResponse(self: *Self, content: []const u8, content_type: []const u8) !void {
        if (self.sent) return error.AlreadyResponded;
        try self.addCookiesToHeaders();
        try self.appendHeaderIfAbsent("Content-Type", content_type);
        self.sent = true;
        if (self.buffered) {
            // 缓冲模式：只存不发送，等 flush() 再写入 sink。
            // 必须拷贝 body——handler 常在返回时释放自己的 body 缓冲区
            // （如 `defer allocator.free(html)`），而 flush() 发生在外层中间件、
            // 晚于 handler 栈帧。若只存借用切片，flush 时就是 use-after-free
            // （小 body 侥幸读到陈旧内存，大 body 页已归还内核 → EFAULT/WriteFailed）。
            // owned_strings 由 response.allocator（请求 arena）持有，flush 之后、
            // deinit 之时释放，生命周期正确。
            self.pending_body = try self.dupeOwned(content);
            return;
        }
        try self.sink.respond(self.status, self.headers.items, content, self.keep_alive);
        // R3：直发已真正写入 sink，同步置 flushed——否则后续违规 setBuffered()
        // 会让 flush() 走 sent&&!pending 分支补发第二个响应（wire 双响应投毒）。
        self.flushed = true;
    }

    fn dupeOwned(self: *Self, s: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(copy);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }

    fn hasHeader(self: *const Self, name: []const u8) bool {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        }
        return false;
    }

    fn appendHeaderIfAbsent(self: *Self, name: []const u8, value: []const u8) !void {
        if (self.hasHeader(name)) return;
        _ = try self.header(name, value);
    }

    fn addCookiesToHeaders(self: *Self) !void {
        for (self.cookies.items) |cookie| {
            const cookie_str = try self.buildCookieString(cookie);
            self.owned_strings.append(self.allocator, cookie_str) catch |e| {
                self.allocator.free(cookie_str);
                return e;
            };
            try self.headers.append(self.allocator, .{
                .name = "Set-Cookie",
                .value = cookie_str,
            });
        }
        self.cookies.clearRetainingCapacity();
    }

    fn buildCookieString(self: *Self, cookie: Cookie) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, cookie.name);
        try buf.append(self.allocator, '=');
        try buf.appendSlice(self.allocator, cookie.value);
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
        if (cookie.secure) try buf.appendSlice(self.allocator, "; Secure");
        if (cookie.http_only) try buf.appendSlice(self.allocator, "; HttpOnly");
        if (cookie.same_site) |ss| {
            try buf.appendSlice(self.allocator, "; SameSite=");
            try buf.appendSlice(self.allocator, ss);
        }
        return buf.toOwnedSlice(self.allocator);
    }
};

fn validateHeaderValue(s: []const u8) !void {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeaderValue;
    }
}

/// 校验 cookie value：除 CRLF/NUL 外，还禁止 `;` `,` 空白（RFC 6265 §4.1.1），
/// 防止通过值里的 `;` 注入 Domain/Path/Secure 等属性（cookie 属性注入）。
/// name 走更严格的 validateCookieName。
fn validateCookieToken(s: []const u8) !void {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeaderValue;
        if (c == ';' or c == ',' or c == ' ' or c == '\t') return error.InvalidCookieValue;
    }
}

/// RFC 9110 tchar（token 字符集）。
fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => true,
        else => false,
    };
}

/// 头名校验（R1）：std 对 header name 有硬 assert（非空、不含 ':'，
/// Server.zig:340-341），违规会 panic 整个进程；含空格/CR/LF 还会错帧或注入。
/// 一律收敛到 RFC 9110 token 校验，在框架层报错，绝不上 wire。
fn validateHeaderName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidHeaderName;
    for (name) |c| {
        if (!isTokenChar(c)) return error.InvalidHeaderName;
    }
}

/// cookie name 必须是严格 RFC 6265 token（R7）：'=' 是 cookie-pair 分隔符，
/// 出现在 name 里会让客户端把 "a=b" 解析成 name="a"、value="b=v"。
fn validateCookieName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidCookieName;
    for (name) |c| {
        if (!isTokenChar(c)) return error.InvalidCookieName;
    }
}

// ===========================================================================
// Tests — 回应 bug.md §8：Response 可以脱离 http.Server 单独测试
// ===========================================================================

test "Response.text writes status line and body via testSink" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    try res.statusCode(.ok).text("hello world");
    const written = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello world") != null);
}

test "Response.header rejects CR/LF injection" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    // name 含 CR/LF：现在由 validateHeaderName（R1）拦截，报 InvalidHeaderName
    try std.testing.expectError(error.InvalidHeaderName, res.header("Evil\r\nInjected", "value"));
    // value 含 CR/LF：仍由 validateHeaderValue 拦截
    try std.testing.expectError(error.InvalidHeaderValue, res.header("X-Evil", "v\r\nInjected"));
}

test "Response.json serializes struct" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    try res.json(.{ .message = "hi", .code = 42 });
    const written = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "42") != null);
}

test "Response.redirect sets 302" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    try res.redirect("/elsewhere", false);
    const written = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "found") != null);
}

test "Response.redirect in buffered mode keeps 302 status on flush" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    res.setBuffered();
    try res.redirect("/elsewhere", true);
    try res.flush();
    const written = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "moved_permanently") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "301") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, " ok ") == null);
}

test "Response cannot send twice" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    try res.text("first");
    try std.testing.expectError(error.AlreadyResponded, res.text("second"));
}

test "Response buffered mode delays send until flush" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, Sink.testSink(&writer));
    defer res.deinit();

    res.setBuffered();
    try res.text("hello");
    // 响应还没写入 buf
    try std.testing.expect(writer.end == 0);
    // handler 之后加头
    _ = try res.header("X-After", "yes");
    // 头已进入 headers 列表
    var found_header = false;
    for (res.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "X-After") and std.mem.eql(u8, h.value, "yes")) {
            found_header = true;
            break;
        }
    }
    try std.testing.expect(found_header);
    try res.flush();
    // 现在写入了 body
    const written = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") != null);
}

// ── 回归测试：缓冲模式 + 流式响应不得双发（P0-2）──────────────────────────
//
// 这是本轮最严重的 wire 层缺陷：`stream()` 只置 sent 不置 flushed，缓冲中间件
// （CompressMiddleware / TimingMiddleware 都会 setBuffered）在 next() 之后调
// flush()，会看到 `pending_body == null && sent == true` 而补发一个完整的空响应
// → 同一个请求两个 HTTP 响应 → keep-alive 客户端/反代把第二个当成下一个请求的
// 响应（响应队列投毒 / 缓存投毒）。
//
// 用一个会统计 respond/startStream 调用次数的 Sink 来断言"提交只能发生一次"。
const CountingSink = struct {
    respond_calls: usize = 0,
    stream_calls: usize = 0,

    fn respondImpl(ptr: *anyopaque, _: http.Status, _: []const http.Header, _: []const u8, _: bool) anyerror!void {
        const self: *CountingSink = @ptrCast(@alignCast(ptr));
        self.respond_calls += 1;
    }
    fn startStreamImpl(ptr: *anyopaque, _: http.Status, _: []const http.Header, _: ?u64, _: []u8, _: bool) anyerror!http.BodyWriter {
        const self: *CountingSink = @ptrCast(@alignCast(ptr));
        self.stream_calls += 1;
        // 不需要真的写 wire：本测试只关心"提交次数"。
        return error.StreamNotNeededInTest;
    }
    fn sink(self: *CountingSink) Sink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{ .respond = respondImpl, .startStream = startStreamImpl },
        };
    }
};

test "缓冲模式下 stream() 之后 flush() 不再补发第二个响应（P0-2 回归）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    // 模拟 CompressMiddleware / TimingMiddleware
    res.setBuffered();

    // handler 走流式响应（静态大文件 / Range 请求）。
    // 本测试的 sink 在 startStream 里返回错误，但 stream() 在调用 startStream 之前
    // 就已经把 sent/flushed 置好了 —— 这正是我们要断言的状态。
    var stream_buf: [64]u8 = undefined;
    _ = res.stream(&stream_buf, .{ .content_length = 100 }) catch {};

    try std.testing.expectEqual(@as(usize, 1), counter.stream_calls);
    try std.testing.expect(res.sent);
    try std.testing.expect(res.flushed); // ← 修复的核心：stream() 必须置位 flushed

    // 中间件收尾 flush + ConnectionRunner 兜底 flush：都必须是 no-op。
    try res.flush();
    try res.flush();
    try std.testing.expectEqual(@as(usize, 0), counter.respond_calls);
}

test "非缓冲模式下 stream() 之后 flush() 也不补发（P0-2 回归）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    var stream_buf: [64]u8 = undefined;
    _ = res.stream(&stream_buf, .{}) catch {};
    try res.flush();
    try std.testing.expectEqual(@as(usize, 0), counter.respond_calls);
}

test "缓冲模式 flush 幂等：只 respond 一次（P0-2 回归）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    res.setBuffered();
    try res.text("hello");
    try res.flush();
    try res.flush();
    try res.flush();
    try std.testing.expectEqual(@as(usize, 1), counter.respond_calls);
}

// ── R1-R8 回归测试（response.zig 审查轮）────────────────────────────────

test "header/setHeader 拒绝非法头名，避免 std assert panic（R1）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    // std Server.zig:340-341 对 name 硬 assert：非空、不含 ':'。空格名会错帧。
    try std.testing.expectError(error.InvalidHeaderName, res.header("X-Foo: Bar", "v"));
    try std.testing.expectError(error.InvalidHeaderName, res.header("", "v"));
    try std.testing.expectError(error.InvalidHeaderName, res.header("Bad Name", "v"));
    try std.testing.expectError(error.InvalidHeaderName, res.setHeader("Bad:Name", "v"));
    // 合法 RFC 9110 token 名必须通过
    _ = try res.header("X-Good-Name_1", "v");
    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
}

test "直发后 flush 幂等：违规 setBuffered 也不补发第二个响应（R3）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    try res.text("hi"); // 直发：respond 一次
    try std.testing.expectEqual(@as(usize, 1), counter.respond_calls);
    // 契约违例场景：直发之后才 setBuffered。修复前 flushed==false，
    // flush() 会从 sent&&!pending 分支补发空响应 → wire 双响应。
    res.setBuffered();
    try res.flush();
    try res.flush();
    try std.testing.expectEqual(@as(usize, 1), counter.respond_calls);
}

test "redirectStatus 直发模式同步 self.status 并置 flushed（R5/R3）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    try res.redirectStatus("/next", .see_other);
    // lifecycle 的 request_end 读 res.status：修复前直发分支不更新，日志显示 200
    try std.testing.expectEqual(http.Status.see_other, res.status);
    try std.testing.expectEqual(@as(usize, 1), counter.respond_calls);
    try std.testing.expect(res.flushed);
}

test "setHeader 替换全部同名头而非仅第一条（R6）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    _ = try res.header("X-Dup", "1");
    _ = try res.header("x-dup", "2");
    _ = try res.header("X-DUP", "3");
    _ = try res.setHeader("X-Dup", "final");

    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
    try std.testing.expectEqualStrings("final", res.headers.items[0].value);
}

test "setCookie 拒绝 name 含 '=' 等非 token 字符（R7）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    try std.testing.expectError(error.InvalidCookieName, res.setCookie("a=b", "v"));
    try std.testing.expectError(error.InvalidCookieName, res.setCookie("na me", "v"));
    // value 含 '=' 合法（RFC 6265 cookie-value 允许）
    _ = try res.setCookie("sid", "a=b");
    try std.testing.expectEqual(@as(usize, 1), res.cookies.items.len);
}

test "replacePendingBody 非缓冲模式下不生效（R8，与 pendingBody 对称）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    // 直发模式：写入无效，返回 null
    try std.testing.expect(res.replacePendingBody("x") == null);
    try std.testing.expect(res.pending_body == null);
    // 缓冲模式：正常替换
    res.setBuffered();
    try res.text("old");
    const old = res.replacePendingBody("new");
    try std.testing.expect(old != null);
    try std.testing.expectEqualStrings("new", res.pending_body.?);
}

test "缓冲模式 status-only 响应：connection 层兜底 text(\"\") + flush 能写出（R2）" {
    var counter = CountingSink{};
    var res = Response.init(std.testing.allocator, counter.sink());
    defer res.deinit();

    // 模拟 204 No Content handler：只设 status，从不写 body。
    // 缓冲模式（Timing/Compress 会开）下 flush() 对 !sent 是 no-op，
    // 依赖 connection.zig 兜底改调 text("")；这里断言兜底路径可写出响应。
    res.setBuffered();
    _ = res.statusCode(.no_content);
    if (!res.sent) try res.text("");
    try res.flush();
    try std.testing.expectEqual(@as(usize, 1), counter.respond_calls);
}
test {
    std.testing.refAllDecls(@This());
}
