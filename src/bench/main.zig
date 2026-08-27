//! 性能基准 — 框架热路径微基准（不依赖真实 TCP）。
//!
//! 用 `std.Io.Writer.Discarding` 作为响应 sink，在内存里驱动完整的
//! Router.dispatch（trie 匹配 + 中间件管道 + handler + 响应构建），
//! 度量纯框架开销（排除网络/内核）。这些数字是**框架内部吞吐上限**的参考，
//! 不等于端到端 HTTP QPS（后者受 zio/内核/网络支配，见 README「性能」）。
//!
//! 运行：
//! ```
//! zig build bench -Doptimize=ReleaseFast
//! ```

const std = @import("std");
const framework = @import("http_framework");

const Context = framework.Context;
const Response = framework.Response;
const Request = framework.Request;
const Router = framework.Router;
const Handler = framework.Handler;
const Middleware = framework.Middleware;
const Sink = framework.Sink;

// ── 测试 handler / 中间件 ─────────────────────────────────────

fn plainHandler(_: *Context, res: *Response) !void {
    try res.statusCode(.ok).text("Hello, World!");
}

fn userHandler(ctx: *Context, res: *Response) !void {
    const id = ctx.param("id") orelse "0";
    try res.statusCode(.ok).text(id);
}

fn jsonHandler(_: *Context, res: *Response) !void {
    try res.json(.{ .status = "ok", .code = 200, .msg = "benchmark" });
}

const NoopMiddleware = struct {
    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: framework.Next) !void {
        try next.call(ctx, res);
    }
};

// ── 丢弃型 Sink：把响应写进 Discarding writer（只计数，不保留字节）──

fn discardingSink(w: *std.Io.Writer) Sink {
    const impl = struct {
        fn respond(ptr: *anyopaque, status: std.http.Status, headers: []const std.http.Header, body: []const u8, keep_alive: bool) anyerror!void {
            _ = status;
            _ = headers;
            _ = keep_alive;
            const dw: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try dw.writeAll(body);
        }
        fn startStream(_: *anyopaque, _: std.http.Status, _: []const std.http.Header, _: ?u64, _: []u8, _: bool) anyerror!std.http.BodyWriter {
            return error.NotSupported;
        }
    };
    return .{
        .ptr = @ptrCast(w),
        .vtable = &.{ .respond = impl.respond, .startStream = impl.startStream },
    };
}

// ── 基准运行器 ────────────────────────────────────────────────

const Case = struct {
    name: []const u8,
    method: std.http.Method,
    path: []const u8,
};

fn buildRequest(path: []const u8) Request {
    const query_start = std.mem.indexOfScalar(u8, path, '?');
    const p = if (query_start) |i| path[0..i] else path;
    const q = if (query_start) |i| path[i + 1 ..] else "";
    return .{
        .method = .GET,
        .target = path,
        .path = p,
        .query = q,
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\nHost: bench\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    router: *const Router,
    case: Case,
    iterations: u64,
) !f64 {
    var discard: std.Io.Writer.Discarding = .init(&.{});

    // 预热一次，确保路径命中且无编译期未触达分支。
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var state = framework.RequestState{};
        defer state.deinit(arena.allocator());
        const cfg = framework.RequestConfig{};
        var req = buildRequest(case.path);
        var ctx = Context{ .request = &req, .state = &state, .config = &cfg, .arena = arena.allocator(), .io = io };
        var res = Response.init(arena.allocator(), discardingSink(&discard.writer));
        defer res.deinit();
        _ = try router.dispatch(&ctx, &res);
    }

    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var i: u64 = 0;
    // 复用 arena（每轮 reset .retain_capacity）——匹配真实 keep-alive 热路径：
    // ConnectionRunner 对每个连接复用同一个 request arena，而非每请求重建。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    while (i < iterations) : (i += 1) {
        var state = framework.RequestState{};
        const cfg = framework.RequestConfig{};
        var req = buildRequest(case.path);
        var ctx = Context{ .request = &req, .state = &state, .config = &cfg, .arena = arena.allocator(), .io = io };
        var res = Response.init(arena.allocator(), discardingSink(&discard.writer));
        _ = try router.dispatch(&ctx, &res);
        res.deinit();
        state.deinit(arena.allocator());
        _ = arena.reset(.retain_capacity);
    }
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start;

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const ops_per_s = @as(f64, @floatFromInt(iterations)) / elapsed_s;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));

    std.debug.print("  {s:<28} {d:>12.0} ops/s   {d:>8.1} ns/op\n", .{ case.name, ops_per_s, ns_per_op });
    return ops_per_s;
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    // 构建带完整中间件管道的 router（3 层 noop + 真实路由）。
    var router = try Router.init(allocator);
    defer router.deinit();
    try router.route(.GET, "/", Handler.fromFn(plainHandler));
    try router.route(.GET, "/users/:id", Handler.fromFn(userHandler));
    try router.route(.GET, "/api/json", Handler.fromFn(jsonHandler));

    var mw1 = NoopMiddleware{};
    var mw2 = NoopMiddleware{};
    var mw3 = NoopMiddleware{};
    try router.use(Middleware.init(NoopMiddleware, &mw1));
    try router.use(Middleware.init(NoopMiddleware, &mw2));
    try router.use(Middleware.init(NoopMiddleware, &mw3));

    const iterations: u64 = 1_000_000;

    std.debug.print("\nhttp-framework 微基准（Router.dispatch 热路径，{d} 次/项，3 层中间件）\n", .{iterations});
    std.debug.print("  注：内存内基准，排除网络/内核；端到端 QPS 见 README。\n\n", .{});

    const cases = [_]Case{
        .{ .name = "static route (fromFn)", .method = .GET, .path = "/" },
        .{ .name = "param route (/users/:id)", .method = .GET, .path = "/users/12345" },
        .{ .name = "json response", .method = .GET, .path = "/api/json" },
        .{ .name = "404 (unmatched)", .method = .GET, .path = "/nope/nothing" },
    };

    for (cases) |case| {
        _ = try runCase(allocator, io, &router, case, iterations);
    }
    std.debug.print("\n", .{});
}
