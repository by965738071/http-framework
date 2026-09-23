//! hello.zig — http_framework 极简示例
//!
//! 展示最基本的 HTTP server 用法：3 条路由 + JSON 响应。
//! 用法：
//!   cd examples && zig build run -- hello
//! 然后访问 http://127.0.0.1:9000/

const std = @import("std");
const framework = @import("http_framework");

pub fn main(init: std.process.Init) !void {
    _ = init;
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer {
        if (debug_allocator.deinit() == .leak) {
            std.debug.print("error:memory leak\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = debug_allocator.allocator();
    try framework.runZio(allocator, appMain);
}

fn appMain(io: std.Io, allocator: std.mem.Allocator) !void {
    var router = try framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/", framework.Handler.fromFn(hello));
    try router.route(.GET, "/health", framework.Handler.fromFn(health));
    try router.route(.GET, "/users/:id", framework.Handler.fromFn(user));

    var error_renderer = framework.ErrorRenderer{};
    try router.use(framework.Middleware.init(framework.ErrorRenderer, &error_renderer));

    var server = try framework.Server.init(allocator, io, .{ .network = .{ .port = 9000 } }, &router);
    defer server.deinit();
    try server.setup();
    try server.run();
}

fn hello(_: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .message = "Hello, World!" });
}

fn health(_: *framework.Context, res: *framework.Response) !void {
    try res.json(.{ .status = "ok" });
}

fn user(ctx: *framework.Context, res: *framework.Response) !void {
    const id = ctx.param("id") orelse {
        try ctx.failWith(framework.AppError.badRequest("missing :id"));
        return;
    };
    try res.json(.{ .user_id = id });
}
