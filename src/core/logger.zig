//! 内置中间件实现
//!
//! 提供开箱即用的日志中间件和鉴权中间件示例。
//! 这些中间件使用堆分配 + VTable 模式，适配 `Middleware` 接口。

const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const NextAction = @import("middleware.zig").NextAction;
const Middle = @import("middleware.zig");

// =========================================================================
// LogMiddleware — 请求日志
// =========================================================================

/// 请求日志中间件。
///
/// 在每个请求被处理前，打印请求方法和路径。
pub const LogMiddleware = struct {
    prefix: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// 在堆上创建日志中间件。
    ///
    /// `prefix` 是日志前缀，用于区分多个日志中间件实例。
    pub fn create(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) !*LogMiddleware {
        const ptr = try allocator.create(LogMiddleware);
        ptr.* = .{
            .prefix = prefix,
            .allocator = allocator,
            .io = io,
            .middle = undefined,
        };
        ptr.middle = Middle.init(LogMiddleware, ptr);
        return ptr;
    }

    /// 处理请求：记录日志
    pub fn process(self: *LogMiddleware, ctx: *RequestContext) anyerror!NextAction {
        std.log.debug("[{s}] {s} {s}", .{
            self.prefix,
            @tagName(ctx.method),
            ctx.path,
        });
        return .next;
    }

    /// 销毁中间件并释放内存
    pub fn deinit(self: *LogMiddleware) void {
        std.log.debug("[{s}] LogMiddleware destroyed", .{self.prefix});
        self.allocator.destroy(self);
    }
};

// =========================================================================
// AuthMiddleware — 简单的 Token 鉴权
// =========================================================================

/// 基于 Token 的简单鉴权中间件。
///
/// 检查请求中是否包含与预期匹配的 `Authorization: Bearer <token>` 头。
pub const AuthMiddleware = struct {
    token: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// 在堆上创建鉴权中间件。
    ///
    /// `expected_token` 是期望的 Bearer token 值。
    pub fn create(allocator: std.mem.Allocator, io: std.Io, expected_token: []const u8) !*AuthMiddleware {
        const ptr = try allocator.create(AuthMiddleware);
        const token_dup = try allocator.dupe(u8, expected_token);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .middle = undefined,
            .token = token_dup,
        };
        ptr.middle = Middle.init(AuthMiddleware, ptr);
        return ptr;
    }

    /// 处理请求：验证 Bearer token
    pub fn process(self: *AuthMiddleware, ctx: *RequestContext) anyerror!NextAction {
        const auth_header = ctx.getHeader("Authorization") orelse {
            std.log.debug("[Auth] Missing Authorization header", .{});
            return .err;
        };

        const bearer_prefix = "Bearer ";
        if (!std.mem.startsWith(u8, auth_header, bearer_prefix)) {
            std.log.debug("[Auth] Invalid Authorization scheme", .{});
            return .err;
        }

        const provided_token = auth_header[bearer_prefix.len..];
        if (std.mem.eql(u8, provided_token, self.token)) {
            return .next;
        }

        std.log.debug("[Auth] Token mismatch", .{});
        return .err;
    }

    /// 销毁中间件并释放内存
    pub fn deinit(self: *AuthMiddleware) void {
        self.allocator.free(self.token);
        self.allocator.destroy(self);
    }
};
