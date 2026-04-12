// src/handlers/user_handler.zig
const std = @import("std");
const core = @import("core");
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;

default_name: []const u8,
handler: Handler, // 👈 内部包含 Handler 类型
allocator: std.mem.Allocator,

const UserHandler = @This();

pub fn create(allocator: std.mem.Allocator, default_name: []const u8) !*UserHandler {
    const ptr = try allocator.create(UserHandler);
    ptr.* = .{
        .allocator = allocator,
        .default_name = default_name,
        .handler = undefined,
    };
    ptr.handler = Handler.init(UserHandler, ptr);
    return ptr;
}

/// 这个方法会被 VTable 自动调用
pub fn handle(self: *UserHandler, ctx: *RequestContext, res: *Response) !void {
    // 提取路径参数
    const user_id = ctx.getParam("id") orelse "unknown";

    // 使用结构体内部的状态 (default_name)
    try res.json(.{
        .user_id = user_id,
        .name = self.default_name,
        .message = "Fetched via Stateful VTable Handler",
    });
}

pub fn destroy(self: *UserHandler) void {
    self.allocator.destroy(self);
}
