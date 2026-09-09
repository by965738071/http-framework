//! http_codec — 请求体编解码（依赖 http_app, http_protocol）
//!
//! 提供请求体的高级解析能力：
//! - `parseJson(T, allocator, bytes)`：把 JSON 字节解析成 typed struct
//! - `JsonBody(T)`：中间件，预解析 JSON body 到 ctx user_data 槽
//!
//! 设计原则：
//! - 不在 http_protocol 层引入 std.json 依赖（protocol 层零依赖）
//! - 解析结果存入 arena，请求结束自动回收——不调 parsed.deinit()
//!   （arena allocator 的 free 是 no-op，arena reset 时全部回收）

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Request = http_protocol.Request;
pub const Context = http_app.Context;
pub const AppError = http_app.AppError;
pub const Response = http_protocol.Response;
pub const Next = http_app.Next;

/// 从字节切片解析 JSON，返回分配在 allocator 上的 *T。
///
/// **allocator 必须是请求级 arena（如 `ctx.arena`）**：`parseFromSliceLeaky`
/// 把全部内部分配直接落在 allocator 上，不产生需要 deinit 的 `Parsed(T)`
/// 句柄——若传非 arena 分配器（如 gpa），这些内存没有任何回收路径，
/// 就是泄漏。arena 下 free 为 no-op，请求结束 reset/回收全部。
///
/// 固定行为（不对调用方开放配置）：
/// - `ignore_unknown_fields = true`：未知字段宽松忽略（面向 API DTO 的常见
///   需求）；需要严格校验未知字段的场景请在业务层自行检查。
/// - `allocate = .alloc_always`：字符串切片一律深拷贝进 allocator，不与
///   `bytes` 入参的内存发生别名——即使 bytes 来自短命缓冲，返回值仍有效。
///   （代价：body 已在 arena 时多一次拷贝，换取公共 API 的输入无关性。）
pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !*T {
    const result = try allocator.create(T);
    result.* = try std.json.parseFromSliceLeaky(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return result;
}

/// 判断 Content-Type 是否为 application/json。大小写不敏感；匹配后要求下一
/// 字符是 `;`/空白/结尾，避免误命中 application/json-patch+json 等变体。
fn isJsonContentType(ct: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(ct, "application/json")) return false;
    if (ct.len == "application/json".len) return true;
    const next = ct["application/json".len];
    return next == ';' or next == ' ' or next == '\t';
}

/// JSON Body 中间件：预解析 application/json 请求体为 typed struct，
/// 存入 `ctx.user_data` 槽。handler 用 `ctx.getUserData(T)` 取出。
///
/// 契约（调用方必读）：
/// - **`getUserData(T)` 可能为 null**：无 Content-Type / 非 JSON / 无 body /
///   空 body 时中间件直接透传，不解析也不塞 T。handler 必须用
///   `orelse` 兜底（如缺 body 回 400），不要 `.?` 硬取。
/// - 413/400 统一走 `ctx.failWith(AppError)` 冒泡，由 ErrorRenderer 渲染
///   （框架推荐路径，与 handler 层错误处理一致）；管道应挂 ErrorRenderer。
///   未挂时由连接层兑底 500（语义降级但不挂死连接）。
/// - `error.OutOfMemory` 向上传播（不可恢复，不能吞成 400）。
///
/// 用法：
/// ```zig
/// const LoginReq = struct { username: []const u8, password: []const u8 };
/// var mw = JsonBody(LoginReq).init(1 << 20); // 1MB limit
/// router.use(Middleware.init(JsonBody(LoginReq), &mw));
/// ```
pub fn JsonBody(comptime T: type) type {
    return struct {
        limit: u64,

        const Self = @This();

        pub fn init(limit: u64) Self {
            return .{ .limit = limit };
        }

        pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
            const ct = ctx.request.content_type orelse {
                return next.call(ctx, res);
            };
            // 只处理 application/json（P2-25：大小写不敏感，Application/JSON 也应命中，
            // 与 multipart.from 的 startsWithIgnoreCase 保持一致）。匹配后要求下一字符是
            // `;`/空白/结尾，避免误命中 application/json-patch+json 等变体。
            if (!isJsonContentType(ct)) {
                return next.call(ctx, res);
            }
            // 只处理有 body 的请求
            switch (ctx.request.body) {
                .none => return next.call(ctx, res),
                else => {},
            }

            const body = ctx.readBody(ctx.arena, self.limit) catch |err| {
                if (err == error.BodyTooLarge) {
                    // 413 后连接不应继续复用：避免 keep-alive 连接去 drain 超限 body，
                    // 放大连接占用。keep_alive=false 在 ErrorRenderer 渲染 flush 时同样
                    // 生效；即使无 ErrorRenderer 由连接层兑底，也会带着关连接语义。
                    res.keep_alive = false;
                    return ctx.failWith(AppError.payloadTooLarge("request body too large"));
                }
                return err;
            };
            if (body.len == 0) return next.call(ctx, res);

            const parsed = parseJson(T, ctx.arena, body) catch |err| {
                // 非解析错误（如 OOM）向上传播，不能吞成 400。
                if (err == error.OutOfMemory) return error.OutOfMemory;
                // 解析失败：统一走 failWith → ErrorRenderer，不再直写裸响应
                // （与框架其它错误处理路径一致，结构化渲染/缓冲模式都兼容）。
                return ctx.failWith(AppError.badRequest("invalid JSON body"));
            };

            try ctx.setUserData(T, parsed);
            return next.call(ctx, res);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseJson parses struct from slice" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Point = struct { x: i32, y: i32 };
    const p = try parseJson(Point, arena.allocator(), "{\"x\":1,\"y\":2}");
    try std.testing.expectEqual(@as(i32, 1), p.x);
    try std.testing.expectEqual(@as(i32, 2), p.y);
}

test "parseJson handles string fields" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const User = struct { name: []const u8, age: u8 };
    const u = try parseJson(User, arena.allocator(), "{\"name\":\"alice\",\"age\":30}");
    try std.testing.expectEqualStrings("alice", u.name);
    try std.testing.expectEqual(@as(u8, 30), u.age);
}

test "parseJson ignores unknown fields" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const S = struct { keep: u32 };
    const s = try parseJson(S, arena.allocator(), "{\"keep\":1,\"extra\":2}");
    try std.testing.expectEqual(@as(u32, 1), s.keep);
}

test "parseJson rejects malformed JSON" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const S = struct { x: u32 };
    // Malformed JSON should produce a parse error
    _ = parseJson(S, arena.allocator(), "not json") catch return;
    try std.testing.expect(false); // should have returned above
}

test "isJsonContentType matches application/json but not lookalikes" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("Application/JSON"));
    try std.testing.expect(isJsonContentType("application/json \t"));
    // 误命中变体：这些都不应匹配
    try std.testing.expect(!isJsonContentType("application/json-patch+json"));
    try std.testing.expect(!isJsonContentType("application/json5"));
    try std.testing.expect(!isJsonContentType("application/xml"));
}

// ── JsonBody.process 分支覆盖测试 ────────────────────────────────────

const TestUser = struct { name: []const u8, age: u8 };

/// 测试脚手架：栈上组装 Request/Context/Response，驱动 JsonBody.process。
const CodecEnv = struct {
    arena: std.heap.ArenaAllocator = undefined,
    state: http_app.RequestState = undefined,
    cfg: http_app.RequestConfig = .{},
    req: Request = undefined,
    ctx: Context = undefined,
    buf: [4096]u8 = undefined,
    writer: std.Io.Writer = undefined,
    res: Response = undefined,

    const Opts = struct {
        child: ?std.mem.Allocator = null, // arena 的底层分配器（默认 testing.allocator）
        content_type: ?[]const u8 = null,
        body: Request.Body = .none,
        content_length: ?u64 = null,
    };

    fn begin(self: *CodecEnv, opts: Opts) void {
        self.arena = std.heap.ArenaAllocator.init(opts.child orelse std.testing.allocator);
        const a = self.arena.allocator();
        self.state = .{ .arena = a };
        self.writer = std.Io.Writer.fixed(&self.buf);
        self.req = .{
            .method = .POST,
            .target = "/",
            .path = "/",
            .query = "",
            .version = .@"HTTP/1.1",
            .head_bytes = "POST / HTTP/1.1\r\n\r\n",
            .content_type = opts.content_type,
            .content_length = opts.content_length,
            .transfer_encoding = .none,
            .body = opts.body,
        };
        self.ctx = .{
            .request = &self.req,
            .state = &self.state,
            .config = &self.cfg,
            .arena = a,
            .io = undefined,
        };
        self.res = Response.init(std.testing.allocator, http_protocol.Sink.testSink(&self.writer));
    }

    fn end(self: *CodecEnv) void {
        self.res.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    fn written(self: *const CodecEnv) []const u8 {
        return self.buf[0..self.writer.end];
    }
};

/// 空中间件管道：next 直达 handler；handler 写 "next ran" 供透传/成功路径检测。
fn codecNext() Next {
    return Next.root(&.{}, http_app.Handler.fromFn(struct {
        fn handle(_: *Context, res: *Response) !void {
            try res.text("next ran");
        }
    }.handle));
}

test "JsonBody: 无 Content-Type 透传，不碰 body 不塞 T" {
    var env: CodecEnv = .{};
    env.begin(.{ .content_type = null, .body = .{ .buffered = "{\"name\":\"x\",\"age\":1}" } });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try mw.process(&env.ctx, &env.res, codecNext());

    try std.testing.expect(std.mem.indexOf(u8, env.written(), "next ran") != null);
    try std.testing.expect(env.ctx.getUserData(TestUser) == null);
}

test "JsonBody: 非 JSON Content-Type 透传" {
    var env: CodecEnv = .{};
    env.begin(.{ .content_type = "application/x-www-form-urlencoded", .body = .{ .buffered = "name=x" } });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try mw.process(&env.ctx, &env.res, codecNext());

    try std.testing.expect(std.mem.indexOf(u8, env.written(), "next ran") != null);
    try std.testing.expect(env.ctx.getUserData(TestUser) == null);
}

test "JsonBody: body 为 .none 透传" {
    var env: CodecEnv = .{};
    env.begin(.{ .content_type = "application/json", .body = .none });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try mw.process(&env.ctx, &env.res, codecNext());

    try std.testing.expect(std.mem.indexOf(u8, env.written(), "next ran") != null);
    try std.testing.expect(env.ctx.getUserData(TestUser) == null);
}

test "JsonBody: 空 body 透传" {
    var env: CodecEnv = .{};
    env.begin(.{ .content_type = "application/json", .body = .{ .buffered = "" } });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try mw.process(&env.ctx, &env.res, codecNext());

    try std.testing.expect(std.mem.indexOf(u8, env.written(), "next ran") != null);
    try std.testing.expect(env.ctx.getUserData(TestUser) == null);
}

test "JsonBody: 合法 JSON 解析入 user_data 并透传到 handler" {
    var env: CodecEnv = .{};
    env.begin(.{
        .content_type = "application/json; charset=utf-8",
        .body = .{ .buffered = "{\"name\":\"alice\",\"age\":30}" },
    });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try mw.process(&env.ctx, &env.res, codecNext());

    const got = env.ctx.getUserData(TestUser).?;
    try std.testing.expectEqualStrings("alice", got.name);
    try std.testing.expectEqual(@as(u8, 30), got.age);
    try std.testing.expect(std.mem.indexOf(u8, env.written(), "next ran") != null);
}

test "JsonBody: 非法 JSON → failWith(AppError 400)，不直写响应" {
    var env: CodecEnv = .{};
    env.begin(.{ .content_type = "application/json", .body = .{ .buffered = "not json" } });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try std.testing.expectError(error.AppError, mw.process(&env.ctx, &env.res, codecNext()));

    const app_err = env.ctx.getUserData(AppError).?;
    try std.testing.expectEqual(std.http.Status.bad_request, app_err.status);
    try std.testing.expectEqualStrings("invalid JSON body", app_err.message);
    // 响应由 ErrorRenderer 渲染；本测试未挂它，中间件自身不应已写出任何响应
    try std.testing.expect(!env.res.sent);
    try std.testing.expectEqual(@as(usize, 0), env.writer.end);
}

test "JsonBody: 超限 streaming body → AppError(413) 且 keep_alive=false" {
    var env: CodecEnv = .{};
    // .streaming 载荷在 BodyTooLarge 检查前不会被解引用（readBodyInto 先判
    // content_length 再建 reader），故测试里可以用 undefined 指针。
    env.begin(.{
        .content_type = "application/json",
        .body = .{ .streaming = undefined },
        .content_length = 1000,
    });
    defer env.end();

    var mw = JsonBody(TestUser).init(10); // limit 10 字节 < content_length 1000
    try std.testing.expectError(error.AppError, mw.process(&env.ctx, &env.res, codecNext()));

    try std.testing.expect(!env.res.keep_alive);
    const app_err = env.ctx.getUserData(AppError).?;
    try std.testing.expectEqual(std.http.Status.payload_too_large, app_err.status);
    try std.testing.expectEqualStrings("request body too large", app_err.message);
}

test "JsonBody: OOM 向上传播，不被吞成 400" {
    // 第一次 arena 分配（parseJson 的 create(T)）就失败。
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    var env: CodecEnv = .{};
    env.begin(.{
        .child = failing.allocator(),
        .content_type = "application/json",
        .body = .{ .buffered = "{\"name\":\"a\",\"age\":1}" },
    });
    defer env.end();

    var mw = JsonBody(TestUser).init(1 << 20);
    try std.testing.expectError(error.OutOfMemory, mw.process(&env.ctx, &env.res, codecNext()));
    // 没有写 400，也没有塞 T
    try std.testing.expect(env.ctx.getUserData(TestUser) == null);
    try std.testing.expect(env.ctx.getUserData(AppError) == null);
    try std.testing.expectEqual(@as(usize, 0), env.writer.end);
}

test {
    std.testing.refAllDecls(@This());
}
