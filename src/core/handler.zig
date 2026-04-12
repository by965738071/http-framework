// src/core/handler.zig
const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

const Handler = @This();

ptr: *anyopaque,
vtable: *const VTable,

const VTable = struct {
    // 🚨 新增：工厂函数，用于按需创建实例
    create: *const fn (std.mem.Allocator, *anyopaque) anyerror!*anyopaque,
    // 原有：处理请求
    handle: *const fn (*anyopaque, *RequestContext, *Response) anyerror!void,
    // 🚨 新增：销毁函数
    destroy: *const fn (std.mem.Allocator, *anyopaque) void,
};

/// 1. 用于“无状态纯函数” (零开销适配)
pub fn fromFn(comptime func: *const fn (*RequestContext, *Response) anyerror!void) Handler {
    const Dummy = struct { data: [0]u8 = .{} };
    return .{
        .ptr = @ptrCast(@constCast(&Dummy{})),
        .vtable = &.{
            .create = struct {
                // 纯函数不需要创建，直接返回虚拟指针
                fn create(_: std.mem.Allocator, ctx: *anyopaque) anyerror!*anyopaque {
                    return ctx;
                }
            }.create,
            .handle = struct {
                fn call(_: *anyopaque, c: *RequestContext, r: *Response) anyerror!void {
                    return func(c, r);
                }
            }.call,
            .destroy = struct {
                // 纯函数不需要销毁
                fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
            }.destroy,
        },
    };
}

/// 2. 用于“全局单例结构体” (如你之前的 StaticFileServer)
pub fn init(comptime T: type, ptr: *T) Handler {
    return .{
        .ptr = @ptrCast(ptr),
        .vtable = &.{
            .create = struct {
                // 单例不创建新对象，直接把传入的指针原路返回
                fn create(_: std.mem.Allocator, ctx: *anyopaque) anyerror!*anyopaque {
                    return ctx;
                }
            }.create,
            .handle = struct {
                fn call(ctx: *anyopaque, req: *RequestContext, res: *Response) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    return self.handle(req, res);
                }
            }.call,
            .destroy = struct {
                // 单例绝对不允许在这里销毁！
                fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
            }.destroy,
        },
    };
}

// (未来你可以在这里加一个 initPerRequest，让 create 真正去 allocator.create)
