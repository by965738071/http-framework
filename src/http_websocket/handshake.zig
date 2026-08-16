//! WebSocket 握手升级 — RFC 6455 §4
//!
//! 握手流程（HTTP/1.1 Upgrade）：
//! ```text
//! Client →  GET /ws HTTP/1.1
//!           Upgrade: websocket
//!           Connection: Upgrade
//!           Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
//!           Sec-WebSocket-Version: 13
//!
//! Server →  HTTP/1.1 101 Switching Protocols
//!           Upgrade: websocket
//!           Connection: Upgrade
//!           Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
//! ```
//!
//! # Sec-WebSocket-Accept 计算
//!
//! RFC 6455 §4.2.2 规定：
//! 1. 取 `Sec-WebSocket-Key` 的值
//! 2. 拼接固定 GUID `"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`
//! 3. SHA-1 摘要（20 字节）
//! 4. Base64 编码（带填充）
//!
//! # 为什么 `handshake` 只设响应头而不发送响应
//!
//! 框架的 `Response` 在 buffered/非 buffered 模式下都通过 Sink 发送，
//! 但握手成功后需要"劫持" TCP 连接做裸 WebSocket 帧读写——这超出了
//! `Response`/`Sink` 的抽象边界（Sink 假设是 HTTP 响应生命周期）。
//!
//! 因此本模块的分工：
//! - `handshake` 只校验请求头并设置 101 + 握手响应头，返回 true/false
//! - 实际响应发送 + 连接劫持由 ConnectionRunner 在外层完成
//! - 帧读写由 `connection.zig` 的 `WebSocket` 包装 reader/writer 实现
//!
//! 这样帧编解码和握手计算都可独立单元测试，不依赖 socket。

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Context = http_app.Context;
pub const Response = http_protocol.Response;
pub const Sink = http_protocol.Sink;

/// RFC 6455 §1.3 规定的固定 GUID。
/// 拼到 client 提供的 key 后做 SHA-1——这是协议约定的"无认证"握手机制，
/// 用来防止 cross-protocol 攻击（让误以为在讲 HTTP 的服务器不轻易升级）。
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Accept-Key 输出长度：20 字节 SHA-1 → base64 编码 = 28 字符（含 1 个 '=' 填充）。
pub const ACCEPT_KEY_LEN = 28;

/// 校验 WebSocket 握手请求并设置 101 响应头。
///
/// 成功时：
/// - 设置 `res.status = .switching_protocols`
/// - 添加 `Upgrade: websocket` / `Connection: Upgrade` / `Sec-WebSocket-Accept` 头
/// - 返回 true
///
/// 失败时（缺头或非升级请求）返回 false，不修改响应——调用方应自行发送错误。
///
/// 注意：响应并未发送，只设置了状态和头。调用方负责发送响应（通常通过
/// `res.flush()` 或直接走框架的发送路径）并在发送后"劫持"底层 stream。
pub fn handshake(ctx: *Context, res: *Response) !bool {
    // 校验 Upgrade 头（大小写不敏感）。RFC §4.2.1: 值必须是 "websocket"。
    const upgrade = ctx.header("upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return false;

    // 校验 Connection 头包含 "upgrade" token。
    // Connection 头可能是 "keep-alive, Upgrade" 形式，所以用 contains 而非 eql。
    const connection = ctx.header("connection") orelse return false;
    if (!containsTokenIgnoreCase(connection, "upgrade")) return false;

    // 必须有 Sec-WebSocket-Key（16 字节 base64 编码 = 24 字符）。这里只校验存在。
    const key = ctx.header("sec-websocket-key") orelse return false;

    // 计算 Accept-Key 并设置响应
    var accept_buf: [ACCEPT_KEY_LEN]u8 = undefined;
    const accept_value = try computeAcceptKey(key, &accept_buf);

    _ = res.statusCode(.switching_protocols);
    _ = try res.header("Upgrade", "websocket");
    _ = try res.header("Connection", "Upgrade");
    _ = try res.header("Sec-WebSocket-Accept", accept_value);

    return true;
}

/// 计算 `Sec-WebSocket-Accept` = base64(SHA1(key + GUID))。
///
/// 输出写入 `out`（必须至少 28 字节），返回的切片指向 `out`。
/// 使用栈缓冲避免堆分配——握手在请求生命周期里只算一次。
pub fn computeAcceptKey(client_key: []const u8, out: *[@This().ACCEPT_KEY_LEN]u8) ![]const u8 {
    // SHA-1 摘要：key + GUID
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key);
    sha.update(WS_GUID);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha.final(&digest);

    // base64 标准编码（带 '=' 填充）。20 字节 → 28 字符。
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// 在逗号分隔的 header 值里查找某个 token（大小写不敏感）。
/// 用于 "Connection: keep-alive, Upgrade" 这种多值场景。
/// 简单实现：split by ',' 并 trim 空白后比对。
fn containsTokenIgnoreCase(header_value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "computeAcceptKey matches RFC 6455 §4.2.2 example" {
    // RFC 给出的示例：key "dGhlIHNhbXBsZSBub25jZQ==" → accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    var buf: [ACCEPT_KEY_LEN]u8 = undefined;
    const got = try computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "computeAcceptKey is deterministic" {
    var buf1: [ACCEPT_KEY_LEN]u8 = undefined;
    var buf2: [ACCEPT_KEY_LEN]u8 = undefined;
    const a = try computeAcceptKey("some-key", &buf1);
    const b = try computeAcceptKey("some-key", &buf2);
    try testing.expectEqualStrings(a, b);
}

test "computeAcceptKey differs for different keys" {
    var buf1: [ACCEPT_KEY_LEN]u8 = undefined;
    var buf2: [ACCEPT_KEY_LEN]u8 = undefined;
    const a = try computeAcceptKey("key-one", &buf1);
    const b = try computeAcceptKey("key-two", &buf2);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "containsTokenIgnoreCase handles comma-separated values" {
    try testing.expect(containsTokenIgnoreCase("keep-alive, Upgrade", "upgrade"));
    try testing.expect(containsTokenIgnoreCase("Upgrade", "upgrade"));
    try testing.expect(containsTokenIgnoreCase("keep-alive, upgrade", "UPGRADE"));
    try testing.expect(!containsTokenIgnoreCase("keep-alive", "upgrade"));
    try testing.expect(!containsTokenIgnoreCase("", "upgrade"));
}

test "handshake rejects non-upgrade requests" {
    // 用最小化的 Context 直接测——不依赖完整 HTTP server
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(arena.allocator());

    var req = http_app.Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        // 不带 Upgrade 头
        .head_bytes = "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = http_app.RequestConfig{};
    var ctx = http_app.Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    // 用 testSink——handshake 不实际发送响应，只设置状态/头
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    var res = Response.init(arena.allocator(), Sink.testSink(&w));
    defer res.deinit();

    try testing.expectEqual(false, try handshake(&ctx, &res));
}

test "handshake accepts valid upgrade request" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(arena.allocator());

    // 构造带完整握手头的请求 head
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    var req = http_app.Request{
        .method = .GET,
        .target = "/ws",
        .path = "/ws",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const cfg = http_app.RequestConfig{};
    var ctx = http_app.Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var out_buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    var res = Response.init(arena.allocator(), Sink.testSink(&w));
    defer res.deinit();

    try testing.expectEqual(true, try handshake(&ctx, &res));

    // 验证状态码和 Accept 头
    try testing.expectEqual(std.http.Status.switching_protocols, res.status);

    // 在 res.headers 里找 Sec-WebSocket-Accept
    var found_accept = false;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Sec-WebSocket-Accept")) {
            try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", h.value);
            found_accept = true;
        }
    }
    try testing.expect(found_accept);
}

test {
    std.testing.refAllDecls(@This());
}
