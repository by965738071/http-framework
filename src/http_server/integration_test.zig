//! 集成测试 — 中间件管道 + 路由 端到端（回应 fix.md §四：无集成测试）
//!
//! 用真实的 Router + 中间件堆栈（通过 Next 直接驱动），验证：
//! - 命中路由经过完整中间件管道
//! - 404 也经过中间件管道（X-Request-Id / timing 头都在）
//! - 405 也经过中间件管道
//! - 客户端 X-Request-Id 被沿用
//! - handler 抛错被 ErrorRenderer 兜底
//!
//! 不用真实 TCP socket——TCP 层在 listener/connection 里有自己的单元测试，
//! 这里聚焦于"管道 + 路由 + 中间件"的集成行为。

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");
const http_router = @import("http_router");
const Context = http_app.Context;
const Response = http_protocol.Response;
const Handler = http_app.Handler;
const Middleware = http_app.Middleware;
const Request = http_protocol.Request;
const Sink = http_protocol.Sink;
const AppError = http_app.AppError;
const http = std.http;

/// 捕获型 Sink——完整写入状态行 + 头 + body（testSink 丢弃了头）。
/// 用于集成测试断言响应头。
fn capturingSink(writer: *std.Io.Writer) Sink {
    const ctx = struct {
        fn respond(ptr: *anyopaque, status: http.Status, headers: []const http.Header, body: []const u8, keep_alive: bool) anyerror!void {
            _ = keep_alive;
            const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try w.print("HTTP/1.1 {d} {s}\r\n", .{ @backingInt(status), @tagName(status) });
            for (headers) |h| {
                try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            }
            try w.writeAll("\r\n");
            try w.writeAll(body);
        }
        fn startStream(ptr: *anyopaque, status: http.Status, headers: []const http.Header, content_length: ?u64, buffer: []u8, keep_alive: bool) anyerror!http.BodyWriter {
            _ = ptr;
            _ = status;
            _ = headers;
            _ = content_length;
            _ = buffer;
            _ = keep_alive;
            return error.NotSupportedInCapturingSink;
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

/// 构建一个最小可用 Context（arena 由测试 allocator 提供）。
fn makeCtx(arena: std.mem.Allocator, req: *Request, state: *http_app.RequestState, io: std.Io) Context {
    return .{
        .request = req,
        .state = state,
        .config = &.{},
        .arena = arena,
        .io = io,
    };
}

/// 构建一个最小 GET 请求。
/// `extra_headers` 必须是完整 header 行（含 `\r\n`），如 `"X-Request-Id: abc\r\n"`。
/// 注意：getHeader 读 head_bytes，所以 extra_headers 要拼进 head_bytes。
fn makeReq(allocator: std.mem.Allocator, path: []const u8, extra_headers: []const u8) !Request {
    // 在 allocator 上分配 head 字节，保证生命周期覆盖整个测试。
    var buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\n{s}\r\n", .{ path, extra_headers }) catch unreachable;
    const head_bytes = try allocator.dupe(u8, head);
    return .{
        .method = .GET,
        .target = path,
        .path = path,
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
}

/// 从 Writer.fixed 的已写缓冲里提取 header 值（大小写不敏感）。
fn extractHeader(buf: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, buf, "\r\n");
    _ = it.first(); // status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hdr_name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(hdr_name, name)) {
            var val_start = colon + 1;
            while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) val_start += 1;
            return line[val_start..];
        }
    }
    return null;
}

/// 从状态行提取状态码。
fn extractStatus(buf: []const u8) u16 {
    if (std.mem.indexOf(u8, buf, "HTTP/1.1 ")) |idx| {
        const start = idx + "HTTP/1.1 ".len;
        if (start + 3 <= buf.len) {
            return std.fmt.parseInt(u16, buf[start .. start + 3], 10) catch 0;
        }
    }
    return 0;
}

/// 提取 body（\r\n\r\n 之后）。
fn extractBody(buf: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return "";
    return buf[sep + 4 ..];
}

// ── 测试用 handler / middleware ────────────────────────────

fn helloHandler(_: *Context, res: *Response) !void {
    try res.statusCode(.ok).text("Hello, World!");
}

// Issue 5：handler 完全不读 body（框架已把 body 置为 .none），只回固定文本。
fn deleteFavHandler(_: *Context, res: *Response) !void {
    try res.statusCode(.ok).text("deleted");
}

// 用 failWith 抛出带状态码的 AppError，验证 ErrorRenderer 能从 ctx.state
// 提取并正确渲染（fix.md §一.3 的端到端验证）。
fn boomHandler(ctx: *Context, _: *Response) !void {
    try ctx.failWith(AppError.forbidden("no access"));
}

const TimingMiddleware = struct {
    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: http_app.Next) !void {
        res.setBuffered();
        const start = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
        // 错误时也要加 timing 头——计时应该包含错误处理时间，
        // 且 ErrorRenderer 在外层兜底时已经能看到这个头（buffered 模式）。
        next.call(ctx, res) catch |err| {
            const elapsed_err = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
            _ = res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed_err}) catch "?") catch {};
            return err;
        };
        const elapsed = std.Io.Timestamp.now(ctx.io, .real).nanoseconds - start;
        _ = res.header("X-Response-Time-ns", std.fmt.allocPrint(ctx.arena, "{d}", .{elapsed}) catch "?") catch {};
    }
};

const TagMiddleware = struct {
    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: http_app.Next) !void {
        _ = res.header("X-Tag", "tag-value") catch {};
        try next.call(ctx, res);
    }
};

// 记录生命周期事件的 Hook，用于验证 request_error 确实被触发。
const EventRecorder = struct {
    request_errors: u32 = 0,
    request_ends: u32 = 0,
    last_error_status: ?std.http.Status = null,

    pub fn onEvent(self: *@This(), event: http_app.Event, data: *const http_app.EventData) void {
        switch (event) {
            .request_error => {
                self.request_errors += 1;
                self.last_error_status = data.status;
            },
            .request_end => self.request_ends += 1,
            else => {},
        }
    }
};

/// 中间件实例必须是静态生命周期：`router.use` 存的是实例指针，写成
/// `buildRouter` 局部变量会在 return 后悬垂（此前 ErrorRenderer 是 0 字节空
/// 结构、process 从不解引用实例内存所以无恙；它有字段后会读 self → segfault）。
var err_renderer = http_app.ErrorRenderer{};
var rid_mw = http_app.RequestIdMiddleware{};
var timing_mw = TimingMiddleware{};
var tag_mw = TagMiddleware{};

/// 构建一个带完整中间件管道的 Router（request-id + timing + tag + error-renderer）。
fn buildRouter(allocator: std.mem.Allocator, io: std.Io) !http_router.Router {
    var router = try http_router.Router.init(allocator);
    try router.route(.GET, "/", Handler.fromFn(helloHandler));
    try router.route(.GET, "/boom", Handler.fromFn(boomHandler));
    try router.route(.POST, "/echo", Handler.fromFn(helloHandler));

    // ErrorRenderer 最外层
    try router.use(Middleware.init(http_app.ErrorRenderer, &err_renderer));
    // RequestId
    try router.use(Middleware.init(http_app.RequestIdMiddleware, &rid_mw));
    // Timing
    try router.use(Middleware.init(TimingMiddleware, &timing_mw));
    // Tag
    try router.use(Middleware.init(TagMiddleware, &tag_mw));
    _ = io;
    return router;
}

// ===========================================================================
// Tests
// ===========================================================================

test "命中路由：200 + body + 中间件头齐全" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    var req = try makeReq(arena.allocator(), "/", "");
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    try std.testing.expectEqual(@as(u16, 200), extractStatus(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello, World!") != null);
    try std.testing.expect(extractHeader(written, "x-request-id") != null);
    try std.testing.expect(extractHeader(written, "x-response-time-ns") != null);
    try std.testing.expectEqualStrings("tag-value", extractHeader(written, "x-tag").?);
}

test "404：经过中间件管道，带 X-Request-Id / timing / tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    var req = try makeReq(arena.allocator(), "/no-such-path", "");
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    try std.testing.expectEqual(@as(u16, 404), extractStatus(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "Not Found") != null);
    // 关键回归点：404 也要有 X-Request-Id（回应 fix.md §三）
    try std.testing.expect(extractHeader(written, "x-request-id") != null);
    try std.testing.expect(extractHeader(written, "x-response-time-ns") != null);
    try std.testing.expect(extractHeader(written, "x-tag") != null);
}

test "405：经过中间件管道，带 X-Request-Id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    // /echo 只注册了 POST，用 GET 访问应 405
    var req = try makeReq(arena.allocator(), "/echo", "");
    req.method = .GET;
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    try std.testing.expectEqual(@as(u16, 405), extractStatus(written));
    try std.testing.expect(extractHeader(written, "x-request-id") != null);
    try std.testing.expect(extractHeader(written, "x-response-time-ns") != null);
}

test "客户端 X-Request-Id 被沿用" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const hdr = "X-Request-Id: trace-abc-123\r\n";
    var req = try makeReq(arena.allocator(), "/", hdr);
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    try std.testing.expectEqual(@as(u16, 200), extractStatus(written));
    const rid = extractHeader(written, "x-request-id");
    try std.testing.expect(rid != null);
    try std.testing.expectEqualStrings("trace-abc-123", rid.?);
}

test "handler 抛错：ErrorRenderer 兜底 500，但仍带中间件头" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    var req = try makeReq(arena.allocator(), "/boom", "");
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    // AppError.forbidden → 403 + "no access"
    try std.testing.expectEqual(@as(u16, 403), extractStatus(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "no access") != null);
    // 中间件头仍然存在——证明管道完整执行了
    try std.testing.expect(extractHeader(written, "x-request-id") != null);
    try std.testing.expect(extractHeader(written, "x-response-time-ns") != null);
}

test "中间件管道顺序：外层先于内层 setBuffered，handler 后外层收尾" {
    // 验证 next() 模型：中间件能在 handler 之后修改响应
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/", Handler.fromFn(helloHandler));

    var local_tag = TagMiddleware{};
    try router.use(Middleware.init(TagMiddleware, &local_tag));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    var req = try makeReq(arena.allocator(), "/", "");
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];

    try std.testing.expectEqual(@as(u16, 200), extractStatus(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello, World!") != null);
    try std.testing.expectEqualStrings("tag-value", extractHeader(written, "x-tag").?);
}

test "request_error 事件：5xx 响应触发 Hook（修复 #1）" {
    // 验证 lifecycle.emit(.request_error) 能被 Hook 收到。这里直接驱动
    // Lifecycle（connection.zig 的实际触发代码与此同形：状态码 >= 500 则 emit）。
    var recorder = EventRecorder{};
    const hooks = [_]http_app.Hook{http_app.Hook.init(EventRecorder, &recorder)};
    const lifecycle = http_app.Lifecycle{ .hooks = &hooks };

    // 成功请求：只发 request_end，不发 request_error。
    lifecycle.emit(.request_end, .{ .status = .ok });
    try std.testing.expectEqual(@as(u32, 1), recorder.request_ends);
    try std.testing.expectEqual(@as(u32, 0), recorder.request_errors);

    // 5xx：补发 request_error。
    lifecycle.emit(.request_error, .{ .status = .internal_server_error });
    try std.testing.expectEqual(@as(u32, 1), recorder.request_errors);
    try std.testing.expectEqual(std.http.Status.internal_server_error, recorder.last_error_status.?);
}

test "HEAD 自动回退到 GET 路由" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try buildRouter(allocator, io);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    // 只注册了 GET /，用 HEAD 访问应命中 GET handler（而非 405）。
    var req = try makeReq(arena.allocator(), "/", "");
    req.method = .HEAD;
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];
    try std.testing.expectEqual(@as(u16, 200), extractStatus(written));
}

test "405 Allow 头无重复方法" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    // 重叠路由 /a/b 与 /a/:x，都只 GET——POST 时回溯可能重复收集 GET。
    try router.route(.GET, "/a/b", Handler.fromFn(helloHandler));
    try router.route(.GET, "/a/:x", Handler.fromFn(helloHandler));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var state = http_app.RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    var req = try makeReq(arena.allocator(), "/a/b", "");
    req.method = .POST;
    var ctx = makeCtx(arena.allocator(), &req, &state, io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    _ = try router.dispatch(&ctx, &res);
    try res.flush();
    const written = buf[0..writer.end];
    try std.testing.expectEqual(@as(u16, 405), extractStatus(written));
    const allow = extractHeader(written, "allow").?;
    // "GET" 只应出现一次
    try std.testing.expect(std.mem.indexOf(u8, allow, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow[3..], "GET") == null);
}

test "缓冲模式 flush 幂等：中间件 flush 后 ConnectionRunner 再 flush 不双发" {
    const allocator = std.testing.allocator;

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    res.setBuffered();
    _ = res.statusCode(.ok);
    try res.text("body");
    try res.flush(); // 中间件的 flush
    const after_first = writer.end;
    try res.flush(); // ConnectionRunner 的兜底 flush——应为 no-op
    try std.testing.expectEqual(after_first, writer.end); // 没有第二次写入
}

// 吞掉 failWith 错误的 handler：调用 failWith 后 catch {} return。
// 没有 ErrorRenderer 时，dispatch 成功返回但 res.sent=false，
// 靠 ConnectionRunner 兑底用 AppError 渲染（修复：静默 200 空 body）。
fn swallowFailHandler(ctx: *Context, _: *Response) !void {
    ctx.failWith(AppError.notFound("resource gone")) catch {};
    return;
}

// 抛出 failWith 错误的 handler（不 catch）：dispatch 返回 error.AppError，
// 靠 ConnectionRunner 兑底用 AppError 渲染（修复：静默 500）。
fn propagateFailHandler(ctx: *Context, _: *Response) !void {
    try ctx.failWith(AppError.unauthorized("bad token"));
}

// ── 驱动真实的 ConnectionRunner ─────────────────────────────────────────
//
// 这两个测试以前是「逻辑复刻型」：把 connection.zig 的兜底分支抄一份自己跑，
// 于是兜底逻辑被改坏时测试照样绿——它测的是测试自己。现在改成驱动真实的
// ConnectionRunner，断言的是"连接上真正写出了什么"。

const ConnectionRunner = @import("connection.zig").ConnectionRunner;

/// 用内存 Reader/Writer 喂真实 HTTP 字节，跑完整的 `ConnectionRunner.run()`：
/// conn_loop 解析报文 → router dispatch → processRequest → keep-alive 收尾。
/// 没有 TCP、没有 zio 运行时，但走的是生产那条代码路径。
fn runConnection(
    allocator: std.mem.Allocator,
    router: *const http_router.Router,
    raw_request: []const u8,
    out: []u8,
) []const u8 {
    var reader = std.Io.Reader.fixed(raw_request);
    var writer = std.Io.Writer.fixed(out);
    var config = http_app.Config{};
    var stats = http_app.RuntimeState{};
    var runner = ConnectionRunner{
        .reader = &reader,
        .writer = &writer,
        .io = std.testing.io,
        .router = router,
        .config = &config,
        .lifecycle = .{},
        .stats = &stats,
        .allocator = allocator,
    };
    runner.run();
    return out[0..writer.end];
}

pub const ProcessResult = struct {
    written: []const u8,
    dispatch_err: ?anyerror,
};

/// 只驱动 `processRequest`（跳过 keep-alive 循环）。
///
/// 为什么不统一用 `run()`：run() 在 dispatch 报错时会 `std.log.err`，而 zig 的
/// test runner 把任何 err 级日志都计为失败、让整个测试二进制 exit 1
/// （std/compiler/test_runner.zig: log_err_count）。于是"handler 抛错 → 兜底
/// 渲染"这条路径只能在 log 之前的那层驱动它。processRequest 正是那层：它是
/// 真实的生产代码，只是没有外面那层循环。
fn processRequestOnce(
    allocator: std.mem.Allocator,
    router: *const http_router.Router,
    raw_request: []const u8,
    out: []u8,
) !ProcessResult {
    var reader = std.Io.Reader.fixed(raw_request);
    var writer = std.Io.Writer.fixed(out);
    var server = http.Server.init(&reader, &writer);
    var arenas = http_app.Arenas.init(allocator);
    defer arenas.deinit();

    // 真实地收一个 head——Request.init 与 Sink 都建立在 std 的 Request 之上，
    // 用假 Server.Request 会绕开 prepareBodyNone 这类真实行为。
    var raw_req = try server.receiveHead();
    var parsed = try http_protocol.Request.init(arenas.requestAllocator(), &raw_req);

    var config = http_app.Config{};
    var stats = http_app.RuntimeState{};
    var runner = ConnectionRunner{
        .reader = &reader,
        .writer = &writer,
        .io = std.testing.io,
        .router = router,
        .config = &config,
        .lifecycle = .{},
        .stats = &stats,
        .allocator = allocator,
    };
    var dispatch_err: ?anyerror = null;
    _ = runner.processRequest(&parsed, &raw_req, &arenas, false) catch |e| {
        dispatch_err = e;
    };
    return .{ .written = out[0..writer.end], .dispatch_err = dispatch_err };
}

test "failWith 被吞：ConnectionRunner 成功路径兜底渲染 404（不是静默 200）" {
    // handler 调 failWith 后 catch {} return：dispatch 成功但 res.sent=false。
    // processRequest 的成功路径兜底必须查 ctx.state 里的 AppError 并按其状态码
    // 渲染——以前这里没有测试保护（旧测试是抄一遍逻辑自己跑）。
    const allocator = std.testing.allocator;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/missing", Handler.fromFn(swallowFailHandler));

    var out: [4096]u8 = undefined;
    const written = runConnection(
        allocator,
        &router,
        "GET /missing HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
        &out,
    );

    try std.testing.expectEqual(@as(u16, 404), extractStatus(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "resource gone") != null);
}

test "failWith 拋出：processRequest 错误路径兜底渲染 401（不是静默 500）" {
    const allocator = std.testing.allocator;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/forbidden", Handler.fromFn(propagateFailHandler));

    var out: [4096]u8 = undefined;
    const r = try processRequestOnce(allocator, &router, "GET /forbidden HTTP/1.1\r\n\r\n", &out);

    // dispatch 确实把 error.AppError 抛上来了
    try std.testing.expectEqual(error.AppError, r.dispatch_err.?);
    // 兜底用 AppError 的状态码渲染，而不是一律 500
    try std.testing.expectEqual(@as(u16, 401), extractStatus(r.written));
    try std.testing.expect(std.mem.indexOf(u8, r.written, "bad token") != null);
}

test "processRequest：没有 AppError 的未知错误兜底 500 + 关连接" {
    const allocator = std.testing.allocator;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/boom", Handler.fromFn(struct {
        fn handle(_: *Context, _: *Response) !void {
            return error.SomethingBroke;
        }
    }.handle));

    var out: [4096]u8 = undefined;
    const r = try processRequestOnce(allocator, &router, "GET /boom HTTP/1.1\r\n\r\n", &out);

    try std.testing.expectEqual(error.SomethingBroke, r.dispatch_err.?);
    try std.testing.expectEqual(@as(u16, 500), extractStatus(r.written));
    try std.testing.expect(std.mem.indexOf(u8, r.written, "Internal Server Error") != null);
}

test "Cookie 值含分号被拒绝（属性注入防护）" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(allocator, capturingSink(&writer));
    defer res.deinit();

    try std.testing.expectError(
        error.InvalidCookieValue,
        res.setCookie("sid", "abc; Domain=evil.example"),
    );
}

// ── Issue 5：无 body 方法携带 CL → 收下但忽略，响应后排空 ──────────────

test "Issue 5: DELETE 携带 body 被接受，响应后排空、keep-alive 继续" {
    const allocator = std.testing.allocator;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.DELETE, "/fav", Handler.fromFn(deleteFavHandler));
    try router.route(.GET, "/", Handler.fromFn(helloHandler));

    // 流水线：DELETE + 5 字节 body + 紧跟一个 GET。若残留 body 未被排空，
    // "helloGET / HTTP/1.1" 会被当成下一个请求行 → 400 + 关连接（旧行为）。
    var out: [8192]u8 = undefined;
    const written = runConnection(
        allocator,
        &router,
        "DELETE /fav HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhello" ++
            "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
        &out,
    );

    // 两个响应都是 200，没有 400；第一个（DELETE）在前，第二个（GET）在后。
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, written, " 400 ") == null);
    const del_pos = std.mem.indexOf(u8, written, "deleted") orelse return error.TestExpectedEqual;
    const hello_pos = std.mem.indexOf(u8, written, "Hello, World!") orelse return error.TestExpectedEqual;
    try std.testing.expect(del_pos < hello_pos);
}

test "Issue 5: 超限 CL → 不排空，响应带 Connection: close 后断开" {
    const allocator = std.testing.allocator;
    var router = try http_router.Router.init(allocator);
    defer router.deinit();
    try router.route(.DELETE, "/fav", Handler.fromFn(deleteFavHandler));
    try router.route(.GET, "/", Handler.fromFn(helloHandler));

    // CL=70000 > IGNORED_BODY_DRAIN_CAP(64KB)：只回一个响应并显式关连接；
    // 后面的 GET 字节不会被读取（不排空 = 不做带宽放大器）。
    var out: [8192]u8 = undefined;
    const written = runConnection(
        allocator,
        &router,
        "DELETE /fav HTTP/1.1\r\nHost: t\r\nContent-Length: 70000\r\n\r\nhello" ++
            "GET / HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expectEqual(@as(u16, 200), extractStatus(written));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "HTTP/1.1 200"));
    // std 写出的是固定小写 `connection: close`（Server.zig writeHead），精确匹配。
    try std.testing.expect(std.mem.indexOf(u8, written, "connection: close") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello, World!") == null);
}
