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

    /// 两个中间件值是否指向同一个实例。
    /// `process` 由 comptime 的 T 决定（同 T 才同函数指针），`ptr` 是实例地址
    /// ——两者一起唯一确定一个中间件值；`destroy` 是 process 的派生物，不必比。
    fn same(a: Middleware, b: Middleware) bool {
        return a.ptr == b.ptr and a.process == b.process;
    }

    /// 释放一组中间件，跳过重复值；`prior` 里出现过的（已释放过）也算重复。
    ///
    /// `Middleware` 是值类型（ptr + 函数指针），`deinit` 调的是实例的
    /// `T.deinit()`，所以「同一个值 deinit 两次」= 实例被销毁两次 = double-free。
    /// `pipeline.add(Middleware.init(T, &x))` 两次就存下两条一模一样的记录，
    /// 逐条 deinit 必炸——与 router 的中间件双释放完全同构，解法也相同：按值去重。
    ///
    /// 两套管道（`DynPipeline` / `Pipeline(N)`）与 `Router` 都走这里：去重逻辑
    /// 只有一份，不复制（本项目已经因为三份 percent 解码器漂过一次）。
    /// 中间件数量是注册期的小常数，O(n²) 扫描只在 deinit 跑一次，不值得建索引。
    pub fn deinitAll(items: []const Middleware, prior: []const Middleware) void {
        for (items, 0..) |mw, i| {
            var dup = false;
            for (items[0..i]) |seen| {
                if (same(seen, mw)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) for (prior) |seen| {
                if (same(seen, mw)) {
                    dup = true;
                    break;
                }
            };
            if (!dup) mw.deinit();
        }
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

    /// 释放 ArrayList **以及**其中的中间件：管道是中间件实例的释放者，
    /// 与 `Pipeline(N).deinit` 同一套契约（修复前这里只放 ArrayList，
    /// 中间件一次都没被 deinit ——两套契约正好反过来）。
    pub fn deinit(self: *DynPipeline) void {
        Middleware.deinitAll(self.items.items, &.{});
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

        /// 释放管道持有的中间件，按值去重：`Middleware.init(T, &x)` 调两次
        /// 得到两个相等的值，逐项 deinit 就是 `T.deinit()` 两次（double-free）。
        /// 现有测试里 `add` 两次同一个 Track 没炸，只是因为那个 Track 没有
        /// deinit ——真换了带 deinit 的类型就会炸。
        pub fn deinit(self: *Self) void {
            Middleware.deinitAll(self.items[0..self.len], &.{});
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

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
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

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
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

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
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

    var state = @import("context.zig").RequestState{ .arena = arena.allocator() };
    defer state.deinit();
    const cfg = @import("context.zig").RequestConfig{};
    var req = @import("http_protocol").Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = "GET / HTTP/1.1\r\n\r\n",
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

// ── 中间件所有权回归：deinit 次数探针 ────────────────────────────────
//
// 直接用 std.testing.allocator 验证 double-free 是不行的：SafeAllocator 在
// free 里持锁 panic，而 0.17 的 test runner 是多线程的，其它测试线程再分配
// 会死锁在那把锁上 ——`zig build test` 表现为超时且零输出。所以内层用 arena
// 兜底，只统计 free 次数，把「释放了几次」变成可以断言的数字。

/// 只统计 free 次数的分配器，内层用 arena 兜底。
const FreeCounter = struct {
    inner: std.mem.Allocator,
    frees: usize = 0,

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocImpl, .resize = resizeImpl, .remap = remapImpl, .free = freeImpl } };
    }
};

/// 探针中间件：`deinit` 释放一块从 FreeCounter 拿的内存，于是
/// 「`T.deinit()` 被调了几次」=「free 了几次」，可以直接断言。
const ProbeMiddleware = struct {
    alloc: std.mem.Allocator,
    buf: []u8,

    pub fn init(a: std.mem.Allocator) !ProbeMiddleware {
        return .{ .alloc = a, .buf = try a.alloc(u8, 8) };
    }

    pub fn process(_: *ProbeMiddleware, ctx: *Context, res: *Response, next: Next) !void {
        return next.call(ctx, res);
    }

    pub fn deinit(self: *ProbeMiddleware) void {
        self.alloc.free(self.buf);
    }
};

const noopHandler = Handler.fromFn(struct {
    fn handle(_: *Context, _: *Response) !void {}
}.handle);

test "Pipeline(N).deinit: 同一中间件 add 两次只释放一次" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };
    var probe = try ProbeMiddleware.init(counter.allocator());

    var pipeline = Pipeline(2).init(noopHandler);
    try pipeline.add(Middleware.init(ProbeMiddleware, &probe));
    try pipeline.add(Middleware.init(ProbeMiddleware, &probe));
    // 修复前逐项 deinit → T.deinit() 两次 = double-free。这里不写 defer，
    // 就是要让 deinit 的结果直接被断言到。
    pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "DynPipeline.deinit: 中间件被释放一次（修复前一次都没有）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };
    var probe = try ProbeMiddleware.init(counter.allocator());

    var pipeline = DynPipeline.init(arena.allocator(), noopHandler);
    try pipeline.add(Middleware.init(ProbeMiddleware, &probe));
    // 修复前 DynPipeline.deinit 只放 ArrayList，中间件一次都没 deinit（泄漏）。
    pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "DynPipeline.deinit: 同一中间件 add 两次只释放一次" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };
    var probe = try ProbeMiddleware.init(counter.allocator());

    var pipeline = DynPipeline.init(arena.allocator(), noopHandler);
    try pipeline.add(Middleware.init(ProbeMiddleware, &probe));
    try pipeline.add(Middleware.init(ProbeMiddleware, &probe));
    pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 1), counter.frees);
}

test "Middleware.deinitAll: 同类型的不同实例各释放一次（去重不能按类型并）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter = FreeCounter{ .inner = arena.allocator() };
    var a = try ProbeMiddleware.init(counter.allocator());
    var b = try ProbeMiddleware.init(counter.allocator());

    var pipeline = Pipeline(2).init(noopHandler);
    try pipeline.add(Middleware.init(ProbeMiddleware, &a));
    try pipeline.add(Middleware.init(ProbeMiddleware, &b));
    pipeline.deinit();

    // 同 T 同 process 函数指针，但 ptr 不同 → 是两个值，各 deinit 一次。
    try std.testing.expectEqual(@as(usize, 2), counter.frees);
}

test {
    std.testing.refAllDecls(@This());
}
