// //! 程序入口 (Zig 0.16)
// //!
// //! 演示如何使用 http_framework 创建 HTTP 服务器、注册路由及 WebSocket。
// //!
// //! # 测试 WebSocket
// //! 启动服务器后，使用 websocat 或浏览器控制台连接：
// //!   websocat ws://127.0.0.1:8080/ws
// //! 发送任意文本，服务器将回显相同内容。

// const std = @import("std");
// const Io = std.Io;
// const core = @import("core");
// const Server = core.Server;
// const Router = core.Router;
// const RequestContext = core.RequestContext;
// const Response = core.Response;
// const Handler = core.Handler;
// const Config = core.Config;
// const WebSocket = core.WebSocket;
// const Static = core.Static;

// const HomeHandler = @import("api/home.zig");
// const UserHandler = @import("api/user.zig");

// pub fn main(init: std.process.Init) !void {
//     // ================================================================
//     // 分配器
//     // ================================================================
//     // 使用 DebugAllocator 便于开发阶段检测内存泄漏。
//     // 也可直接使用 init.gpa（Arena），但 DebugAllocator 提供更细粒度的检查。
//     var gpa = std.heap.DebugAllocator(.{}){};
//     defer {
//         const leaked = gpa.deinit();
//         if (leaked == .leak) @panic("Memory leak detected");
//     }
//     const allocator = gpa.allocator();
//     const io = init.io; // 来自 Juicy Main 的标准 Io 实例

//     // ================================================================
//     // 路由器
//     // ================================================================
//     var router = Router.init(allocator);
//     defer router.deinit();

//     // ================================================================
//     // WebSocket 管理器（全局单例，管理所有 WebSocket 连接）
//     // ================================================================
//     var ws_manager = WebSocket.WebSocketManager.init(allocator, io);
//     defer ws_manager.deinit();

//     // 定时清理超时的 WebSocket 连接（简易版，生产环境建议用独立线程）
//     // 此处仅示意：框架若支持定时任务可挂载，否则需在 Server 的循环中调用。
//     // 作为演示，我们可以在每个 WebSocket 消息循环中触发清理，或由调用方自行处理。

//     // ================================================================
//     // 注册 HTTP 路由
//     // ================================================================

//     // 请求级模式 — 每次请求创建新实例，框架自动管理生命周期
//     try router.route(.GET, "/", Handler.initPerRequest(HomeHandler, allocator));

//     // 请求级模式（带参数）
//     try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
//         UserHandler,
//         allocator,
//         .{ .default_name = "John Doe" },
//     ));

//     // 404 处理（纯函数）
//     router.notFound(Handler.fromFn(struct {
//         fn handler(ctx: *RequestContext, res: *Response) !void {
//             _ = ctx;
//             try res.statusCode(.not_found).html(
//                 \\<!DOCTYPE html>
//                 \\<html><body><h1>404 - Page Not Found</h1></body></html>
//             );
//         }
//     }.handler));

//     // ================================================================
//     // 注册 WebSocket 路由（演示 echo 服务）
//     // ================================================================

//     // ================================================================
//     // 静态文件服务
//     // ================================================================

//     var static_server = Static.init(allocator, io, "/Users/by/project/zig/http-framework/public", "/static");
//     try router.route(.GET, "/static*", Handler.init(Static, &static_server));

//     // ================================================================
//     // 服务器配置与启动
//     // ================================================================
//     const config: core.Config.Config = .{};

//     var server = try Server.init(allocator, io, config, router);
//     defer server.deinit();
//     try server.run();
// }

// =========================================================================
// 主函数
// =========================================================================
const std = @import("std");
const Io = std.Io;
const core = @import("core");
const Server = core.Server;
const Router = core.Router;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;
const Config = core.Config;
const WebSocket = core.WebSocket;
const Static = core.Static;
const WsEchoHandler = core.WsEchoHandler;
const HomeHandler = @import("api/home.zig");
const UserHandler = @import("api/user.zig");

pub fn main(init: std.process.Init) !void {
    // ── 分配器 ──────────────────────────────────────────
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // ── 解析命令行参数（获取静态文件目录）───────────────
    var args = init.minimal.args.iterate();
    var static_dir: []const u8 = "public"; // 默认值

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--static-dir") or std.mem.eql(u8, arg, "-s")) {
            const dir = args.next() orelse {
                std.log.err("Missing value for --static-dir", .{});
                return error.InvalidArgs;
            };
            static_dir = dir;
            break;
        }
    }

    // ── 路由器 ──────────────────────────────────────────
    var router = Router.init(allocator);
    defer router.deinit();

    // ── WebSocket 管理器 & 处理器 ─────────────────────
    var ws_manager = WebSocket.WebSocketManager.init(allocator, io);
    defer ws_manager.deinit();

    var ws_echo = try WsEchoHandler.init(allocator, &ws_manager);
    defer ws_echo.deinit();

    // ── HTTP 路由 ───────────────────────────────────────
    try router.route(.GET, "/", Handler.initPerRequest(HomeHandler, allocator));
    try router.route(.GET, "/users/:id", Handler.initPerRequestWith(
        UserHandler,
        allocator,
        .{ .default_name = "John Doe" },
    ));

    // 404 处理
    router.notFound(Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler));

    // WebSocket 路由（单例模式）
    try router.route(.GET, "/ws", Handler.init(WsEchoHandler, ws_echo));

    // ── 静态文件服务（动态路径）─────────────────────────

    var static_server = Static.init(allocator, io, static_dir, "/static");
    try router.route(.GET, "/static*", Handler.init(Static, &static_server));

    // ── 服务器配置 ─────────────────────────────────────
    const config: core.Config.Config = .{};
    var server = try Server.init(allocator, io, config, router);
    defer server.deinit();
    try server.run();
}
