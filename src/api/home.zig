//! Home 页面处理器
//!
//! 演示 **请求级生命周期** 处理器。
//! 通过 `Handler.initPerRequest` 注册，框架自动管理每次请求的创建和销毁。
//!
//! # 性能说明
//!
//! - HTML 模板在编译期完全展开为 `[]const u8` 常量，**零运行时分配**
//! - `init` 只做一次 `allocator.create(Self)`，不 dupe 任何数据
//! - `deinit` 为空（没有堆分配的内部字段需要释放）
//! - 框架的 VTable destroy 会自动调用 `allocator.destroy(self)`
//!
//! # 使用示例
//!
//! ```zig
//! try router.route(.GET, "/", Handler.initPerRequest(HomeHandler, allocator));
//! ```

const std = @import("std");
const fw = @import("http_framework");
const RequestContext = fw.RequestContext;
const Response = fw.Response;

/// Home 页面处理器
///
/// 每次请求创建一个新实例，处理完毕后自动销毁。
/// 所有数据均为 comptime 常量，零堆分配。
title: []const u8,

const Self = @This();

// =========================================================================
// 生命周期（Handler.initPerRequest 要求的方法签名）
// =========================================================================

/// 工厂方法 — 每次请求时由框架自动调用。
///
/// 只分配结构体本身，title 直接引用 comptime 常量。
pub fn init(allocator: std.mem.Allocator) !*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{ .title = TITLE };
    return ptr;
}

/// 请求级工厂方法（带参数版本用）— 允许外部传入标题。
pub fn initWithTitle(allocator: std.mem.Allocator, title: []const u8) !*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{ .title = title };
    return ptr;
}

// =========================================================================
// 请求处理
// =========================================================================

/// 处理请求，返回静态 HTML 页面。
///
/// HTML 完全嵌入在全局 comptime 常量中，零运行时格式化开销。
pub fn handle(self: *Self, ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    _ = self;
    try res.html(HTML);
}

// =========================================================================
// 清理
// =========================================================================

/// 释放内部资源。
///
/// title 指向 comptime 常量，无需释放。
/// VTable destroy 会自动调用 allocator.destroy(self)。
pub fn deinit(self: *Self) void {
    _ = self;
}

// ===========================================================================
// 编译期常量
// ===========================================================================

/// 页面标题
const TITLE = "My Awesome Zig Server";

/// 完整的 HTML 页面（编译期确定，零运行时开销）
const HTML = "<!DOCTYPE html>\n" ++
    "<html>\n" ++
    "<head><title>" ++ TITLE ++ "</title></head>\n" ++
    "<body>\n" ++
    "  <h1>Welcome to " ++ TITLE ++ "!</h1>\n" ++
    "  <p>Welcome to the Zig HTTP Framework!</p>\n" ++
    "  <p><em>Served by initPerRequest</em></p>\n" ++
    "</body>\n" ++
    "<html>";

// =========================================================================
// 测试
// =========================================================================

test "HomeHandler.init - creates instance with TITLE" {
    const allocator = std.testing.allocator;
    const handler = try Self.init(allocator);
    defer allocator.destroy(handler);

    try std.testing.expectEqualStrings("My Awesome Zig Server", handler.title);
}

test "HomeHandler.initWithTitle - creates instance with custom title" {
    const allocator = std.testing.allocator;
    const handler = try Self.initWithTitle(allocator, "Custom Title");
    defer allocator.destroy(handler);

    try std.testing.expectEqualStrings("Custom Title", handler.title);
}

test "HomeHandler.deinit - no-op does not crash" {
    const allocator = std.testing.allocator;
    const handler = try Self.init(allocator);
    defer allocator.destroy(handler);

    handler.deinit();
}

test "HomeHandler - TITLE constant is correct" {
    try std.testing.expectEqualStrings("My Awesome Zig Server", TITLE);
}

test "HomeHandler - HTML contains title" {
    try std.testing.expect(std.mem.indexOf(u8, HTML, TITLE) != null);
    try std.testing.expect(std.mem.indexOf(u8, HTML, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, HTML, "</body>") != null);
}

test "HomeHandler - Handler.initPerRequest vtable integration" {
    const allocator = std.testing.allocator;
    const Handler = fw.Handler;

    const handler = try Handler.initPerRequest(Self, allocator);
    defer {
        const ctx: *std.mem.Allocator = @ptrCast(@alignCast(handler.ptr));
        allocator.destroy(ctx);
    }

    // Create instance via vtable
    const instance = try handler.vtable.create(handler.ptr);
    const typed: *Self = @ptrCast(@alignCast(instance));
    try std.testing.expectEqualStrings("My Awesome Zig Server", typed.title);

    // Destroy via vtable
    handler.vtable.destroy(handler.ptr, instance);
}

test "HomeHandler - init returns distinct instances" {
    const allocator = std.testing.allocator;
    const h1 = try Self.init(allocator);
    defer allocator.destroy(h1);
    const h2 = try Self.init(allocator);
    defer allocator.destroy(h2);

    try std.testing.expect(h1 != h2);
    try std.testing.expectEqualStrings(h1.title, h2.title);
}

test "HomeHandler - initWithTitle with empty string" {
    const allocator = std.testing.allocator;
    const handler = try Self.initWithTitle(allocator, "");
    defer allocator.destroy(handler);

    try std.testing.expectEqualStrings("", handler.title);
}

test "HomeHandler - initWithTitle with long string" {
    const allocator = std.testing.allocator;
    const long_title = "A" * *1000;
    const handler = try Self.initWithTitle(allocator, long_title);
    defer allocator.destroy(handler);

    try std.testing.expectEqualStrings(long_title, handler.title);
}
