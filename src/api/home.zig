//! Home 页面处理器
//!
//! 演示 **请求级生命周期** 处理器。
//! 通过 `Handler.initPerRequest` 注册，框架自动管理每次请求的创建和销毁。
//!
//! # 设计说明
//!
//! - `title` 使用 comptime 常量，**零堆分配**（不需要 dupe）
//! - `init` 只做一次 `allocator.create(Self)`，不额外分配
//! - `deinit` **只释放内部资源**，不调 `allocator.destroy(self)`
//!   （框架的 VTable destroy 会统一调用 allocator.destroy）
//!
//! # deinit 规则
//!
//! 当前使用的是 `Handler.initPerRequest`，其 VTable destroy 会自动：
//!   1. 调用 `instance.deinit()`
//!   2. 调用 `allocator.destroy(instance)`
//!
//! 所以 `deinit` 中**不要**调 `allocator.destroy(self)`，否则 double free。

const std = @import("std");
const core = @import("core");
const RequestContext = core.RequestContext;
const Response = core.Response;

/// Home 页面处理器
///
/// 每次请求创建一个新实例，处理完毕后自动销毁。
/// 不持有任何堆分配的数据。
title: []const u8,

const Self = @This();

/// 页面标题（comptime 常量，零运行时开销）
const TITLE = "My Awesome Zig Server";

// =========================================================================
// 生命周期（Handler.initPerRequest 要求的方法签名）
// =========================================================================

/// 工厂方法 — 每次请求时由框架自动调用。
///
/// 只分配结构体本身，不 dupe 数据。
/// title 直接引用 comptime 常量。
pub fn init(allocator: std.mem.Allocator) !*Self {
    const ptr = try allocator.create(Self);
    ptr.* = .{
        .title = TITLE,
    };
    return ptr;
}

// =========================================================================
// 请求处理
// =========================================================================

/// 处理请求，返回动态生成的 HTML 页面。
///
/// 注意：`allocPrint` 使用了 `page_allocator`，因为这是要传给
/// `res.html()` 的临时数据，生命周期只需到响应发送完毕。
pub fn handle(self: *Self, ctx: *RequestContext, res: *Response) !void {
    _ = ctx;

    const html_content = try std.fmt.allocPrint(
        std.heap.page_allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{s}</title></head>
        \\<body>
        \\  <h1>Welcome to {s}!</h1>
        \\  <p>Welcome to the Zig HTTP Framework!</p>
        \\</body>
        \\<html>
    ,
        .{ self.title, self.title },
    );
    defer std.heap.page_allocator.free(html_content);

    try res.html(html_content);
}

// =========================================================================
// 清理
// =========================================================================

/// 释放内部资源。
///
/// 因为 title 指向 comptime 常量，没有堆分配的内部字段需要释放。
/// 方法体为空，框架的 VTable destroy 会自动调用 allocator.destroy(self)。
pub fn deinit(self: *Self) void {
    _ = self;
    // 没有堆分配的内部字段，不需要 free
    // allocator.destroy(self) 由 VTable destroy 统一处理
}
