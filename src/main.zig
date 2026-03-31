const std = @import("std");
const Io = std.Io;

const http_framework = @import("http_framework");
const Server = @import("core/server.zig");
const Router = @import("core/router.zig");
const StaticFileServer = @import("core/static_file_server.zig");
const RequestContext = @import("core/request_context.zig");
const Response = @import("core/response.zig");

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

    // 注册路由
    try router.route(.GET, "/", homeHandler);
    try router.route(.GET, "/api", apiHandler);
    try router.route(.GET, "/users/:id", userHandler);
    try router.route(.POST, "/users", createUserHandler);
    // try router.route(.GET, "/ws", wsHandler);

    // 静态文件服务
    // const static_server = StaticFileServer.init(arena, io, "./public", "/static");
    // try router.route(.GET, "/static/*", struct {
    //     fn handler(ctx: *RequestContext, res: *Response) !void {
    //         try static_server.handle(ctx, res);
    //     }
    // }.handler);

    // 设置 404 处理器
    router.notFound(struct {
        fn handler(ctx: *RequestContext, res: *Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler);

    const address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:9000");
    var server = try Server.init(arena, io, address, router);
    try server.start();
    defer server.deinit();
}

/// 首页处理器
fn homeHandler(ctx: *RequestContext, res: *Response) !void {
    _ = ctx;
    try res.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Zig HTTP Server</title></head>
        \\<body>
        \\  <h1>Welcome to Zig 0.16 HTTP Server!</h1>
        \\  <p>Server is running on Zig 0.16-dev</p>
        \\</body>
        \\</html>
    );
}

/// API 处理器
fn apiHandler(ctx: *RequestContext, res: *Response) !void {
    try res.json(.{
        .version = "0.16-dev",
        .method = @tagName(ctx.method),
        .path = ctx.path,
        .query_params = ctx.query_params.count(),
    });
}

/// 用户处理器（带路径参数）
fn userHandler(ctx: *RequestContext, res: *Response) !void {
    const user_id = ctx.getParam("id") orelse "unknown";

    try res.json(.{
        .user_id = user_id,
        .name = "John Doe",
        .email = "john@example.com",
    });
}

/// POST 数据处理
fn createUserHandler(ctx: *RequestContext, res: *Response) !void {
    const body = try ctx.readBody();

    try res.statusCode(.created).json(.{
        .success = true,
        .body_length = body.len,
        .content_type = ctx.content_type,
    });
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

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
