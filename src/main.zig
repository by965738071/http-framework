const std = @import("std");
const Io = std.Io;

const http_framework = @import("http_framework");
const core = @import("core");
const Server = core.Server;
const Router = core.Router;
const Static = core.Static;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Middle = core.Middle;
const logger = core.Logger;
const Handler = core.Handler;

const HomeHandler = @import("api/home.zig");
const UserHandler = @import("api/user.zig");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try http_framework.printAnotherMessage(stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!

    // 创建路由
    var router = Router.init(arena);
    defer router.deinit();

    const loggerMiddle = try logger.LogMiddleware.create(arena, io);
    const authMiddle = try logger.AuthMiddleware.create(arena, io);
    // 注册路由
    //
    //

    // 1. 初始化首页处理器 (堆分配)
    var home = try HomeHandler.create(arena, "My Awesome Zig 0.16 Server");
    defer home.destroy(); // 👈 千万别忘了销毁

    // 注册时，取出它内部的 .handler 字段
    try router.routeWithMiddleware(.GET, "/", home.handler, &.{ loggerMiddle.middle, authMiddle.middle });

    // 2. 初始化用户处理器 (堆分配)
    var user = try UserHandler.create(arena, "John Doe");
    defer user.destroy(); // 👈 千万别忘了销毁

    // 注册时，取出它内部的 .handler 字段
    try router.routeWithMiddleware(.GET, "/users/:id", user.handler, &.{ loggerMiddle.middle, authMiddle.middle });

    //try router.routeWithMiddleware(.GET, "/", try HomeHandler.create(arena, "HOME"), &.{ loggerMiddle.middle, authMiddle.middle });

    //try router.routeWithMiddleware(.POST, "/users", try UserHandler.create(arena, "USER"), &.{ loggerMiddle.middle, authMiddle.middle });
    //try router.route(.GET, "/ws", wsHandler);

    // 静态文件服务
    var static_server = Static.init(arena, io, "./public", "/static");

    try router.route(.GET, "/static/*", Handler.init(Static, &static_server));

    // 你甚至可以复用同一个 static_server 注册不同的前缀
    // try router.route(.GET, "/assets/*", Handler.init(StaticFileServer, &static_server));

    // 设置 404 处理器
    router.notFound(Handler.fromFn(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler));

    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:9000");
    var server = try Server.init(arena, io, address, router);

    try server.start();
    defer server.deinit();
}

// /// WebSocket 处理器
// fn wsHandler(ctx: *RequestContext, res: *Response) !void {
// _ = res;

// const ws = try WebSocketHandler.handle(ctx, ctx.request);

// // 简单的 echo 服务器
// var buffer: [1024]u8 = undefined;
// while (true) {
//     const msg = ws.readSmallMessage() catch |err| {
//         if (err == error.ConnectionClose) break;
//         return err;
//     };

//     // Echo 回消息
//     try ws.writeMessage(msg.data, msg.opcode);
// }
// }
