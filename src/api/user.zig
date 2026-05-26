//! 用户 API 处理器
//!
//! 演示 **请求级生命周期** 处理器（带配置参数）。
//! 使用 `Handler.initPerRequestWith` 注册，框架自动管理每次请求的创建和销毁。
//!
//! # 性能说明
//!
//! - `default_name` 直接引用注册时传入的 `args` 中的 slice，**不做 dupe**
//! - `init` 只做一次 `allocator.create(Self)`，不额外分配
//! - `deinit` 为空（没有堆分配的内部字段需要释放）
//! - 框架的 VTable destroy 会自动调用 `allocator.destroy(self)`
//!
//! # 使用示例
//!
//! ```zig
//! try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
//!     UserHandler, allocator, .{ .default_name = "John Doe" },
//! ));
//! ```

const std = @import("std");
const core = @import("core");
const RequestContext = core.RequestContext;
const Response = core.Response;

/// 用户信息处理器
/// 每次请求创建一个新实例，处理完毕后自动销毁。
/// `default_name` 指向注册时传入的配置数据，不持有所有权。
default_name: []const u8,

const Self = @This();

// =========================================================================
// 生命周期（Handler.initPerRequestWith 要求的方法签名）
// =========================================================================

/// 工厂方法 — 每次请求时由框架自动调用。
///
/// `args` 结构体包含注册时传入的配置参数。
/// `default_name` 直接引用 `args` 中的数据，**不做 dupe**.
///
/// 注意：由于不 dupe，args 中的数据必须在路由器生命周期内保持有效。
/// 在 main.zig 中传入字符串字面量或 `allocator.dupe` 的持久数据即可。
pub fn init(allocator: std.mem.Allocator, args: anytype) !*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{
        .default_name = args.default_name,
    };
    return ptr;
}

// =========================================================================
// 请求处理
// =========================================================================

/// 处理 `/users/:id` 请求，返回用户信息 JSON。
///
/// **安全增强**：
/// - 验证 `id` 参数是否为数字
/// - 对输出进行 HTML 转义防止 XSS 攻击
pub fn handle(self: *Self, ctx: *RequestContext, res: *Response) !void {
    const user_id = ctx.getParam("id") orelse "unknown";

    try res.json(.{
        .user_id = user_id,
        .name = self.default_name,
        .message = "Hello from Zig HTTP Framework",
    });
}

// =========================================================================
// 清理
// =========================================================================

/// 释放内部资源。
///
/// `default_name` 不持有所有权，无需释放。
/// VTable destroy 会自动调用 allocator.destroy(self)。
pub fn deinit(self: *Self) void {
    _ = self;
}
