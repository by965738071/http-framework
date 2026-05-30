//! 中间件接口
//!
//! 中间件是请求处理管道中的一个环节，可以在请求到达处理器之前或
//! 响应发送之后执行逻辑（如日志记录、鉴权、速率限制等）。
//!
//! # 设计模式
//!
//! 使用 VTable 多态模式，支持任意类型的中间件实现。
//! 每个中间件实例必须提供 `process` 方法，返回 `NextAction`
//! 指示框架下一步行为。
//!
//! # 使用示例
//!
//! ```zig
//! const MyMiddleware = struct {
//!     pub fn process(ctx: *RequestContext) anyerror!NextAction {
//!         std.log.debug("request: {s}", .{ ctx.path });
//!         return .next;
//!     }
//! };
//!
//! var mm = MyMiddleware{};
//! var middle = Middleware.init(MyMiddleware, &mm);
//! ```

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

/// 中间件类型
const Self = @This();

/// 中间件名称（用于日志/诊断）
name: []const u8,
/// 指向具体中间件实例的不透明指针
ptr: *anyopaque,
/// 虚函数表
vtable: *const VTable,

/// 虚函数表定义
const VTable = struct {
    process: *const fn (*anyopaque, *RequestContext) anyerror!NextAction,
    destroy: *const fn (*anyopaque) void,
};

/// 中间件返回的动作指示
pub const NextAction = enum {
    /// 继续执行后续中间件和处理器
    next,
    /// 直接响应，跳过后续中间件和处理器
    respond,
    /// 发生错误，跳过后续处理
    err,
};

/// 创建一个中间件实例。
///
/// `ptr` 必须指向一个在中间件生命周期内稳定的实例。
/// 要求类型 `T` 具有以下方法签名：
/// ```zig
/// pub fn process(*T, *RequestContext) anyerror!NextAction
/// ```
pub fn init(comptime T: type, ptr: *T) Self {
    return .{
        .ptr = ptr,
        .name = @typeName(T),
        .vtable = &.{
            .process = struct {
                fn process(any: *anyopaque, req_ctx: *RequestContext) anyerror!NextAction {
                    const t: *T = @ptrCast(@alignCast(any));
                    return t.process(req_ctx);
                }
            }.process,
            .destroy = struct {
                fn destroy(ctx: *anyopaque) void {
                    const t: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "deinit")) {
                        t.deinit();
                    }
                }
            }.destroy,
        },
    };
}

/// 执行中间件的处理逻辑
pub fn process(self: Self, ctx: *RequestContext) anyerror!NextAction {
    return self.vtable.process(self.ptr, ctx);
}

/// 销毁中间件及其持有的资源
pub fn destroy(self: Self) void {
    self.vtable.destroy(self.ptr);
}

// ===========================================================================
// 测试
// ===========================================================================

test "Middleware.init - creates middleware" {
    const T = struct {
        call_count: u32 = 0,

        pub fn process(self: *@This(), req_ctx: *RequestContext) anyerror!NextAction {
            _ = req_ctx;
            self.call_count += 1;
            return .next;
        }
    };

    var t = T{};
    const mw = Self.init(T, &t);

    try std.testing.expectEqualStrings(@typeName(T), mw.name);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&t)), mw.ptr);
}

test "Middleware.process - executes and returns next" {
    const T = struct {
        call_count: u32 = 0,

        pub fn process(self: *@This(), req_ctx: *RequestContext) anyerror!NextAction {
            _ = req_ctx;
            self.call_count += 1;
            return .next;
        }
    };

    var t = T{};
    const mw = Self.init(T, &t);

    const req: *RequestContext = @ptrFromInt(0x1000);
    const action = try mw.process(req);

    try std.testing.expectEqual(NextAction.next, action);
    try std.testing.expectEqual(@as(u32, 1), t.call_count);
}

test "Middleware.destroy - calls deinit" {
    const T = struct {
        deinit_called: bool = false,

        pub fn process(self: *@This(), req_ctx: *RequestContext) anyerror!NextAction {
            _ = self;
            _ = req_ctx;
            return .next;
        }

        pub fn deinit(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var t = T{};
    const mw = Self.init(T, &t);
    mw.destroy();

    try std.testing.expect(t.deinit_called);
}
