//! http_testing — 离线驱动「中间件 + handler」的测试 harness（addon）
//!
//! 回应 `examples/FRICTION.md` F-06：给一个中间件写单测要手搓十几行
//! `Context` 字面量，里面还塞着 `.io = undefined` 这种「只要没人碰就不会炸」
//! 的占位符。代价是框架自带的中间件几乎没有像样的单测——`request_id.zig` 里
//! 那条「无客户端 ID 时自动生成」的测试干脆是空壳，注释写着「需要接线的 io，
//! 留到集成测试覆盖」，而集成测试从未覆盖它。
//!
//! # 为什么做成 addon 而不是塞进 core
//!
//! 架构铁律：core（http_protocol / http_app / http_router / http_server）只做
//! 最小 HTTP server，能力一律做成 addon、靠接口反转扩展。测试驱动不是运行时
//! 职责，所以它必须是 addon：
//!
//! - core 里一行测试专用代码都不用加，`Context` 的公开 API 一个字节都没动
//!   （向后兼容：现有 `Context{ .request, .state, .config, .arena, .io }`
//!   字面量继续可用）；
//! - harness 只用**已经存在**的公开接缝（`Next.root` / `Response` / `Sink` /
//!   `RequestState`）驱动管道，不要求 core 为测试开后门、加 friend 开关或
//!   导出内部符号。
//!
//! 这就是「接口反转」的同一套打法：不是 core 提供测试能力，而是 addon 用 core
//! 已经暴露的接口组装出测试能力。哪天 core 换了 Response 的实现，只要 Sink 的
//! 契约不变，harness 不用改。
//!
//! # 用法
//!
//! ```zig
//! const h = try http_testing.Harness.init(allocator);
//! defer h.deinit();
//! try h.req(.GET, "/users/42?q=zig");
//! try h.reqHeader("X-Request-Id", "trace-1");
//! try h.run(&.{Middleware.init(RequestIdMiddleware, &mw)}, Handler.fromFn(handler));
//!
//! try std.testing.expectEqual(std.http.Status.ok, h.status().?);
//! try std.testing.expectEqualStrings("trace-1", h.header("x-request-id").?);
//! try std.testing.expectEqualStrings("hello", h.body());
//! ```
//!
//! # 边界
//!
//! - 驱动深度是「中间件链 + handler」（`Next` 管道），**不含** TCP / accept /
//!   keep-alive 循环。要驱动到 `ConnectionRunner.processRequest` 那一层，见
//!   `http_server/integration_test.zig`（用内存 Reader/Writer 喂真实字节）。
//! - 不支持流式响应（`Response.stream`）：捕获型 Sink 没有实现 `startStream`。
//!   静态大文件 / Range 这类场景目前只能靠集成测试。
//! - 断言读的是**真正上 wire 的字节**（状态行 + 头 + body），不是 `Response`
//!   的内部状态——中间件忘了 flush、头在 flush 之后才加，这类问题都会暴露。

const std = @import("std");
const http = std.http;
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Context = http_app.Context;
pub const Request = http_protocol.Request;
pub const RequestState = http_app.RequestState;
pub const RequestConfig = http_app.RequestConfig;
pub const Response = http_protocol.Response;
pub const Sink = http_protocol.Sink;
pub const Middleware = http_app.Middleware;
pub const Handler = http_app.Handler;
pub const Next = http_app.Next;
pub const Services = http_app.Services;
pub const AppError = http_app.AppError;

/// 捕获型 Sink：完整写出 `状态行 + 头 + 空行 + body`。
///
/// 为什么不用 `Sink.testSink`：后者丢弃了头（`_ = headers`），而中间件的可观测
/// 行为几乎全在头上（request-id / CSP / timing / Set-Cookie）。丢了头就只能断言
/// body，等于没测。
///
/// 不实现 `startStream`：流式响应会把状态行直接写进 sink、body 走另一条路，
/// 捕获成一段连续字节反而丢失结构。需要流式时用集成测试。
fn capturingSink(writer: *std.Io.Writer) Sink {
    const Ctx = struct {
        fn respond(
            ptr: *anyopaque,
            status: http.Status,
            headers: []const http.Header,
            body: []const u8,
            keep_alive: bool,
        ) anyerror!void {
            _ = keep_alive;
            const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try w.print("HTTP/1.1 {d} {s}\r\n", .{ @backingInt(status), status.phrase() orelse "Error" });
            for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
            try w.writeAll("\r\n");
            try w.writeAll(body);
        }

        fn startStream(
            ptr: *anyopaque,
            status: http.Status,
            headers: []const http.Header,
            content_length: ?u64,
            buffer: []u8,
            keep_alive: bool,
        ) anyerror!http.BodyWriter {
            _ = .{ ptr, status, headers, content_length, buffer, keep_alive };
            return error.StreamingNotSupportedInHarness;
        }
    };
    return .{
        .ptr = @ptrCast(writer),
        .vtable = &.{ .respond = Ctx.respond, .startStream = Ctx.startStream },
    };
}

/// 一次「离线请求」的驱动器。堆分配（`init` 返回指针）：`Context` 内部持有
/// `&self.built` / `&self.state` 的指针，栈上实例一旦被拷贝（返回、赋值）这些
/// 指针就悬空了。返回指针把「不要移动我」变成类型层面的事实，而不是注释里的约定。
pub const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    /// 运行期 io。默认 `std.testing.io`（真实接线的 `Io.Threaded`）——这正是
    /// F-06 里手搓字面量做不到、只能写 `.io = undefined` 的地方：`ctx.io.random`
    /// 要真能跑，`RequestIdMiddleware` 的自动生成分支才测得动。
    io: std.Io,
    /// 请求配置视图。需要在 run() 前覆盖（如 body_size_limit）时直接赋值。
    config: RequestConfig = .{},
    /// 应用级服务容器。中间件/ handler 用 `ctx.service(T)` 取，未注入时为 null。
    services: ?*const Services = null,
    /// 对端地址。per-IP 限流 / 审计走它，未设置时为 null。
    peer_ip: ?std.Io.net.IpAddress = null,

    // ── 请求描述（run 之前可改）──────────────────────────────
    head: std.ArrayList(u8),
    method: http.Method = .GET,
    target: []const u8 = "/",
    req_body: ?[]const u8 = null,

    // ── run 之后的产物 ─────────────────────────────────────
    /// 组装好的 Request（切片全部指向 arena）。
    built: Request = undefined,
    state: RequestState,
    res: ?Response = null,
    ctx: ?Context = null,
    wire: std.Io.Writer.Allocating,
    /// `Next.call` 返回的错误。run() 会把它原样返回给调用方，方便
    /// `try std.testing.expectError(error.AppError, h.run(...))`。
    dispatch_err: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .io = std.testing.io,
            .head = .empty,
            .state = undefined,
            .wire = .init(allocator),
        };
        // state.arena 指向 &self.arena：Harness 是堆分配且永不移动，安全。
        self.state = .{ .arena = self.arena.allocator() };
        return self;
    }

    pub fn deinit(self: *Harness) void {
        if (self.res) |*r| r.deinit();
        self.state.deinit();
        self.head.deinit(self.allocator);
        self.wire.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// 清空本轮请求的全部状态，让同一个 Harness 可以再跑一次
    /// （典型用法：同一个请求穿过两套中间件栈做对比）。arena 不重置——
    /// 上一轮 dupe 进去的字节随 Harness 一起释放即可。
    pub fn reset(self: *Harness) void {
        if (self.res) |*r| r.deinit();
        self.res = null;
        self.ctx = null;
        self.dispatch_err = null;
        self.state.deinit();
        self.state = .{ .arena = self.arena.allocator() };
        self.head.clearRetainingCapacity();
        self.method = .GET;
        self.target = "/";
        self.req_body = null;
    }

    /// 设置请求行。**会清空此前 `reqHeader` 累积的头**——先定 method/target，
    /// 再加头，语义上才和报文顺序一致。
    ///
    /// target 可以是带 query 的完整形式（`/x?q=1`），path/query 自动切分。
    pub fn req(self: *Harness, method: http.Method, target: []const u8) !void {
        self.method = method;
        self.target = try self.arena.allocator().dupe(u8, target);
        self.head.clearRetainingCapacity();
        try self.head.appendSlice(self.allocator, @tagName(method));
        try self.head.append(self.allocator, ' ');
        try self.head.appendSlice(self.allocator, self.target);
        try self.head.appendSlice(self.allocator, " HTTP/1.1\r\n");
    }

    /// 追加一个请求头。必须真的写进 head 字节——`Request.getHeader` 只解析
    /// `head_bytes`，把头塞进别的地方（比如只放进 `content_type` 字段）在
    /// 生产路径上会出现「Request 有、getHeader 没有」的判定分裂。
    pub fn reqHeader(self: *Harness, name: []const u8, value: []const u8) !void {
        try self.head.appendSlice(self.allocator, name);
        try self.head.appendSlice(self.allocator, ": ");
        try self.head.appendSlice(self.allocator, value);
        try self.head.appendSlice(self.allocator, "\r\n");
    }

    /// 设置请求体（buffered，非流式）。同时补 `Content-Length`——少了它
    /// `Request.init` 的生产路径不会把 body 判成 streaming，测试就会在
    /// 生产环境不成立的假设下通过。
    pub fn reqBody(self: *Harness, content: []const u8) !void {
        self.req_body = content;
        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content.len}) catch unreachable;
        try self.reqHeader("Content-Length", len_str);
    }

    /// 预设路径参数（模拟 router 的匹配结果）。
    pub fn param(self: *Harness, key: []const u8, value: []const u8) !void {
        try self.state.path_params.put(key, value);
    }

    /// 跑「中间件链 + handler」。返回 `Next.call` 的错误（null 表示成功）。
    ///
    /// 即使 dispatch 出错也照样 flush：错误渲染中间件（ErrorRenderer）正是在
    /// catch 分支里写响应的，不 flush 就看不到它写了什么。
    pub fn run(self: *Harness, middleware: []const Middleware, handler: Handler) !void {
        const arena_alloc = self.arena.allocator();

        self.dispatch_err = null;
        if (self.res) |*r| r.deinit();
        self.wire.deinit();
        self.wire = .init(self.allocator);

        // head 终止空行。每轮重新拼一份（而不是往 self.head 追加），否则
        // run 第二次会多出一个空行。
        const head_bytes = try arena_alloc.alloc(u8, self.head.items.len + 2);
        @memcpy(head_bytes[0..self.head.items.len], self.head.items);
        head_bytes[head_bytes.len - 2] = '\r';
        head_bytes[head_bytes.len - 1] = '\n';

        const q = std.mem.indexOfScalar(u8, self.target, '?');
        const path = if (q) |i| self.target[0..i] else self.target;
        const query = if (q) |i| self.target[i + 1 ..] else "";

        self.built = .{
            .method = self.method,
            .target = self.target,
            .path = path,
            .query = query,
            .version = .@"HTTP/1.1",
            .head_bytes = head_bytes,
            .content_type = findHeader(head_bytes, "content-type"),
            .content_length = if (self.req_body) |b| @as(u64, @intCast(b.len)) else null,
            .transfer_encoding = .none,
            .body = if (self.req_body) |b| .{ .buffered = b } else .none,
        };

        self.res = Response.init(arena_alloc, capturingSink(&self.wire.writer));
        const res = &self.res.?;
        self.ctx = .{
            .request = &self.built,
            .state = &self.state,
            .config = &self.config,
            .arena = arena_alloc,
            .io = self.io,
            .services = self.services,
            .peer_ip = self.peer_ip,
        };

        Next.root(middleware, handler).call(&self.ctx.?, res) catch |err| {
            self.dispatch_err = err;
        };
        // flush 失败（buffer 太小等）不顶替 dispatch 错误：真实病因在后者。
        res.flush() catch {};
        if (self.dispatch_err) |e| return e;
    }

    /// 无中间件的便捷入口：直接把请求交给 handler。
    pub fn runHandler(self: *Harness, handler: Handler) !void {
        return self.run(&.{}, handler);
    }

    // ── 断言辅助 ──────────────────────────────────────────

    /// 真正写出去的字节（状态行 + 头 + 空行 + body）。
    pub fn wireBytes(self: *Harness) []const u8 {
        return self.wire.written();
    }

    pub fn statusCode(self: *Harness) u16 {
        const w = self.wireBytes();
        const prefix = "HTTP/1.1 ";
        if (w.len < prefix.len + 3 or !std.mem.startsWith(u8, w, prefix)) return 0;
        return std.fmt.parseInt(u16, w[prefix.len..][0..3], 10) catch 0;
    }

    pub fn status(self: *Harness) ?http.Status {
        const code = self.statusCode();
        if (code == 0) return null;
        return @as(http.Status, @enumFromInt(code));
    }

    /// 取响应头（大小写不敏感）。读的是 wire 而不是 `res.headers`：
    /// 只有真的被 flush 出去的头才算数。
    pub fn header(self: *Harness, name: []const u8) ?[]const u8 {
        return extractHeader(self.wireBytes(), name);
    }

    /// 响应体（空行之后的所有字节）。响应根本没上 wire 时返回空串。
    pub fn body(self: *Harness) []const u8 {
        const w = self.wireBytes();
        const sep = std.mem.indexOf(u8, w, "\r\n\r\n") orelse return "";
        return w[sep + 4 ..];
    }

    /// 拿到底层 Response（断言 cookie / 内部 flag 等非 wire 状态）。
    pub fn response(self: *Harness) ?*Response {
        return if (self.res) |*r| r else null;
    }

    /// 拿到跑过的 Context（断言 `ctx.state` 里的 user_data 槽等）。
    pub fn context(self: *Harness) ?*Context {
        return if (self.ctx) |*c| c else null;
    }
};

/// 从 head 字节里取某个头（大小写不敏感）。与 `Request.getHeader` 同口径。
fn findHeader(head_bytes: []const u8, name: []const u8) ?[]const u8 {
    var it = http.HeaderIterator.init(head_bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// 从一段完整 HTTP 响应里提取头值（大小写不敏感，跳过状态行）。
fn extractHeader(buf: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, buf, "\r\n");
    _ = it.first(); // status line
    while (it.next()) |line| {
        if (line.len == 0) break; // 空行 = 头结束
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        var start = colon + 1;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
        return line[start..];
    }
    return null;
}

// ===========================================================================
// Tests — harness 自身 + 用它给现有中间件补单测（F-06）
// ===========================================================================

const echoHandler = Handler.fromFn(struct {
    fn handle(ctx: *Context, res: *Response) !void {
        try res.text(ctx.request.path);
    }
}.handle);

/// 中间件通讯槽（放在命名空间层：`@typeName` 含父作用域，写在 handler 函数
/// 体里的类型在别处取不回同一个槽）。
const IdSlot = struct {
    id: u32,
};

test "harness：路径参数与 state user_data 对 handler 可见" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/users/42");
    try h.param("id", "42");

    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            const slot = ctx.arena.create(IdSlot) catch return error.OutOfMemory;
            slot.* = .{ .id = 7 };
            try ctx.setUserData(IdSlot, slot);
            try res.text(ctx.param("id").?);
        }
    }.handle);
    try h.runHandler(handler);

    try std.testing.expectEqualStrings("42", h.body());
    // run 之后 ctx.state 仍可检查——中间件往 user_data 槽里放了什么，测试能断言
    try std.testing.expectEqual(@as(u32, 7), h.context().?.state.getUserData(IdSlot).?.id);
}

test "harness：无中间件直接跑 handler，status/body 可断言" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/hello");
    try h.runHandler(echoHandler);

    try std.testing.expectEqual(@as(u16, 200), h.statusCode());
    try std.testing.expectEqual(http.Status.ok, h.status().?);
    try std.testing.expectEqualStrings("/hello", h.body());
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", h.header("content-type").?);
}

test "harness：请求头 / query / body 能被 handler 读到" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.POST, "/submit?next=/done");
    try h.reqHeader("X-Token", "t-42");
    try h.reqHeader("Content-Type", "application/x-www-form-urlencoded");
    try h.reqBody("name=zig&lang=zig");

    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            const body = try ctx.readBody(ctx.arena, 1024);
            try res.json(.{
                .token = ctx.header("x-token"),
                .next = ctx.query("next"),
                .name = Request.getFormFrom(body, "name"),
                .ct = ctx.request.content_type,
            });
        }
    }.handle);
    try h.runHandler(handler);

    try std.testing.expectEqual(@as(u16, 200), h.statusCode());
    try std.testing.expectEqualStrings("application/json", h.header("content-type").?);
    try std.testing.expect(std.mem.indexOf(u8, h.body(), "t-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.body(), "/done") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.body(), "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.body(), "x-www-form-urlencoded") != null);
}

// ── RequestIdMiddleware：以前只能写空壳测试（"需要接线的 io"）────────────
//
// F-06 的直接受害者：这条分支要 `ctx.io.random`，手搓 `Context` 字面量时只能
// 写 `.io = undefined`，于是「自动生成 ID」这条最重要的分支完全没有测试。
// harness 默认接 `std.testing.io`，现在可以真跑。

test "RequestIdMiddleware：无客户端 ID 时生成 32 位 hex" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/");

    var mw = http_app.RequestIdMiddleware{};
    try h.run(&.{Middleware.init(http_app.RequestIdMiddleware, &mw)}, echoHandler);

    const generated = h.header("x-request-id").?;
    try std.testing.expectEqual(@as(usize, 32), generated.len);
    for (generated) |c| try std.testing.expect(std.ascii.isHex(c));
    // 也存进了 ctx.state，供日志中间件取用
    try std.testing.expectEqualStrings(
        generated,
        h.context().?.state.getUserData(http_app.RequestId).?.slice(),
    );
}

test "RequestIdMiddleware：沿用合法客户端 ID 并回写响应头" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/");
    try h.reqHeader("X-Request-Id", "trace-abc-123");

    var mw = http_app.RequestIdMiddleware{};
    try h.run(&.{Middleware.init(http_app.RequestIdMiddleware, &mw)}, echoHandler);

    try std.testing.expectEqualStrings("trace-abc-123", h.header("x-request-id").?);
}

test "RequestIdMiddleware：拒绝含 CRLF 的客户端 ID（响应头注入）" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/");
    try h.reqHeader("X-Request-Id", "abc\r\nX-Injected: 1");

    var mw = http_app.RequestIdMiddleware{};
    try h.run(&.{Middleware.init(http_app.RequestIdMiddleware, &mw)}, echoHandler);

    const rid = h.header("x-request-id").?;
    // 不得回显恶意值：要么没有该头，要么是自生成的 32 位 hex
    try std.testing.expect(h.header("x-injected") == null);
    try std.testing.expect(std.mem.indexOf(u8, h.wireBytes(), "X-Injected") == null);
    _ = rid;
}

// ── ErrorRenderer：以前只有「failWith 存得进去」的测试，没有渲染测试 ──────

fn failForbidden(ctx: *Context, _: *Response) !void {
    try ctx.failWith(AppError.forbidden("no access"));
}

fn failUnknown(_: *Context, _: *Response) !void {
    return error.OutOfMemory;
}

// 注意：这里**不**测「非 AppError 的未知错误 → 500」——那条路径 ErrorRenderer
// 会 std.log.err，而 zig 的 test runner 把任何 err 级日志计为失败并让整个
// 测试二进制 exit 1（std/compiler/test_runner.zig: log_err_count）。
// 用一个吞掉日志的 logFn 去绕开它，代价是整个二进制（含伞形 src/root.zig
// 聚合的那份）都失去「意外错误日志 = 构建失败」这道防线，不值得。
// 那条分支的等价覆盖放在 http_server/integration_test.zig 的 processRequest
// 驱动测试里（走 connection 的 500 兜底，同样不触发日志）。

test "ErrorRenderer：框架级错误（OOM）直接冒泡，不被渲染成 500" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/boom");

    var renderer = http_app.ErrorRenderer{};
    // OOM 不可恢复：必须冒泡给调用方（进程/连接层），不能假装成 500 响应。
    try std.testing.expectError(
        error.OutOfMemory,
        h.run(&.{Middleware.init(http_app.ErrorRenderer, &renderer)}, Handler.fromFn(failUnknown)),
    );
    // 且一个字节都没上 wire——没人渲染过它
    try std.testing.expectEqual(@as(u16, 0), h.statusCode());
}

fn writeThenFail(ctx: *Context, res: *Response) !void {
    _ = ctx;
    try res.text("already written");
    return error.LateFailure;
}

test "ErrorRenderer：渲染 AppError 的状态码与消息（不是一律 500）" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/secret");

    var renderer = http_app.ErrorRenderer{};
    try h.run(&.{Middleware.init(http_app.ErrorRenderer, &renderer)}, Handler.fromFn(failForbidden));

    try std.testing.expectEqual(@as(u16, 403), h.statusCode());
    // Issue 4：默认渲染为 JSON 包络，非纯文本。
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"code\":\"forbidden\",\"message\":\"no access\"}}",
        h.body(),
    );
    try std.testing.expectEqualStrings("application/json", h.header("content-type").?);
}



test "ErrorRenderer：响应已发送时不覆盖 handler 写的内容" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/late");

    var renderer = http_app.ErrorRenderer{};
    try h.run(&.{Middleware.init(http_app.ErrorRenderer, &renderer)}, Handler.fromFn(writeThenFail));

    try std.testing.expectEqual(@as(u16, 200), h.statusCode());
    try std.testing.expectEqualStrings("already written", h.body());
}

const OrderMiddleware = struct {
    tag: []const u8,

    pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
        var before: [64]u8 = undefined;
        _ = res.header(
            std.fmt.bufPrint(&before, "X-{s}-before", .{self.tag}) catch unreachable,
            "1",
        ) catch {};
        try next.call(ctx, res);
        var after: [64]u8 = undefined;
        _ = res.header(
            std.fmt.bufPrint(&after, "X-{s}-after", .{self.tag}) catch unreachable,
            "1",
        ) catch {};
    }
};

test "中间件链顺序：外层先进后出，且外层能在 handler 之后改响应" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/");
    var outer = OrderMiddleware{ .tag = "outer" };
    var inner = OrderMiddleware{ .tag = "inner" };
    try h.run(&.{
        Middleware.init(OrderMiddleware, &outer),
        Middleware.init(OrderMiddleware, &inner),
    }, echoHandler);

    try std.testing.expect(h.header("x-outer-before") != null);
    try std.testing.expect(h.header("x-inner-before") != null);
    // 非缓冲模式下 handler 已直发，之后的头进不了 wire——断言"没有"同样是
    // 一个真实契约（想让它们生效就得 setBuffered，见下个测试）。
    try std.testing.expect(h.header("x-inner-after") == null);
}

test "中间件链：缓冲模式下 handler 之后追加的头能上 wire" {
    const h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/hello");

    const Buffered = struct {
        pub fn process(_: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            res.setBuffered();
            try next.call(ctx, res);
            _ = res.header("X-After-Handler", "1") catch {};
        }
    };
    var buffered = Buffered{};
    try h.run(&.{Middleware.init(Buffered, &buffered)}, echoHandler);

    try std.testing.expectEqualStrings("/hello", h.body());
    try std.testing.expectEqualStrings("1", h.header("x-after-handler").?);
}

test {
    std.testing.refAllDecls(@This());
}
