//! 组合语义测试(5.2 测试覆盖补全):
//! 跨中间件 user_data 传播 + 外层中间件错误改写。
//! 链顺序/缓冲改写已有用例覆盖(root.zig);这里补"多层中间件协同"盲区。
//!
//! 由 root.zig `test { _ = @import("combo_test.zig"); }` 挂进 http_testing 模块测试。

const std = @import("std");
const http = std.http;
const testing = std.testing;
const http_testing = @import("root.zig");

const Harness = http_testing.Harness;
const Context = http_testing.Context;
const Response = http_testing.Response;
const Handler = http_testing.Handler;
const Middleware = http_testing.Middleware;
const Next = http_testing.Next;

/// 放在命名空间层的通讯槽(同 root.zig IdSlot 的理由:@typeName 含父作用域)。
const CrossSlot = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,
    fn append(self: *CrossSlot, ch: u8) void {
        self.buf[self.len] = ch;
        self.len += 1;
    }
    fn view(self: *const CrossSlot) []const u8 {
        return self.buf[0..self.len];
    }
};

const SeederMw = struct {
    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: Next) !void {
        const slot = try ctx.arena.create(CrossSlot);
        slot.* = .{}; // create 返回未初始化内存，必须显式初始化（len=0）
        try ctx.setUserData(CrossSlot, slot);
        try next.call(ctx, res);
    }
};

/// 工厂:生成"进链追 pre、出链追 post"的中间件类型,验证外层先进后出。
fn TraceMw(comptime pre: u8, comptime post: u8) type {
    return struct {
        pub fn process(_: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            const slot = ctx.getUserData(CrossSlot) orelse return error.MissingSlot;
            slot.append(pre);
            try next.call(ctx, res);
            slot.append(post);
        }
    };
}

test "中间件组合:user_data 跨三层传播,进出链顺序可断言" {
    const h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/trace");

    var seeder: SeederMw = .{};
    var outer: TraceMw('O', 'o') = .{};
    var inner: TraceMw('I', 'i') = .{};

    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            const slot = ctx.getUserData(CrossSlot) orelse return error.MissingSlot;
            slot.append('H');
            try res.text(slot.view());
        }
    }.handle);

    try h.run(&.{
        Middleware.init(SeederMw, &seeder),
        Middleware.init(TraceMw('O', 'o'), &outer),
        Middleware.init(TraceMw('I', 'i'), &inner),
    }, handler);

    // handler 看到的链前缀:外层先进→内层→自己。
    try testing.expectEqualStrings("OIH", h.body());
    // chain finishes: full in/out sequence in the slot: outer first-in-last-out
    try testing.expectEqualStrings("OIHio", h.context().?.getUserData(CrossSlot).?.view());
}

const FailingMw = struct {
    pub fn process(_: *@This(), _: *Context, _: *Response, _: Next) !void {
        return error.UpstreamBroken;
    }
};

const RewriterMw = struct {
    pub fn process(_: *@This(), ctx: *Context, res: *Response, next: Next) !void {
        next.call(ctx, res) catch |err| switch (err) {
            error.UpstreamBroken => {
                _ = res.statusCode(.service_unavailable);
                try res.text("fallback");
            },
            else => |e| return e,
        };
    }
};

test "中间件组合:内层报错被外层改写为兜底响应,handler 不执行" {
    const h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.req(.GET, "/flaky");

    var rw: RewriterMw = .{};
    var fl: FailingMw = .{};

    const handler = Handler.fromFn(struct {
        fn handle(_: *Context, res: *Response) !void {
            try res.text("handler-ran");
        }
    }.handle);

    // 外层 Rewriter 吞掉 UpstreamBroken → run 不应返回错误。
    try h.run(&.{
        Middleware.init(RewriterMw, &rw),
        Middleware.init(FailingMw, &fl),
    }, handler);

    try testing.expectEqual(@as(u16, 503), h.statusCode());
    try testing.expectEqualStrings("fallback", h.body());
}
