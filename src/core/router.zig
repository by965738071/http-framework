const std = @import("std");
const mem = std.mem;
const http = std.http;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");

/// 路由处理器类型
pub const Handler = *const fn (*RequestContext, *Response) anyerror!void;

/// 增强的路由器，支持路径参数
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
};

const Self = @This();

allocator: std.mem.Allocator,
routes: std.ArrayList(Route),
not_found_handler: ?Handler = null,
error_handler: ?*const fn (anyerror, *RequestContext, *Response) anyerror!void = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        // 0.13+ 的 ArrayList 初始化方式
        .routes = std.ArrayList(Route).empty,
    };
}

pub fn deinit(self: *Self) void {
    // 0.13+ 的 ArrayList 清理方式
    self.routes.deinit(self.allocator);
}

/// 注册路由
pub fn route(self: *Self, method: http.Method, pattern: []const u8, handler: Handler) !void {
    // 0.13+ 的 append 不再需要传 allocator
    try self.routes.append(self.allocator,.{
        .method = method,
        .pattern = pattern,
        .handler = handler,
    });
}

pub fn routeWithMiddleware(self: *Self, method: http.Method, pattern: []const u8, handle: Handler, middle: []const Middleware) !void {
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = pattern,
        .handler = handle,
        .middlewares = middle,
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

/// 匹配路由并提取路径参数 (核心修复区)
pub fn match(self: *const Self, ctx: *RequestContext) !?Handler {
    for (self.routes.items) |r| {
        // 1. 规范化：去掉末尾的斜杠，避免 /api/users 和 /api/users/ 不匹配的问题
        const clean_pattern = trimSlash(r.pattern);
        const clean_path = trimSlash(ctx.path);

        // 2. 先匹配路径
        if (try self.matchPattern(clean_pattern, clean_path, ctx)) {
            // 3. 路径匹配成功！再检查 Method
            if (r.method != ctx.method) {
                // 只要路径对了，方法不对，严格返回 405 错误
                return error.MethodNotAllowed;
            }

            // 4. 执行该路由绑定的中间件
            if (r.middlewares.len > 0) {
                for (r.middlewares) |middle| {
                    // 🚨 修复：必须传递 middle.ptr (真实对象指针)，而不是 middle (包装器指针)
                    const action = try middle.vtable.process(middle.ptr, ctx);
                    switch (action) {
                        .next => continue,
                        .respond, .err => {
                            return error.MiddlewareInterrupted;
                        },
                    }
                }
            }

            // 中间件全部放行，返回真正的 Handler
            return r.handler;
        }
    }
    // 循环结束都没找到路径匹配项，才是真正的 404
    return null;
}

/// 路径模式匹配（支持 :id 等参数）
fn matchPattern(self: *const Self, pattern: []const u8, path: []const u8, ctx: *RequestContext) !bool {
    _ = self;

    // 如果都是空字符串（比如根路径 / 被trim成了空），直接匹配
    if (pattern.len == 0 and path.len == 0) return true;

    var p_parts = mem.splitScalar(u8, pattern, '/');
    var path_parts = mem.splitScalar(u8, path, '/');

    while (p_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return false;

        if (p_part.len == 0 and path_part.len == 0) continue;

        if (p_part.len > 0 and p_part[0] == ':') {
            // 提取路径参数并存入 ctx
            const param_name = p_part[1..];
            const param_key = try ctx.allocator.dupe(u8, param_name);
            const param_value = try ctx.allocator.dupe(u8, path_part);
            try ctx.path_params.put(param_key, param_value);
        } else if (!mem.eql(u8, p_part, path_part)) {
            return false;
        }
    }

    // 确保请求路径没有多余的部分
    return path_parts.next() == null;
}

/// 辅助函数：去掉路径头尾的 '/'
fn trimSlash(path: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = path.len;

    if (end > 0 and path[0] == '/') start = 1;
    if (end > start and path[end - 1] == '/') end -= 1;

    return path[start..end];
}
