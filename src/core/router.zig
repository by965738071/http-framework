//! HTTP 路由引擎
//!
//! 支持静态路径和动态路径参数（`:param` 语法），
//! 以及中间件链、404/错误处理器。

const std = @import("std");
const mem = std.mem;
const http = std.http;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Middleware = @import("middleware.zig");
const Handler = @import("handler.zig");

/// 单条路由记录
pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const Middleware = &.{},
    /// 可选的路由参数验证函数，在路径参数解析后调用。
    /// 如果返回 false，则跳过此路由（视为不匹配）。
    param_validator: ?*const fn (ctx: *RequestContext) bool = null,
};

/// 路由分发结果
pub const DispatchResult = enum {
    handled,
    not_found,
    method_not_allowed,
    middleware_blocked,
};

const Self = @This();

/// 路径参数最大数量（防止恶意超大路径）
const MAX_PATH_PARAMS = 32;

allocator: std.mem.Allocator,
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

/// 注册一条路由
pub fn route(self: *Self, method: http.Method, pattern: []const u8, handler: Handler) !void {
    try self.routes.append(self.allocator, .{
        .method = method,
        .pattern = pattern,
        .handler = handler,
    });
}

/// 注册一条带中间件的路由
pub fn routeWithMiddleware(
    self: *Self,
    method: http.Method,
    pattern: []const u8,
    handle: Handler,
    middle: []const Middleware,
) !void {
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

/// 设置错误处理器（路由分发过程中出现异常时调用）
pub fn onError(
    self: *Self,
    handler: *const fn (anyerror, *RequestContext, *Response) anyerror!void,
) void {
    self.error_handler = handler;
}

/// 分发请求到匹配的路由
///
/// 返回 `true` 表示已处理，`false` 表示无匹配。
pub fn dispatch(self: *const Self, ctx: *RequestContext, res: *Response) !bool {
    for (self.routes.items) |r| {
        const clean_pattern = trimSlash(r.pattern);
        const clean_path = trimSlash(ctx.path);

        if (matchPattern(clean_pattern, clean_path, self.allocator, ctx)) {
            // 参数验证（如果设置了验证器）
            if (r.param_validator) |validator| {
                if (!validator(ctx)) {
                    // 验证失败，清除已解析的路径参数，继续下一个路由
                    ctx.path_params.deinit(self.allocator);
                    ctx.path_params = std.StringHashMapUnmanaged([]const u8).empty;
                    continue;
                }
            }

            // 方法必须匹配
            if (r.method != ctx.method) {
                continue;
            }

            // 执行中间件链
            if (r.middlewares.len > 0) {
                for (r.middlewares) |middle| {
                    const action = try middle.vtable.process(middle.ptr, ctx);
                    switch (action) {
                        .next => continue,
                        .respond => return true,
                        .err => return true,
                    }
                }
            }

            // 创建处理器实例并执行
            const handler_instance = try r.handler.vtable.create(r.handler.ptr);
            defer r.handler.vtable.destroy(r.handler.ptr, handler_instance);
            try r.handler.vtable.handle(handler_instance, ctx, res);
            return true;
        }
    }

    // 无匹配 → 调用 404 处理器（如果已设置）
    if (self.not_found_handler) |nf| {
        const instance = try nf.vtable.create(nf.ptr);
        defer nf.vtable.destroy(nf.ptr, instance);
        try nf.vtable.handle(instance, ctx, res);
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// 路径模式匹配
// ---------------------------------------------------------------------------

/// 将路径模式与真实路径进行匹配，支持 `:param` 动态参数。
///
/// 匹配成功时，参数会被写入 `ctx.path_params`。
fn matchPattern(
    pattern: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    ctx: *RequestContext,
) bool {
    if (pattern.len == 0 and path.len == 0) return true;

    var p_parts = mem.splitScalar(u8, pattern, '/');
    var path_parts = mem.splitScalar(u8, path, '/');

    var params_buf: [MAX_PATH_PARAMS]struct { key: []const u8, value: []const u8 } = undefined;
    var params_len: usize = 0;

    while (p_parts.next()) |p_part| {
        const path_part = path_parts.next() orelse return false;
        if (p_part.len == 0 and path_part.len == 0) continue;

        if (p_part.len > 0 and p_part[0] == ':') {
            if (params_len >= MAX_PATH_PARAMS) return false; // 防御性限制
            params_buf[params_len] = .{
                .key = p_part[1..],
                .value = path_part,
            };
            params_len += 1;
        } else if (!mem.eql(u8, p_part, path_part)) {
            return false;
        }
    }

    // 路径段数量必须一致
    if (path_parts.next() != null) return false;

    // ---------- 所有匹配检查通过，一次性写入 context ----------
    // 注意：这里仅在完全匹配后才分配内存，避免中途失败留下脏数据
    for (params_buf[0..params_len]) |param| {
        const key_dup = allocator.dupe(u8, param.key) catch return false;
        const val_dup = allocator.dupe(u8, param.value) catch {
            allocator.free(key_dup);
            return false;
        };
        ctx.path_params.put(allocator, key_dup, val_dup) catch {
            allocator.free(key_dup);
            allocator.free(val_dup);
            return false;
        };
    }

    return true;
}

/// 去除首尾的 `/` 字符
fn trimSlash(path: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = path.len;

    if (end > 0 and path[0] == '/') start = 1;
    if (end > start and path[end - 1] == '/') end -= 1;

    return path[start..end];
}
