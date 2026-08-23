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
const connection = @import("connection.zig");

pub const Context = http_app.Context;
pub const Response = http_protocol.Response;
pub const Sink = http_protocol.Sink;

/// RFC 6455 §1.3 规定的固定 GUID。
/// 拼到 client 提供的 key 后做 SHA-1——这是协议约定的"无认证"握手机制，
/// 用来防止 cross-protocol 攻击（让误以为在讲 HTTP 的服务器不轻易升级）。
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Accept-Key 输出长度：20 字节 SHA-1 → base64 编码 = 28 字符（含 1 个 '=' 填充）。
pub const ACCEPT_KEY_LEN = 28;

/// 获取进程级 Origin 白名单（由 setAllowedOrigins 设置）。null = 不校验（向后兼容）。
/// 浏览器发起的跨源 WebSocket 不受同源策略/CORS 约束，不校验 Origin 会造成
/// CSWSH（跨站 WebSocket 劫持）。生产中应显式设置白名单。
var allowed_origins: ?[]const []const u8 = null;

/// 设置 WebSocket 握手的 Origin 白名单（全局，启动期调用一次）。
/// 传入的切片必须在进程存活期内有效（通常是编译期常量）。
/// 传 null / 不调用 = 不校验（适用于非浏览器客户端 / 内网）。
pub fn setAllowedOrigins(origins: ?[]const []const u8) void {
    allowed_origins = origins;
}

/// 校验请求 Origin 是否在白名单内。未配白名单时总是通过（向后兼容）。
/// 配了白名单但请求无 Origin 头（非浏览器客户端）也通过。
fn isOriginAllowed(ctx: *Context) bool {
    const allowed = allowed_origins orelse return true;
    const origin = ctx.header("origin") orelse return true; // 非浏览器客户端无 Origin
    for (allowed) |o| {
        if (std.mem.eql(u8, o, origin)) return true;
    }
    return false;
}

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
    const upgrade_hdr = ctx.header("upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) return false;

    // 校验 Connection 头包含 "upgrade" token。
    // Connection 头可能是 "keep-alive, Upgrade" 形式，所以用 contains 而非 eql。
    const connection_hdr = ctx.header("connection") orelse return false;
    if (!containsTokenIgnoreCase(connection_hdr, "upgrade")) return false;

    // 必须有 Sec-WebSocket-Key（16 字节 base64 编码 = 24 字符）。这里只校验存在。
    const key = ctx.header("sec-websocket-key") orelse return false;

    // 校验 Origin（防 CSWSH）。未配白名单时不校验（向后兼容）。
    if (!isOriginAllowed(ctx)) {
        _ = res.statusCode(.forbidden);
        return false;
    }

    // 校验 Sec-WebSocket-Version（RFC 6455 §4.2.1）：本实现仅支持版本 13。
    // 缺失或不支持时按 RFC 回 426 Upgrade Required + Sec-WebSocket-Version: 13，
    // 让客户端知道服务端期望的版本。
    const version = ctx.header("sec-websocket-version") orelse {
        setUnsupportedVersion(res) catch {};
        return false;
    };
    if (!containsTokenIgnoreCase(version, "13")) {
        try setUnsupportedVersion(res);
        return false;
    }

    // 计算 Accept-Key 并设置响应
    var accept_buf: [ACCEPT_KEY_LEN]u8 = undefined;
    const accept_value = try computeAcceptKey(key, &accept_buf);

    _ = res.statusCode(.switching_protocols);
    _ = try res.header("Upgrade", "websocket");
    _ = try res.header("Connection", "Upgrade");
    _ = try res.header("Sec-WebSocket-Accept", accept_value);

    return true;
}

/// 设置 426 Upgrade Required 响应，并带上服务端支持的版本号（RFC 6455 §4.4）。
fn setUnsupportedVersion(res: *Response) !void {
    _ = res.statusCode(.upgrade_required);
    _ = try res.header("Sec-WebSocket-Version", "13");
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

/// 在逐字分隔的 header 值里查找某个 token（大小写不敏感）。
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

/// WebSocket 升级（高级 API）——把“校验握手 + 注册连接劫持回调”一步完成。
///
/// 返回 `true`：握手合法，已通过 `ctx.hijack` 注册回调。handler 应**直接 return**，
/// 不要再写任何响应。ConnectionRunner 在 dispatch 结束后会：
///   1. 向裸 writer 写 101 Switching Protocols + Sec-WebSocket-Accept；
///   2. 构造 `WebSocket.initServer` 并调用你的 `handlerFn(ws, hijack_ctx)`。
///
/// 返回 `false`：非合法升级请求（缺头/版本不支持），已写好错误响应（426 等），
/// handler 直接 return 即可。
///
/// `hijack_ctx` 是用户上下文指针（必须在连接存活期内有效，如 singleton handler
/// 实例）；`handlerFn` 拿到已建好的 `*WebSocket` 和该上下文。
pub fn upgrade(
    ctx: *Context,
    res: *Response,
    hijack_ctx: *anyopaque,
    comptime handlerFn: fn (ws: *connection.WebSocket, hijack_ctx: *anyopaque) anyerror!void,
) !bool {
    // 校验 Upgrade 头（大小写不敏感）。RFC §4.2.1: 值必须是 "websocket"。
    const upgrade_hdr = ctx.header("upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) return false;

    const connection_hdr = ctx.header("connection") orelse return false;
    if (!containsTokenIgnoreCase(connection_hdr, "upgrade")) return false;

    const key = ctx.header("sec-websocket-key") orelse return false;

    // 校验 Origin（防 CSWSH）。未配白名单时不校验（向后兼容）。
    if (!isOriginAllowed(ctx)) {
        _ = res.statusCode(.forbidden);
        return false;
    }

    const version = ctx.header("sec-websocket-version") orelse {
        setUnsupportedVersion(res) catch {};
        return false;
    };
    if (!containsTokenIgnoreCase(version, "13")) {
        try setUnsupportedVersion(res);
        return false;
    }

    // 把 client key 拷到请求 arena（handshake 响应写阶段在 dispatch 后，target/head 可能失效）。
    const key_owned = try ctx.arena.dupe(u8, key);

    // 封装“写 101 + 跑帧循环”的劫持回调。因为 Hijack.run 签名固定，
    // 需要把 client key 和用户回调 handlerFn 一起带到回调里——用一个请求 arena
    // 上的 UpgradeCtx 打包（arena 在 hijack.run 执行前不会被 reset，因为 run 在
    // 本请求的 keep-alive 循环迭代内、endRequest 之前就被调用）。
    const UpgradeCtx = struct { key: []const u8, user_ctx: *anyopaque };
    const uc = try ctx.arena.create(UpgradeCtx);
    uc.* = .{ .key = key_owned, .user_ctx = hijack_ctx };

    const runFn = struct {
        fn run(
            hctx: *anyopaque,
            io: std.Io,
            reader: *std.Io.Reader,
            writer: *std.Io.Writer,
            allocator: std.mem.Allocator,
        ) anyerror!void {
            _ = io;
            const u: *UpgradeCtx = @ptrCast(@alignCast(hctx));

            // 1. 写 101 Switching Protocols 握手响应（直写裸 writer，不经 Sink）。
            var accept_buf: [ACCEPT_KEY_LEN]u8 = undefined;
            const accept_value = try computeAcceptKey(u.key, &accept_buf);
            try writer.print(
                "HTTP/1.1 101 Switching Protocols\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Accept: {s}\r\n\r\n",
                .{accept_value},
            );
            try writer.flush();

            // 2. 构造 WebSocket 连接对象，交给用户回调。
            var ws = connection.WebSocket.initServer(reader, writer, allocator);
            try handlerFn(&ws, u.user_ctx);
        }
    }.run;

    ctx.hijack(@ptrCast(uc), runFn);
    return true;
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

test "handshake rejects unsupported Sec-WebSocket-Version with 426" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(arena.allocator());

    // Sec-WebSocket-Version: 8（不支持）
    const head =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 8\r\n" ++
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

    try testing.expectEqual(false, try handshake(&ctx, &res));
    try testing.expectEqual(std.http.Status.upgrade_required, res.status);

    var found_version = false;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Sec-WebSocket-Version")) {
            try testing.expectEqualStrings("13", h.value);
            found_version = true;
        }
    }
    try testing.expect(found_version);
}

test "upgrade registers hijack and writes 101 + runs handler" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = http_app.RequestState{};
    defer state.deinit(arena.allocator());

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

    // 用户上下文：记录回调是否被调用 + 收到的消息。
    const H = struct {
        var called: bool = false;
        var got: [64]u8 = undefined;
        var got_len: usize = 0;
        fn onWs(ws: *connection.WebSocket, hijack_ctx: *anyopaque) anyerror!void {
            _ = hijack_ctx;
            called = true;
            var msg = try ws.receive();
            defer msg.deinit();
            @memcpy(got[0..msg.payload.len], msg.payload);
            got_len = msg.payload.len;
            try ws.sendText("pong");
        }
    };
    H.called = false;

    var dummy: u8 = 0;
    const ok = try upgrade(&ctx, &res, @ptrCast(&dummy), H.onWs);
    try testing.expect(ok);
    // upgrade 不直接写响应，而是注册 hijack。
    try testing.expect(state.hijack != null);
    try testing.expect(!res.sent);

    // 模拟 ConnectionRunner 执行 hijack：客户端先发一个 masked text 帧。
    var client_send: std.Io.Writer.Allocating = .init(allocator);
    defer client_send.deinit();
    {
        var cw: std.Io.Reader = .fixed("");
        var cli = connection.WebSocket.initClient(&cw, &client_send.writer, allocator);
        try cli.sendText("hi-server");
    }

    var server_in: std.Io.Reader = .fixed(client_send.written());
    var server_out: std.Io.Writer.Allocating = .init(allocator);
    defer server_out.deinit();

    const h = state.hijack.?;
    try h.run(h.ctx, undefined, &server_in, &server_out.writer, allocator);

    // 回调被调用、收到客户端消息。
    try testing.expect(H.called);
    try testing.expectEqualStrings("hi-server", H.got[0..H.got_len]);
    // server_out 应包含 101 握手行 + Sec-WebSocket-Accept。
    const server_written = server_out.written();
    try testing.expect(std.mem.indexOf(u8, server_written, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, server_written, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test {
    std.testing.refAllDecls(@This());
}
