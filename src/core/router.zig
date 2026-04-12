const std = @import("std");
const mem = std.mem;
const http = std.http;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");
const Handler = @import("handler.zig");

/// 增强的路由器，支持路径参数与请求级生命周期
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
};

pub const DispatchResult = enum {
    handled,
    not_found,
    method_not_allowed,
    middleware_blocked,
};

const Self = @This();

allocator: std.mem.Allocator, // 用于路由表本身的分配
routes: std.ArrayList(Route),
not_found_handler: ?Handler = null,
error_handler: ?*const fn (anyerror, *RequestContext, *Response) anyerror!void = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .routes = .empty,
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

// ==========================================
// 🚀 核心重构：请求级生命周期的派发器
// ==========================================
/// 注意这里的第一个参数：req_allocator
/// 它应该是一个“请求级分配器”（比如每个请求独立创建的 Arena 或 GPA）
pub fn dispatch(self: *const Self, req_allocator: std.mem.Allocator, ctx: *RequestContext, res: *Response) !DispatchResult {
    for (self.routes.items) |r| {
        const clean_pattern = trimSlash(r.pattern);
        const clean_path = trimSlash(ctx.path);

        if (try self.matchPattern(clean_pattern, clean_path, ctx)) {
            if (r.method != ctx.method) {
                return .method_not_allowed;
            }

            // 1. 执行中间件（中间件通常是全局单例，不需要每次请求创建）
            if (r.middlewares.len > 0) {
                for (r.middlewares) |middle| {
                    const action = try middle.vtable.process(middle.ptr, ctx);
                    switch (action) {
                        .next => continue,
                        .respond, .err => return .middleware_blocked,
                    }
                }
            }

            // ==========================================
            // 🌟 核心魔法：Handler 的按需创建与自动销毁
            // ==========================================

            // 2. 创建实例：调用 VTable 的 create 函数
            // 如果是简单的 Handler(fromFn)，这里直接返回原指针，开销为 0
            // 如果是复杂的 Handler，这里会在 req_allocator 上分配新内存
            const handler_instance = try r.handler.vtable.create(req_allocator, r.handler.ptr);

            // 3. 错误兜底：如果 handle 抛出异常，确保一定会执行 destroy 防止内存泄漏
            errdefer r.handler.vtable.destroy(req_allocator, handler_instance);

            // 4. 执行业务逻辑
            try r.handler.vtable.handle(handler_instance, ctx, res);

            // 5. 销毁实例：调用 VTable 的 destroy 函数
            // 如果用的是请求级 Arena 分配器，这里通常什么都不用做
            r.handler.vtable.destroy(req_allocator, handler_instance);

            return .handled;
        }
    }

    // 处理 404 (404 也走同样的生命周期，虽然通常它是空操作)
    if (self.not_found_handler) |nf| {
        const instance = try nf.vtable.create(req_allocator, nf.ptr);
        errdefer nf.vtable.destroy(req_allocator, instance);
        try nf.vtable.handle(instance, ctx, res);
        nf.vtable.destroy(req_allocator, instance);
        return .handled;
    }

    return .not_found;
}

/// 路径模式匹配（支持 :id 等参数）
fn matchPattern(self: *const Self, pattern: []const u8, path: []const u8, ctx: *RequestContext) !bool {
    _ = self;
    if (pattern.len == 0 and path.len == 0) return true;

    var p_parts = mem.splitScalar(u8, pattern, '/');
    var path_parts = mem.splitScalar(u8, path, '/');

    while (p_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return false;
        if (p_part.len == 0 and path_part.len == 0) continue;

        if (p_part.len > 0 and p_part[0] == ':') {
            const param_name = p_part[1..];
            const param_key = try ctx.allocator.dupe(u8, param_name); // 注意：这里用的是 ctx 自带的分配器
            const param_value = try ctx.allocator.dupe(u8, path_part);
            try ctx.path_params.put(param_key, param_value);
        } else if (!mem.eql(u8, p_part, path_part)) {
            return false;
        }
    }
    return path_parts.next() == null;
}

fn trimSlash(path: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = path.len;
    if (end > 0 and path[0] == '/') start = 1;
    if (end > start and path[end - 1] == '/') end -= 1;
    return path[start..end];
}
