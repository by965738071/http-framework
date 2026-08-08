//! 处理器（Handler）接口
//!
//! 使用 VTable 多态模式，支持三种处理器生命周期模式：
//!
//! | 模式 | 工厂函数 | create | destroy | 适用场景 |
//! |------|----------|--------|---------|----------|
//! | **纯函数** | `fromFn` | 空操作 | 空操作 | 无状态的普通函数 |
//! | **单例** | `init(T, ptr)` | 返回自身 | **空操作** | 全局共享的处理器 |
//! | **请求级** | `initPerRequest(T, alloc)` | 分配新实例 | deinit + destroy | 每次请求独立状态 |
//!
//! # 生命周期
//!
//! 请求级模式（`initPerRequest`）：
//! ```text
//! router.dispatch:
//!   create(ctx_ptr) → T.init(alloc) → 返回 *T
//!   handle(instance, ctx, res)
//!   destroy(ctx_ptr, instance):
//!     T.deinit(instance)
//!     alloc.destroy(instance)
//! ```
//!
//! # ⚠️ deinit 不需要调 allocator.destroy(self)
//!
//! VTable destroy 会统一处理 `allocator.destroy(instance)`。
//! `deinit` 只负责释放实例内部持有的资源即可：
//!
//! ```zig
//! pub fn deinit(self: *Self) void {
//!     self.allocator.free(self.some_field); // ✅ 释放内部资源
//!     // ❌ 不需要 allocator.destroy(self) — 框架自动调用
//! }
//! ```

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

const Handler = @This();

/// Handler 持有的不透明指针（指向 Context 或实例本身）
ptr: *anyopaque,

/// 虚函数表
vtable: *const VTable,

const VTable = struct {
    /// 创建处理器实例。
    /// `ctx` = `Handler.ptr`，返回的指针会传给 `handle` 和 `destroy`。
    create: *const fn (ctx: *anyopaque) anyerror!*anyopaque,

    /// 处理请求。
    /// `instance` = `create` 的返回值。
    handle: *const fn (instance: *anyopaque, *RequestContext, *Response) anyerror!void,

    /// 销毁处理器实例。
    /// `ctx` = `Handler.ptr`（可从中获取分配器）。
    /// `instance` = `create` 的返回值。
    destroy: *const fn (ctx: *anyopaque, instance: *anyopaque) void,

    /// 释放注册时创建的上下文（`Handler.ptr`）。
    /// 单例/纯函数模式为空操作 — 指针归调用方所有；
    /// 请求级模式释放 `initPerRequest(With)` 分配的一次性 Context。
    deinit_context: *const fn (ctx: *anyopaque) void,
};

// ===========================================================================
// 工厂函数
// ===========================================================================

/// **纯函数处理器** — create/destroy 均为空操作，零开销。
pub fn fromFn(comptime func: *const fn (*RequestContext, *Response) anyerror!void) Handler {
    const Placeholder = struct {
        pub const instance: u8 = 0;
    };

    return .{
        .ptr = @ptrCast(@constCast(&Placeholder.instance)),
        .vtable = &.{
            .create = struct {
                fn create(ctx: *anyopaque) anyerror!*anyopaque {
                    return ctx;
                }
            }.create,
            .handle = struct {
                fn call(_: *anyopaque, c: *RequestContext, r: *Response) anyerror!void {
                    return func(c, r);
                }
            }.call,
            .destroy = struct {
                fn destroy(_: *anyopaque, _: *anyopaque) void {}
            }.destroy,
            .deinit_context = struct {
                fn deinit_context(_: *anyopaque) void {}
            }.deinit_context,
        },
    };
}

/// **单例处理器** — destroy 为空操作，由调用者管理生命周期。
///
/// `ptr` 指向一个全局稳定的实例。每次请求 `create` 返回同一个指针。
pub fn init(comptime T: type, ptr: *T) Handler {
    return .{
        .ptr = @ptrCast(ptr),
        .vtable = &.{
            .create = struct {
                fn create(any: *anyopaque) anyerror!*anyopaque {
                    return any;
                }
            }.create,
            .handle = struct {
                fn call(any: *anyopaque, req: *RequestContext, res: *Response) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(any));
                    return self.handle(req, res);
                }
            }.call,
            .destroy = struct {
                fn destroy(_: *anyopaque, _: *anyopaque) void {}
            }.destroy,
            .deinit_context = struct {
                // 单例：ptr 归调用方所有，释放由调用方负责
                fn deinit_context(_: *anyopaque) void {}
            }.deinit_context,
        },
    };
}

// ===========================================================================
// 请求级生命周期
// ===========================================================================

/// **请求级处理器** — 框架自动管理创建和销毁。
///
/// 每次请求流程：
/// 1. `create` → 调 `T.init(allocator)` 分配新实例
/// 2. `handle` → 调 `instance.handle(ctx, res)`
/// 3. `destroy` → 从 `ctx` 中取出 `allocator`，调 `deinit()` + `alloc.destroy(instance)`
///
/// # 要求类型 T
///
/// - `pub fn init(allocator: std.mem.Allocator) !*T`
/// - `pub fn handle(self: *T, ctx: *RequestContext, res: *Response) !void`
/// - `pub fn deinit(self: *T) void`（释放内部资源，**不需要**调 destroy）
///
/// # 内存分配
///
/// | 阶段 | 分配次数 |
/// |------|---------|
/// | 路由注册时 | 1 次 `alloc.create(Context)` |
/// | 每次请求 create | 1 次 `T.init(alloc)` |
/// | 每次请求 destroy | 1 次 `alloc.destroy(T)` |
///
/// 路由注册时的 Context 分配是**一次性的**，后续请求只涉及 `T` 的 create/destroy。
///
/// # 使用示例
///
/// ```zig
/// try router.route(.GET, "/", Handler.initPerRequest(MyHandler, allocator));
/// ```
pub fn initPerRequest(comptime T: type, allocator: std.mem.Allocator) !Handler {
    // Context 在路由注册时分配一次，后续所有请求共享。
    // 它持有 allocator，供 destroy 阶段释放 T 实例。
    const Context = struct {
        alloc: std.mem.Allocator,
    };

    const ctx = try allocator.create(Context);
    ctx.* = .{ .alloc = allocator };

    return .{
        .ptr = @ptrCast(ctx),
        .vtable = &.{
            .create = struct {
                fn create(any: *anyopaque) anyerror!*anyopaque {
                    const c: *Context = @ptrCast(@alignCast(any));
                    return @ptrCast(try T.init(c.alloc));
                }
            }.create,
            .handle = struct {
                fn call(any: *anyopaque, req: *RequestContext, res: *Response) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(any));
                    return self.handle(req, res);
                }
            }.call,
            .destroy = struct {
                fn destroy(any: *anyopaque, instance: *anyopaque) void {
                    const c: *Context = @ptrCast(@alignCast(any));
                    const self: *T = @ptrCast(@alignCast(instance));
                    self.deinit();
                    c.alloc.destroy(self);
                }
            }.destroy,
            .deinit_context = struct {
                fn deinit_context(any: *anyopaque) void {
                    const c: *Context = @ptrCast(@alignCast(any));
                    c.alloc.destroy(c);
                }
            }.deinit_context,
        },
    };
}

/// **请求级处理器（带配置参数）** — 框架自动管理创建和销毁。
///
/// 与 `initPerRequest` 相同，但 `T.init` 可以接收额外的配置参数。
///
/// # 内存分配
///
/// Context 中除了 allocator 还存储了 `args`（按值拷贝），
/// 在路由注册时一次性分配，后续请求不再产生额外分配。
///
/// # 要求类型 T
///
/// - `pub fn init(allocator: std.mem.Allocator, args: anytype) !*T`
/// - args 是注册时传入的结构体，见示例
///
/// # 使用示例
///
/// ```zig
/// try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
///     UserHandler, allocator, .{ .default_name = "John Doe" },
/// ));
/// ```
pub fn initPerRequestWith(
    comptime T: type,
    allocator: std.mem.Allocator,
    args: anytype,
) !Handler {
    const Args = @TypeOf(args);
    const Context = struct {
        alloc: std.mem.Allocator,
        args: Args,
    };

    const ctx = try allocator.create(Context);
    ctx.* = .{ .alloc = allocator, .args = args };

    return .{
        .ptr = @ptrCast(ctx),
        .vtable = &.{
            .create = struct {
                fn create(any: *anyopaque) anyerror!*anyopaque {
                    const c: *Context = @ptrCast(@alignCast(any));
                    return @ptrCast(try T.init(c.alloc, c.args));
                }
            }.create,
            .handle = struct {
                fn call(any: *anyopaque, req: *RequestContext, res: *Response) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(any));
                    return self.handle(req, res);
                }
            }.call,
            .destroy = struct {
                fn destroy(any: *anyopaque, instance: *anyopaque) void {
                    const c: *Context = @ptrCast(@alignCast(any));
                    const self: *T = @ptrCast(@alignCast(instance));
                    self.deinit();
                    c.alloc.destroy(self);
                }
            }.destroy,
            .deinit_context = struct {
                fn deinit_context(any: *anyopaque) void {
                    const c: *Context = @ptrCast(@alignCast(any));
                    c.alloc.destroy(c);
                }
            }.deinit_context,
        },
    };
}

// ===========================================================================
// 注册上下文清理
// ===========================================================================

/// 释放注册时分配的上下文（`Handler.ptr`）。
///
/// 单例/纯函数模式为空操作 — 指针归调用方所有；
/// 请求级模式释放 `initPerRequest(With)` 一次性分配的 Context。
/// `Router.deinit()` 会自动对每条路由调用本方法。
pub fn deinit(self: *const Handler) void {
    self.vtable.deinit_context(self.ptr);
}

// ===========================================================================
// 测试
// ===========================================================================

/// 测试用计数器（文件级变量，供 test 块内的 struct 函数访问）
var handler_test_call_count: u32 = 0;

test "Handler.fromFn - pure function can be called" {
    const Fn = struct {
        fn handle(req: *RequestContext, res: *Response) anyerror!void {
            _ = req;
            _ = res;
            handler_test_call_count += 1;
        }
    };

    handler_test_call_count = 0;
    const handler = Handler.fromFn(Fn.handle);

    // create 应返回 handler.ptr 自身（零开销，无分配）
    const instance = try handler.vtable.create(handler.ptr);
    try std.testing.expectEqual(handler.ptr, instance);

    // handle 应调用纯函数
    // 安全说明：0x10 是一个从不被解引用的标记指针 — 该处理函数忽略参数
    // 用于测试 VTable 分派逻辑，而非实际的 Request／Response 操作
    const req: *RequestContext = @ptrFromInt(0x10);
    const res: *Response = @ptrFromInt(0x10);
    try handler.vtable.handle(instance, req, res);
    try std.testing.expectEqual(@as(u32, 1), handler_test_call_count);

    // destroy 为空操作（不应崩溃）
    handler.vtable.destroy(handler.ptr, instance);
}

test "Handler.init - singleton returns itself" {
    const Singleton = struct {
        handle_called: bool = false,

        pub fn handle(self: *@This(), req: *RequestContext, res: *Response) !void {
            _ = req;
            _ = res;
            self.handle_called = true;
        }
    };

    var singleton = Singleton{};
    const handler = Handler.init(Singleton, &singleton);

    // create 应返回相同的指针（单例模式）
    const instance = try handler.vtable.create(handler.ptr);
    try std.testing.expectEqual(handler.ptr, instance);

    // 验证返回指针就是原始 singleton 的地址
    const typed: *Singleton = @ptrCast(@alignCast(instance));
    try std.testing.expectEqual(&singleton, typed);

    // handle 应调用 singleton.handle
    // 安全说明：标记指针（0x10）从不被解引用 — 该处理函数忽略参数
    const req: *RequestContext = @ptrFromInt(0x10);
    const res: *Response = @ptrFromInt(0x10);
    try handler.vtable.handle(instance, req, res);
    try std.testing.expect(singleton.handle_called);

    // destroy 为空操作（单例生命周期由调用者管理）
    handler.vtable.destroy(handler.ptr, instance);
}

test "Handler.initPerRequest - new instance per request and deinit called" {
    const allocator = std.testing.allocator;

    const PerRequest = struct {
        id: u32,

        pub fn init(alloc: std.mem.Allocator) !*@This() {
            const self = try alloc.create(@This());
            self.* = .{ .id = next_id };
            next_id += 1;
            return self;
        }

        pub fn handle(self: *@This(), req: *RequestContext, res: *Response) !void {
            _ = req;
            _ = res;
            last_handle_id = self.id;
        }

        pub fn deinit(self: *@This()) void {
            deinit_called = true;
            deinit_id = self.id;
        }

        var next_id: u32 = 0;
        var last_handle_id: u32 = 999;
        var deinit_called: bool = false;
        var deinit_id: u32 = 999;
    };

    // 重置全局状态
    PerRequest.next_id = 0;
    PerRequest.last_handle_id = 999;
    PerRequest.deinit_called = false;
    PerRequest.deinit_id = 999;

    const handler = try Handler.initPerRequest(PerRequest, allocator);
    defer handler.deinit();

    // 第一次请求 — 应创建新实例 id=0
    const inst1 = try handler.vtable.create(handler.ptr);
    const typed1: *PerRequest = @ptrCast(@alignCast(inst1));
    try std.testing.expectEqual(@as(u32, 0), typed1.id);

    try handler.vtable.handle(inst1, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expectEqual(@as(u32, 0), PerRequest.last_handle_id);

    // 第二次请求 — 应创建新实例 id=1（不同于第一次）
    const inst2 = try handler.vtable.create(handler.ptr);
    const typed2: *PerRequest = @ptrCast(@alignCast(inst2));
    try std.testing.expectEqual(@as(u32, 1), typed2.id);
    try std.testing.expect(typed1 != typed2);

    try handler.vtable.handle(inst2, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expectEqual(@as(u32, 1), PerRequest.last_handle_id);

    // 销毁第一个实例 — 应调用 deinit
    handler.vtable.destroy(handler.ptr, inst1);
    try std.testing.expect(PerRequest.deinit_called);
    try std.testing.expectEqual(@as(u32, 0), PerRequest.deinit_id);

    // 销毁第二个实例
    PerRequest.deinit_called = false;
    PerRequest.deinit_id = 999;
    handler.vtable.destroy(handler.ptr, inst2);
    try std.testing.expect(PerRequest.deinit_called);
    try std.testing.expectEqual(@as(u32, 1), PerRequest.deinit_id);
}

test "Handler.init - creates from struct with handle method" {
    const T = struct {
        handled: bool = false,

        pub fn handle(self: *@This(), req: *RequestContext, res: *Response) !void {
            _ = req;
            _ = res;
            self.handled = true;
        }
    };

    var t = T{};
    const handler = Handler.init(T, &t);

    const instance = try handler.vtable.create(handler.ptr);
    try handler.vtable.handle(instance, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expect(t.handled);

    handler.vtable.destroy(handler.ptr, instance);
}

test "Handler vtable dispatches to correct function" {
    const T = struct {
        pub fn handle(self: *@This(), req: *RequestContext, res: *Response) !void {
            _ = self;
            _ = req;
            _ = res;
            handler_test_call_count += 1;
        }
    };

    handler_test_call_count = 0;
    var t = T{};
    const handler = Handler.init(T, &t);

    const instance = try handler.vtable.create(handler.ptr);
    try std.testing.expectEqual(handler.ptr, instance);

    try handler.vtable.handle(instance, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expectEqual(@as(u32, 1), handler_test_call_count);

    handler.vtable.destroy(handler.ptr, instance);
}

test "Handler - error propagation from handle" {
    const T = struct {
        pub fn handle(_: *@This(), _: *RequestContext, _: *Response) !void {
            return error.HandlerTestError;
        }
    };

    var t = T{};
    const handler = Handler.init(T, &t);

    const instance = try handler.vtable.create(handler.ptr);
    errdefer handler.vtable.destroy(handler.ptr, instance);

    try std.testing.expectError(error.HandlerTestError, handler.vtable.handle(instance, @ptrFromInt(0x10), @ptrFromInt(0x10)));

    handler.vtable.destroy(handler.ptr, instance);
}

test "Handler.initPerRequestWith - args passed through and deinit called" {
    const allocator = std.testing.allocator;

    const TestArgs = struct {
        name: []const u8,
        value: u32,
    };

    const PerRequestWith = struct {
        name: []const u8,
        value: u32,

        pub fn init(alloc: std.mem.Allocator, args: TestArgs) !*@This() {
            const self = try alloc.create(@This());
            self.* = .{ .name = args.name, .value = args.value };
            return self;
        }

        pub fn handle(self: *@This(), req: *RequestContext, res: *Response) !void {
            _ = req;
            _ = res;
            last_name = self.name;
            last_value = self.value;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            deinit_called = true;
        }

        var last_name: []const u8 = "";
        var last_value: u32 = 0;
        var deinit_called: bool = false;
    };

    // 重置全局状态
    PerRequestWith.last_name = "";
    PerRequestWith.last_value = 0;
    PerRequestWith.deinit_called = false;

    const args = TestArgs{ .name = "test-handler", .value = 42 };
    const handler = try Handler.initPerRequestWith(PerRequestWith, allocator, args);
    defer handler.deinit();

    // 第一次请求 — 应创建新实例并正确保存 args
    const inst1 = try handler.vtable.create(handler.ptr);
    const typed1: *PerRequestWith = @ptrCast(@alignCast(inst1));
    try std.testing.expectEqualStrings("test-handler", typed1.name);
    try std.testing.expectEqual(@as(u32, 42), typed1.value);

    try handler.vtable.handle(inst1, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expectEqualStrings("test-handler", PerRequestWith.last_name);
    try std.testing.expectEqual(@as(u32, 42), PerRequestWith.last_value);

    // 第二次请求 — 应创建新实例，且 args 仍然正确
    const inst2 = try handler.vtable.create(handler.ptr);
    const typed2: *PerRequestWith = @ptrCast(@alignCast(inst2));
    try std.testing.expectEqualStrings("test-handler", typed2.name);
    try std.testing.expectEqual(@as(u32, 42), typed2.value);
    try std.testing.expect(typed1 != typed2);

    try handler.vtable.handle(inst2, @ptrFromInt(0x10), @ptrFromInt(0x10));
    try std.testing.expectEqualStrings("test-handler", PerRequestWith.last_name);
    try std.testing.expectEqual(@as(u32, 42), PerRequestWith.last_value);

    // 销毁第一个实例 — 应调用 deinit
    handler.vtable.destroy(handler.ptr, inst1);
    try std.testing.expect(PerRequestWith.deinit_called);

    // 销毁第二个实例
    PerRequestWith.deinit_called = false;
    handler.vtable.destroy(handler.ptr, inst2);
    try std.testing.expect(PerRequestWith.deinit_called);
}
