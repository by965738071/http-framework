//! Handler — union(enum) 替代 vtable 3 语义（回应 bug.md §2）
//!
//! 原来的 Handler VTable 用一个 4 函数 vtable 承担 3 种生命周期语义
//!（纯函数 / 单例 / 请求级），`fromFn` 甚至用 sentinel 指针 hack。
//!
//! 现在用 `union(enum)`，`dispatch` 时 switch 命中分支，每个分支走
//! 自己的快路径：
//! - `.func`：零间接调用、零分配、无 sentinel hack
//! - `.singleton`：指针直接派发到 `T.handle`
//! - `.factory`：每请求 create/destroy
//!
//! `create/destroy` 对 `.func` 来说根本不存在——不再需要空操作函数。

const std = @import("std");
const context = @import("context.zig");
const response = @import("http_protocol").Response;
const Context = context.Context;
const Response = response;

pub const Handler = union(enum) {
    /// 纯函数处理器 — 零分配，编译期已知
    func: *const fn (*Context, *Response) anyerror!void,

    /// 单例处理器 — 指向全局稳定实例
    singleton: Singleton,

    /// 工厂处理器 — 每请求创建实例
    factory: Factory,

    pub const Singleton = struct {
        ptr: *anyopaque,
        call: *const fn (*anyopaque, *Context, *Response) anyerror!void,
    };

    pub const Factory = struct {
        ctx: *anyopaque,
        create: *const fn (*anyopaque) anyerror!*anyopaque,
        handle: *const fn (*anyopaque, *Context, *Response) anyerror!void,
        destroy: *const fn (*anyopaque, *anyopaque) void,
        deinit_ctx: *const fn (*anyopaque) void,
    };

    // ── 工厂函数 ──────────────────────────────────────────

    /// **纯函数处理器** — 零开销，无 sentinel hack
    pub fn fromFn(comptime func: *const fn (*Context, *Response) anyerror!void) Handler {
        return .{ .func = func };
    }

    /// **单例处理器** — ptr 指向全局稳定实例，T 有 handle 方法
    pub fn initSingleton(comptime T: type, ptr: *T) Handler {
        const callFn = struct {
            fn call(any: *anyopaque, ctx: *Context, res: *Response) anyerror!void {
                const self: *T = @ptrCast(@alignCast(any));
                return self.handle(ctx, res);
            }
        }.call;
        return .{
            .singleton = .{
                .ptr = @ptrCast(ptr),
                .call = callFn,
            },
        };
    }

    /// **请求级处理器** — 框架自动管理创建和销毁。
    /// T 必须有 `init(allocator) !*T` / `handle(ctx, res) !void` / `deinit() void`
    pub fn initFactory(comptime T: type, allocator: std.mem.Allocator) !Handler {
        const FactoryCtx = struct { alloc: std.mem.Allocator };
        const ctx = try allocator.create(FactoryCtx);
        ctx.* = .{ .alloc = allocator };

        const createFn = struct {
            fn create(any: *anyopaque) anyerror!*anyopaque {
                const c: *FactoryCtx = @ptrCast(@alignCast(any));
                return @ptrCast(try T.init(c.alloc));
            }
        }.create;
        const handleFn = struct {
            fn call(any: *anyopaque, ctx2: *Context, res: *Response) anyerror!void {
                const self: *T = @ptrCast(@alignCast(any));
                return self.handle(ctx2, res);
            }
        }.call;
        const destroyFn = struct {
            fn destroy(any: *anyopaque, instance: *anyopaque) void {
                const c: *FactoryCtx = @ptrCast(@alignCast(any));
                const self: *T = @ptrCast(@alignCast(instance));
                self.deinit();
                c.alloc.destroy(self);
            }
        }.destroy;
        const deinitCtxFn = struct {
            fn deinitCtx(any: *anyopaque) void {
                const c: *FactoryCtx = @ptrCast(@alignCast(any));
                c.alloc.destroy(c);
            }
        }.deinitCtx;

        return .{
            .factory = .{
                .ctx = @ptrCast(ctx),
                .create = createFn,
                .handle = handleFn,
                .destroy = destroyFn,
                .deinit_ctx = deinitCtxFn,
            },
        };
    }

    // ── 派发 ──────────────────────────────────────────────

    /// 执行 handler。对 factory 模式，create/destroy 在一次调用内配对。
    pub fn dispatch(self: Handler, ctx: *Context, res: *Response) !void {
        switch (self) {
            .func => |f| return f(ctx, res),
            .singleton => |s| return s.call(s.ptr, ctx, res),
            .factory => |f| {
                const inst = try f.create(f.ctx);
                defer f.destroy(f.ctx, inst);
                return f.handle(inst, ctx, res);
            },
        }
    }

    /// 释放注册时分配的上下文。func/singleton 为 no-op。
    pub fn deinit(self: Handler) void {
        switch (self) {
            .func, .singleton => {},
            .factory => |f| f.deinit_ctx(f.ctx),
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "Handler.fromFn dispatches to pure function (zero alloc)" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    var state = @import("context.zig").RequestState{};
    defer state.deinit(std.testing.allocator);
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
        .arena = std.testing.allocator,
        .io = undefined,
    };

    const handler = Handler.fromFn(struct {
        fn handle(c: *Context, r: *Response) !void {
            _ = c;
            try r.text("ok");
        }
    }.handle);

    try handler.dispatch(&ctx, &res);
    handler.deinit(); // no-op for func
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "ok") != null);
}

test "Handler.initSingleton dispatches to instance handle method" {
    const T = struct {
        counter: u32 = 0,
        pub fn handle(self: *@This(), ctx: *Context, res: *Response) !void {
            _ = ctx;
            self.counter += 1;
            try res.text("singleton");
        }
    };
    var instance = T{};

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    var state = @import("context.zig").RequestState{};
    defer state.deinit(std.testing.allocator);
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
        .arena = std.testing.allocator,
        .io = undefined,
    };

    const handler = Handler.initSingleton(T, &instance);
    try handler.dispatch(&ctx, &res);
    handler.deinit();

    try std.testing.expectEqual(@as(u32, 1), instance.counter);
}

test "Handler.initFactory creates and destroys per request" {
    const T = struct {
        id: u32,
        pub fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .id = 999 };
            return self;
        }
        pub fn handle(self: *@This(), ctx: *Context, res: *Response) !void {
            _ = ctx;
            self.id = 42;
            try res.text("factory");
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const handler = try Handler.initFactory(T, std.testing.allocator);
    defer handler.deinit();

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var res = Response.init(std.testing.allocator, @import("http_protocol").Sink.testSink(&writer));
    defer res.deinit();

    var state = @import("context.zig").RequestState{};
    defer state.deinit(std.testing.allocator);
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
        .arena = std.testing.allocator,
        .io = undefined,
    };

    try handler.dispatch(&ctx, &res);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..writer.end], "factory") != null);
}
