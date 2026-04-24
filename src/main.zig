//! 程序入口
//!
//! 演示如何使用 http_framework 创建 HTTP 服务器、注册路由。
//!
//! # 生命周期模式说明
//!
//! ## 请求级模式（`Handler.initPerRequest`）
//! 每次请求框架自动创建新实例并销毁。
//! main.zig 中不需要手动 create/destroy。
//!
//! ```text
//! 每次请求:
//!   create → T.init(allocator) → 分配 *T
//!   handle → T.handle(ctx, res)
//!   destroy → T.deinit(self) + allocator.destroy(self)
//! ```
//!
//! ## 单例模式（`Handler.init`）
//! 零分配，实例在 main 启动时创建一次，程序退出时销毁。
//!
//! ```zig
//! var handler = try allocator.create(MyHandler);
//! handler.* = .{ ... };
//! defer allocator.destroy(handler);
//! router.route(.GET, "/path", Handler.init(MyHandler, handler));
//! ```
//!
//! ## 纯函数模式（`Handler.fromFn`）
//! 零分配，create/destroy 均为空操作。

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const Server = core.Server;
const Router = core.Router;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;
const Config = core.Config;

const HomeHandler = @import("api/home.zig");
const UserHandler = @import("api/user.zig");

pub fn main(init: std.process.Init) !void {
    // ================================================================
    // 分配器
    // ================================================================
    // init.gpa 是 Arena 分配器，内存只增不减。
    // 使用 DebugAllocator 在开发阶段检测内存泄漏。
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    // ================================================================
    // 路由器
    // ================================================================
    var router = Router.init(allocator);
    defer router.deinit();

    // ================================================================
    // 注册路由
    // ================================================================

    // 请求级模式 — 每次请求创建新实例，框架自动管理生命周期
    try router.route(.GET, "/", Handler.initPerRequest(HomeHandler, allocator));

    // 请求级模式（带参数）— 注册时传入配置，每次请求透传给 init
    try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
        UserHandler,
        allocator,
        .{ .default_name = "John Doe" },
    ));

    // 纯函数模式 — 零开销，无状态
    router.notFound(Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler));

    // ================================================================
    // 服务器配置与启动
    // ================================================================
    const config = Config.defaults();

    var server = try Server.init(allocator, io, config, router);
    defer server.deinit();
    try server.run();
}
