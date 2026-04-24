//! 用户 API 处理器
//!
//! 支持两种生命周期模式（可同时使用）：
//!
//! ## 单例模式（推荐 — 零分配）
//! ```zig
//! var user = try UserHandler.initSingleton(allocator, "John Doe");
//! defer user.deinit();
//! router.route(.GET, "/users/:id", Handler.init(UserHandler, user));
//! ```
//!
//! ## 请求级模式（每次请求独立状态）
//! ```zig
//! router.route(.GET, "/users/:id", Handler.initPerRequestWith(
//!     UserHandler, allocator, .{ .default_name = "John Doe" },
//! ));
//! ```

const std = @import("std");
const core = @import("core");
const RequestContext = core.RequestContext;
const Response = core.Response;

/// 用户信息处理器
///
/// 根据初始化方式不同，可以工作于单例或请求级模式。
default_name: []const u8,
allocator: std.mem.Allocator,

const Self = @This();

// =========================================================================
// 单例模式工厂
// =========================================================================

/// 创建单例实例（main 启动时调用一次，程序退出时 deinit）。
pub fn initSingleton(allocator: std.mem.Allocator, default_name: []const u8) !*Self {
    const ptr = try allocator.create(Self);
    const name_dup = try allocator.dupe(u8, default_name);
    ptr.* = .{
        .allocator = allocator,
        .default_name = name_dup,
    };
    return ptr;
}

// =========================================================================
// 请求级模式工厂（Handler.initPerRequestWith 要求的方法签名）
// =========================================================================

/// 请求级工厂方法 — 每次请求由框架自动调用。
///
/// `args` 结构体包含注册时传入的配置参数：
/// ```zig
/// .{ .default_name = "John Doe" }
/// ```
pub fn init(allocator: std.mem.Allocator, args: anytype) !*Self {
    const ptr = try allocator.create(Self);
    const name_dup = try allocator.dupe(u8, args.default_name);
    ptr.* = .{
        .allocator = allocator,
        .default_name = name_dup,
    };
    return ptr;
}

// =========================================================================
// 请求处理
// =========================================================================

/// 处理 `/users/:id` 请求，返回用户信息 JSON。
pub fn handle(self: *Self, ctx: *RequestContext, res: *Response) !void {
    const user_id = ctx.getParam("id") orelse "unknown";

    try res.json(.{
        .user_id = user_id,
        .name = self.default_name,
        .message = "Hello from Zig HTTP Framework",
    });
}

// =========================================================================
// 清理（单例模式和请求级模式共用）
// =========================================================================

/// 释放内部资源。
///
/// 框架的 VTable destroy 会自动调用 allocator.destroy(self)，
/// 所以这里只释放内部字段即可。
pub fn deinit(self: *Self) void {
    self.allocator.free(self.default_name);
}
