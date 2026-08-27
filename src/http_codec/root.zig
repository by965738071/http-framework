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

/// 从字节切片解析 JSON，返回 arena 分配的 *T。
///
/// 用 arena allocator 时不调 parsed.deinit()——arena reset 回收全部。
/// 返回的 *T 以及其中所有切片都由 allocator 管理。
pub fn parseJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !*T {
    // 用 parseFromSliceLeaky 明确 arena 契约：所有内部分配直接落在 allocator
    // 上，不产生需要 deinit 的 Parsed(T) 句柄，避免传非 arena 分配器时泄漏。
    // 调用方应传 arena（如 ctx.arena），请求结束时统一回收。
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
                    // 放大连接占用（修复低优先：codec 413 后 res.keep_alive = false）。
                    res.keep_alive = false;
                    _ = res.statusCode(.payload_too_large);
                    try res.text("request body too large");
                    return;
                }
                return err;
            };
            if (body.len == 0) return next.call(ctx, res);

            const parsed = parseJson(T, ctx.arena, body) catch |err| {
                // 修复低优先：非解析错误（如 OOM）向上传播，不能吞成 400。
                if (err == error.OutOfMemory) return error.OutOfMemory;
                _ = res.statusCode(.bad_request);
                try res.text("invalid JSON body");
                return;
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

test {
    std.testing.refAllDecls(@This());
}
