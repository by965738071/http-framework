const std = @import("std");
// 假设这些存在
const RequestContext = @import("request.zig");
const Response = @import("response.zig");

/// 中间件接口
const Self = @This();

name: []const u8,
ptr: *anyopaque, // <--- 新增：必须要有这个字段来保存具体对象的指针
vtable: *const VTable,

const VTable = struct {
    process: *const fn (*anyopaque, *RequestContext) anyerror!NextAction,
    destroy: *const fn (*anyopaque) void,
};

pub const NextAction = enum {
    next,
    respond,
    err,
};

/// 修改 init，传入具体实例的指针
pub fn init(comptime T: type, ptr: *T) Self {
    return .{
        .ptr = ptr,
        .name = @typeName(T),
        .vtable = &.{
            .process = struct {
                fn process(ctx: *anyopaque, req_ctx: *RequestContext) anyerror!NextAction {
                    const t: *T = @ptrCast(@alignCast(ctx));
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

// --- 为了方便调用，通常还会提供包装方法 ---
pub fn process(self: Self, ctx: *RequestContext) anyerror!NextAction {
    return self.vtable.process(self.ptr, ctx);
}

pub fn destroy(self: Self) void {
    self.vtable.destroy(self.ptr);
}
