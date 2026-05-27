const std = @import("std");
pub const http_framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // 初始化路由器
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    // 注册路由
    //try router.route(.GET, "/", http_framework.Handler.initPerRequest(http_framework.HomeHandler, allocator));
    //try router.route(.GET, "/users/:id", http_framework.Handler.initPerRequestWith(http_framework.UserHandler, allocator, .{ .default_name = "John Doe" }));

    // 404 处理
    router.notFound(http_framework.Handler.fromFn(struct {
        fn handler(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
            _ = ctx;
            try res.statusCode(.not_found).html(
                \\<!DOCTYPE html>
                \\<html><body><h1>404 - Page Not Found</h1></body></html>
            );
        }
    }.handler));

    // 启动服务器
    const config = http_framework.Config.Config{};
    var server = try http_framework.Server.init(allocator, io, config, router);
    defer server.deinit();
    try server.run();
}
