const std = @import("std");
const mem = std.mem;
const http = std.http;
const RequestContext = @import("request_context.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");

/// 路由处理器类型
pub const Handler = *const fn (*RequestContext, *Response) anyerror!void;

/// 增强的路由器，支持路径参数
allocator: std.mem.Allocator,
routes: std.ArrayList(Route),
not_found_handler: ?Handler = null,
error_handler: ?*const fn (anyerror, *RequestContext, *Response) anyerror!void = null,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .routes = std.ArrayList(Route).empty,
    };
}

pub fn deinit(self: *Self) void {
    self.routes.deinit(self.allocator);
}

/// 注册路由
pub fn route(self: *Self, method: http.Method, pattern: []const u8, handler: Handler) !void {
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = pattern,
        .handler = handler,
    });
}

/// 设置 404 处理器
pub fn notFound(self: *Self, handler: Handler) void {
    self.not_found_handler = handler;
}

/// 设置错误处理器
pub fn onError(self: *Self, handler: *const fn (anyerror, *RequestContext, *Response) anyerror!void) void {
    self.error_handler = handler;
}

/// 匹配路由并提取路径参数
pub fn match(self: *const Self, ctx: *RequestContext) !?Handler {
    for (self.routes.items) |r| {
        if (r.method != ctx.method) continue;

        if (try self.matchPattern(r.pattern, ctx.path, ctx)) {
            return r.handler;
        }
    }
    return null;
}

/// 模式匹配 /users/:id/posts/:postId
fn matchPattern(self: *const Self, pattern: []const u8, path: []const u8, ctx: *RequestContext) !bool {
    _ = self;
    var p_parts = mem.splitScalar(u8, pattern, '/');
    var path_parts = mem.splitScalar(u8, path, '/');

    while (p_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return false;

        if (p_part.len == 0 and path_part.len == 0) continue;

        if (p_part.len > 0 and p_part[0] == ':') {
            // 路径参数
            const param_name = p_part[1..];
            const param_value = try ctx.allocator.dupe(u8, path_part);
            const param_key = try ctx.allocator.dupe(u8, param_name);
            ctx.path_params.put(param_key, param_value) catch {};
        } else if (!mem.eql(u8, p_part, path_part)) {
            return false;
        }
    }

    // 确保路径也没有更多部分
    return path_parts.next() == null;
}

/// 带中间件的路由
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
};
