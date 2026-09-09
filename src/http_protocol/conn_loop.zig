//! 连接级 keep-alive 状态机
//!
//! 设计原则（回应 bug.md §7）：
//! 把"HTTP 状态机 + keep-alive 循环"从 Server 里拆出来。这一层只负责
//! "从连接上循环读取请求、产出 Request 对象"，不负责 dispatch /
//! handler / middleware / 信号。
//!
//! ConnectionLoop 包装 std.http.Server，每次 `next()` 返回一个
//! `http_protocol.Request`。连接关闭时返回 null。

const std = @import("std");
const http = std.http;
const protocol = @import("request.zig");

pub const ConnectionLoop = struct {
    server: *http.Server,
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    /// `server` 必须由调用方（ConnectionRunner）创建并持有。
    /// `arena` 是请求级 arena——**next() 不做 reset**：回收由 ConnectionRunner
    /// 的 arenas.endRequest() 按 request_arena_retain_bytes 带上限地进行，
    /// next() 只往上面分配 Server.Request 外壳。
    pub fn init(server: *http.Server, arena: *std.heap.ArenaAllocator) Self {
        return .{ .server = server, .arena = arena };
    }

    /// next() 的返回值。
    /// `raw` 是指向 arena 分配的 std.http.Server.Request，ConnectionRunner 用它构建 Sink
    /// 和读取 streaming body。arena 分配保证其生命周期覆盖整个请求处理过程。
    /// 调用方必须在处理完这个请求（发送完响应）之后才能再次调 next()。
    pub const NextResult = struct {
        parsed: protocol.Request,
        raw: *http.Server.Request,
    };

    /// 读取下一个请求。
    ///
    /// 返回 `null` 表示连接已结束（请求边界正常关闭 / head 半截断开 /
    /// 传输层错误或读超时）—— 这些情况下**不要**向连接写任何响应。
    /// 返回 `error.ProtocolError` 表示客户端发了坏请求，应当回 400 并关连接。
    /// 返回 `error.HeadTooLarge` 表示请求头超出读缓冲，应当回 431 并关连接。
    /// 第四类：`error.OutOfMemory`（Server.Request 外壳 / Request.init 复制
    /// head）原样传播——connection.zig 的契约是记日志后直接关连接、**不写
    /// 响应**；这是刻意的，OOM 下响应本身多半也分配不出来。
    pub fn next(self: *Self) !?NextResult {
        // 不在这里 reset arena：ConnectionRunner 的 arenas.endRequest() 已经按
        // request_arena_retain_bytes 做了带上限的 reset。这里再来一次
        // `.retain_capacity`（按历史峰值预热、无上限）会把那个上限重新破坏掉。
        //
        // 在 arena 上分配 http_request，生命周期绑定请求 arena
        const http_request = try self.arena.allocator().create(http.Server.Request);
        http_request.* = self.server.receiveHead() catch |err| switch (classifyHeadError(err)) {
            .connection_closed => return null,
            .head_too_large => return error.HeadTooLarge,
            .protocol_error => return error.ProtocolError,
        };

        const parsed = try protocol.Request.init(self.arena.allocator(), http_request);
        return .{ .parsed = parsed, .raw = http_request };
    }

    /// 检查请求是否可以继续复用连接（keep-alive）。
    ///
    /// 注意：std 的 `Server.Request.Head` 自带 `keep_alive` 字段，但它对
    /// close 的判断是**整值相等**（`value != "close"`，`Connection: keep-alive,
    /// close` 会被 std 判成可复用）——不符合 RFC 9110。本函数的 token 判定才是
    /// 本框架的权威来源（ConnectionRunner 用的就是它）；不要再从 `raw` 上读
    /// std 那个字段，两者语义不一致。
    pub fn shouldKeepAlive(self: *const Self, req: *const protocol.Request) bool {
        _ = self;
        // RFC 9110 §7.6.1：Connection 是列表型头，允许拆成多个头行——
        // getHeader 只返回第一个，`Connection: keep-alive` + `Connection: close`
        // 会漏掉 close。必须扫全部 Connection 出现。
        var saw_close = false;
        var saw_keepalive = false;
        var it = std.http.HeaderIterator.init(req.head_bytes);
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "Connection")) continue;
            if (hasToken(h.value, "close")) saw_close = true;
            if (hasToken(h.value, "keep-alive")) saw_keepalive = true;
        }
        // close 优先（RFC 9110 §7.6.1.4）
        if (saw_close) return false;
        // HTTP/1.0 默认 close，除非显式 Connection: keep-alive
        if (req.version == .@"HTTP/1.0") return saw_keepalive;
        // HTTP/1.1 默认 keep-alive
        return true;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // server 和 arena 由调用方管理
    }
};

/// `next()` 对 receiveHead 错误的处置分类。
const HeadAction = enum {
    /// 连接正常结束：不是错误，**绝不能**向连接写响应。
    connection_closed,
    /// 请求头超出读缓冲 → 431 Request Header Fields Too Large（RFC 6585 §5）+ 关连接。
    head_too_large,
    /// 客户端发了坏请求 → 400 Bad Request + 关连接（framing 已不可信）。
    protocol_error,
};

/// 对 receiveHead 错误分类。**刻意用 std 的具体错误集做 exhaustive switch**
/// 而非 `anyerror`：
///   - std 的 `Server.receiveHead` 会把 `Head.parse` 的全部细节错误
///     （UnknownHttpMethod、InvalidContentLength、MissingFinalNewline 等）
///     统一折叠成 `HttpHeadersInvalid`（std 文档：想看细节可拿 head_buffer
///     重放 `Head.parse`）。旧版分类函数把那些细节错误名逐个列出，在
///     `switch (anyerror)` 下既不报错也永远不会命中——纯粹的假覆盖。
///   - 现在若 std 增删该错误集成员，这里编译期直接报错，强制重审。
fn classifyHeadError(err: http.Server.ReceiveHeadError) HeadAction {
    return switch (err) {
        // `HttpConnectionClosing` 是 std 明确定义的「客户端在请求边界正常关闭
        // keep-alive 连接」（std/http.zig: "The client sent 0 bytes of headers
        // before closing the stream."）。旧代码没把它列进来，导致每一个正常关闭
        // 的连接都会收到一个伪造的 400 Bad Request（已实测：client
        // shutdown(SHUT_WR) 后仍收到 78 字节的 400）。
        // `HttpRequestTruncated`：head 只收了一半就断，无法也无须回应。
        // `ReadFailed`：传输层错误或读超时（zio 后端把两者都归到它），对端多半
        // 已经走了，写响应只会污染 wire、刷日志。
        error.HttpConnectionClosing, error.HttpRequestTruncated, error.ReadFailed => .connection_closed,
        // head 超出 Reader.max_head_len。
        error.HttpHeadersOversize => .head_too_large,
        // 一切坏头（std 已把细节错误折叠到此）。
        error.HttpHeadersInvalid => .protocol_error,
    };
}

/// 在逗号分隔的 header 值（如 Connection）里查找某个 token（大小写不敏感）。
fn hasToken(header_value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

fn reqWithHead(version: http.Version, head: []const u8) protocol.Request {
    return .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = version,
        .head_bytes = head,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
}

test "shouldKeepAlive: HTTP/1.1 默认可复用，HTTP/1.0 默认关" {
    var r11 = reqWithHead(.@"HTTP/1.1", "GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(ConnectionLoop.shouldKeepAlive(undefined, &r11));

    var r10 = reqWithHead(.@"HTTP/1.0", "GET / HTTP/1.0\r\n\r\n");
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &r10));

    var r10k = reqWithHead(.@"HTTP/1.0", "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    try std.testing.expect(ConnectionLoop.shouldKeepAlive(undefined, &r10k));
}

test "shouldKeepAlive: token 匹配，close 优先" {
    var a = reqWithHead(.@"HTTP/1.1", "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &a));

    // 逗号分隔多 token：close 仍胜出（std 的整值比较会在这里判错）
    var b = reqWithHead(.@"HTTP/1.1", "GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n");
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &b));

    // 大小写不敏感 + 多余空白
    var c = reqWithHead(.@"HTTP/1.1", "GET / HTTP/1.1\r\nCONNECTION: \tCLOSE \r\n\r\n");
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &c));

    // 子串不算 token 命中
    var d = reqWithHead(.@"HTTP/1.1", "GET / HTTP/1.1\r\nConnection: xclosey\r\n\r\n");
    try std.testing.expect(ConnectionLoop.shouldKeepAlive(undefined, &d));

    var e = reqWithHead(.@"HTTP/1.0", "GET / HTTP/1.0\r\nConnection: xkeep-alivey\r\n\r\n");
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &e));
}

test "shouldKeepAlive: 扫全部 Connection 头（RFC 9110 §7.6.1）" {
    // keep-alive 在前、close 在后：只看第一个头的旧实现会漏掉 close。
    var multi = reqWithHead(
        .@"HTTP/1.1",
        "GET / HTTP/1.1\r\nConnection: keep-alive\r\nConnection: close\r\n\r\n",
    );
    try std.testing.expect(!ConnectionLoop.shouldKeepAlive(undefined, &multi));
}

test "classifyHeadError: 覆盖 std receiveHead 的全部错误成员" {
    try std.testing.expectEqual(HeadAction.connection_closed, classifyHeadError(error.HttpConnectionClosing));
    try std.testing.expectEqual(HeadAction.connection_closed, classifyHeadError(error.HttpRequestTruncated));
    try std.testing.expectEqual(HeadAction.connection_closed, classifyHeadError(error.ReadFailed));
    try std.testing.expectEqual(HeadAction.head_too_large, classifyHeadError(error.HttpHeadersOversize));
    try std.testing.expectEqual(HeadAction.protocol_error, classifyHeadError(error.HttpHeadersInvalid));
}

test "hasToken matches whole comma-separated tokens only" {
    try std.testing.expect(hasToken("keep-alive, close", "close"));
    try std.testing.expect(hasToken("  Close\t", "close"));
    try std.testing.expect(hasToken("KEEP-ALIVE", "keep-alive"));
    try std.testing.expect(!hasToken("xclosey", "close"));
    try std.testing.expect(!hasToken("close", "keep-alive"));
}

test {
    std.testing.refAllDecls(@This());
}
