//! 中间件 — 真正的 next 回调管道（回应 bug.md §3）
//!
//! 原来的 Middleware 用 `NextAction` 枚举（.next/.respond/.err）控制
//! 流程，中间件无法在 handler **之后**执行代码。计时、响应压缩、
//! 错误兜底全部做不了。`blocked_status` 是 side-channel 补丁。
//!
//! 现在用经典的 `fn process(ctx, res, next) !void` 模型：
//! 中间件自己决定调不调 next、在什么时候调。
//!
//! `Next` 是一个纯值类型，携带中间件切片 + handler + 索引。
//! 在栈上分配，通过 `.call(ctx, res)` 调用下一层。**不使用 threadlocal**
//! （回应 fix.md 架构缺陷 #1：threadlocal 在重试/嵌套 dispatch /
//! 异步 IO 下会串）。
//!
//! `DynPipeline`（运行时 ArrayList）和 `Pipeline(comptime N)`（栈数组）
//! 都只需从各自的存储产出 `Next`，共用同一套 `call` 逻辑。
//! `Pipeline(N)` 零堆分配，适用于中间件栈在编译期已知的场景
//! （回应 fix.md §四.8：comptime Pipeline 未实现）。
//!
//! ```zig
//! fn process(self, ctx, res, next) !void {
//!     const start = std.Io.Timestamp.now(ctx.io, .monotonic).nanoseconds;
//!     try next.call(ctx, res);     // 先执行 handler
//!     const elapsed = std.Io.Timestamp.now(ctx.io, .monotonic).nanoseconds - start;
//!     _ = res.header("X-Duration-ns", ...) catch {};
//! }
//! ```

const std = @import("std");
const context = @import("context.zig");
const response = @import("http_protocol").Response;
const handler_mod = @import("handler.zig");
const Context = context.Context;
const Response = response;
const Handler = handler_mod.Handler;

/// "调用下一个节点"的上下文 — 纯值类型，栈上分配。
/// 携带中间件切片 + handler + 下一层索引。
/// 中间件通过 `next.call(ctx, res)` 调用下一层。
pub const Next = struct {
    items: []const Middleware,
    handler: Handler,
    idx: usize,

    /// 调用第 idx 层中间件（或 handler，如果 idx 超出范围）。
    pub fn call(self: Next, ctx: *Context, res: *Response) anyerror!void {
        if (self.idx >= self.items.len) {
            return self.handler.dispatch(ctx, res);
        }
        const mw = self.items[self.idx];
        // 下一层 Next——同样在栈上分配，可安全多次调用、重试、嵌套 dispatch。
        const next: Next = .{
            .items = self.items,
            .handler = self.handler,
            .idx = self.idx + 1,
        };
        return mw.process(mw.ptr, ctx, res, next);
    }

    /// 从中间件切片 + handler 构建起始 Next（idx=0）。
    pub fn root(items: []const Middleware, handler: Handler) Next {
        return .{ .items = items, .handler = handler, .idx = 0 };
    }
};

/// 中间件 — 持有实例指针 + process 函数。
pub const Middleware = struct {
    ptr: *anyopaque,
    process: *const fn (*anyopaque, *Context, *Response, next: Next) anyerror!void,
    destroy: ?*const fn (*anyopaque) void = null,

    /// 从实现了 `process(ctx, res, next)` 方法的类型创建中间件。
    pub fn init(comptime T: type, ptr: *T) Middleware {
        const processFn = struct {
            fn call(any: *anyopaque, ctx: *Context, res: *Response, next: Next) anyerror!void {
                const self: *T = @ptrCast(@alignCast(any));
                return self.process(ctx, res, next);
            }
        }.call;
        const destroyFn = if (@hasDecl(T, "deinit")) struct {
            fn call(any: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(any));
                self.deinit();
            }
        }.call else null;
        return .{
            .ptr = @ptrCast(ptr),
            .process = processFn,
            .destroy = destroyFn,
        };
    }

    pub fn deinit(self: Middleware) void {
        if (self.destroy) |d| d(self.ptr);
    }
};

/// 动态长度管道 — 用 ArrayList 存储，运行时组装。
/// 适用于中间件数量在运行时才能确定的场景（如 `router.use()` 动态添加）。
/// 如果中间件栈在编译期已知，优先用 `Pipeline(comptime N)`（零堆分配）。
pub const DynPipeline = struct {
    items: std.ArrayList(Middleware) = .empty,
    handler: Handler,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, handler: Handler) DynPipeline {
        return .{ .arena = arena, .handler = handler };
    }

    pub fn add(self: *DynPipeline, mw: Middleware) !void {
        try self.items.append(self.arena, mw);
    }

    /// 执行管道：从第 0 层开始，每层调 next 时进入下一层，
    /// 最后一层的 next 直接调 handler。
    pub fn dispatch(self: *DynPipeline, ctx: *Context, res: *Response) !void {
        const next = Next.root(self.items.items, self.handler);
        return next.call(ctx, res);
    }

    pub fn deinit(self: *DynPipeline) void {
        self.items.deinit(self.arena);
    }
};

/// 编译期固定长度管道 — 栈上数组存储，零堆分配（fix.md §四.8）。
///
/// 适用于中间件栈在编译期已知的场景。与 `DynPipeline` 共用 `Next` 逻辑，
/// 但 `items` 是 `[N]Middleware` 栈数组而非 `ArrayList`。
///
/// ```zig
/// var pipeline = Pipeline(3).init(handler);
/// pipeline.set(0, Middleware.init(TimingMiddleware, &timing));
/// pipeline.set(1, Middleware.init(RequestIdMiddleware, &rid));
/// pipeline.set(2, Middleware.init(ErrorRenderer, &err));
/// try pipeline.dispatch(&ctx, &res);
/// ```
pub fn Pipeline(comptime N: usize) type {
    return struct {
        const Self = @This();

        items: [N]Middleware = undefined,
        len: usize = 0,
        handler: Handler,

        pub fn init(handler: Handler) Self {
            return .{ .handler = handler };
        }

        /// 按顺序添加中间件。超出 N 时返回 error.PipelineFull。
        pub fn add(self: *Self, mw: Middleware) !void {
            if (self.len >= N) return error.PipelineFull;
            self.items[self.len] = mw;
            self.len += 1;
        }

        /// 直接设置指定位置的中间件（不检查顺序）。
        pub fn set(self: *Self, idx: usize, mw: Middleware) void {
            self.items[idx] = mw;
            if (idx + 1 > self.len) self.len = idx + 1;
        }

        pub fn dispatch(self: *Self, ctx: *Context, res: *Response) !void {
            const next = Next.root(self.items[0..self.len], self.handler);
            return next.call(ctx, res);
        }

        pub fn deinit(self: *Self) void {
            for (self.items[0..self.len]) |mw| mw.deinit();
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "Middleware with next can run code after handler" {
    const Track = struct {
        order: *std.ArrayList(u8),

        pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            self.order.append(ctx.arena, 'A') catch {};
            try next.call(ctx, res);
            self.order.append(ctx.arena, 'B') catch {};
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var order = std.ArrayList(u8).empty;
    var track = Track{ .order = &order };

    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            _ = ctx;
            _ = res;
        }
    }.handle);

    var pipeline = DynPipeline.init(arena.allocator(), handler);
    defer pipeline.deinit();
    try pipeline.add(Middleware.init(Track, &track));

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    try pipeline.dispatch(&ctx, &res);

    // A = before, handler runs, B = after
    try std.testing.expect(order.items.len >= 2);
    try std.testing.expectEqual(@as(u8, 'A'), order.items[0]);
    try std.testing.expectEqual(@as(u8, 'B'), order.items[1]);
}

test "Middleware can short-circuit by not calling next" {
    const Blocker = struct {
        pub fn process(_: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            _ = next;
            _ = ctx;
            try res.text("blocked");
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var blocker = Blocker{};
    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            _ = ctx;
            try res.text("handler ran");
        }
    }.handle);

    var pipeline = DynPipeline.init(arena.allocator(), handler);
    defer pipeline.deinit();
    try pipeline.add(Middleware.init(Blocker, &blocker));

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    try pipeline.dispatch(&ctx, &res);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "handler ran") == null);
}

// ── Pipeline(comptime N) 测试（fix.md §四.8）────────────────────────────

test "Pipeline(N): comptime 长度管道，栈数组，零堆分配" {
    const Track = struct {
        order: *std.ArrayList(u8),

        pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            self.order.append(ctx.arena, 'A') catch {};
            try next.call(ctx, res);
            self.order.append(ctx.arena, 'B') catch {};
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var order = std.ArrayList(u8).empty;
    var track = Track{ .order = &order };

    const handler = Handler.fromFn(struct {
        fn handle(ctx: *Context, res: *Response) !void {
            _ = ctx;
            _ = res;
        }
    }.handle);

    // 编译期已知 2 层中间件 → Pipeline(2)，栈数组，无 ArrayList 分配
    var pipeline = Pipeline(2).init(handler);
    try pipeline.add(Middleware.init(Track, &track));
    try pipeline.add(Middleware.init(Track, &track));

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    try pipeline.dispatch(&ctx, &res);

    // 两层中间件，每层 A...B：A A B B
    try std.testing.expectEqual(@as(usize, 4), order.items.len);
    try std.testing.expectEqual(@as(u8, 'A'), order.items[0]);
    try std.testing.expectEqual(@as(u8, 'A'), order.items[1]);
    try std.testing.expectEqual(@as(u8, 'B'), order.items[2]);
    try std.testing.expectEqual(@as(u8, 'B'), order.items[3]);
}

test "Pipeline(N): add 超出容量返回 PipelineFull" {
    const Noop = struct {
        pub fn process(_: *@This(), _: *Context, _: *Response, next: Next) !void {
            _ = next;
        }
    };

    const handler = Handler.fromFn(struct {
        fn handle(_: *Context, _: *Response) !void {}
    }.handle);

    var noop1 = Noop{};
    var noop2 = Noop{};
    var pipeline = Pipeline(1).init(handler);
    try pipeline.add(Middleware.init(Noop, &noop1));

    // 容量 1，第二个 add 应该失败
    const result = pipeline.add(Middleware.init(Noop, &noop2));
    try std.testing.expectError(error.PipelineFull, result);
}

test "Pipeline(N): set 直接指定位置" {
    const Tag = struct {
        tag: u8,
        pub fn process(self: *@This(), ctx: *Context, res: *Response, next: Next) !void {
            _ = self;
            try next.call(ctx, res);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const handler = Handler.fromFn(struct {
        fn handle(_: *Context, _: *Response) !void {}
    }.handle);

    var t0 = Tag{ .tag = 0 };
    var t1 = Tag{ .tag = 1 };

    var pipeline = Pipeline(2).init(handler);
    pipeline.set(0, Middleware.init(Tag, &t0));
    pipeline.set(1, Middleware.init(Tag, &t1));

    // set 超出当前 len 应更新 len
    try std.testing.expectEqual(@as(usize, 2), pipeline.len);
}

test "Pipeline(0): 无中间件直接调 handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const handler = Handler.fromFn(struct {
        fn handle(_: *Context, res: *Response) !void {
            try res.text("ok");
        }
    }.handle);

    var pipeline = Pipeline(0).init(handler);

    var state = @import("context.zig").RequestState{};
    defer state.deinit(arena.allocator());
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    var ctx = Context{
        .request = &req,
        .state = &state,
        .config = &cfg,
        .arena = arena.allocator(),
        .io = undefined,
    };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    try pipeline.dispatch(&ctx, &res);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "ok") != null);
}

test {
    std.testing.refAllDecls(@This());
}
