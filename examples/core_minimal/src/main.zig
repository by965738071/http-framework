//! 只依赖 core 模块的最小 HTTP 服务器。
//!
//! 不用伞形模块 http_framework，不引任何 addon（无中间件、无静态文件、
//! 无日志器……），核心只有四件事：Router 注册路由 → Server.init →
//! server.run()。

const std = @import("std");
const core = @import("core");

const Router = core.Router;
const Server = core.Server;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 1. 路由表
    var router = Router.init(gpa);
    defer router.deinit();

    try router.route(.GET, "/", Handler.fromFn(indexHandler));
    try router.route(.GET, "/hello/:name", Handler.fromFn(helloHandler));

    // 2. 服务器（Config 全走默认值）
    var server = try Server.init(gpa, io, .{}, &router);
    defer server.deinit();

    // 3. 阻塞运行，Ctrl+C 优雅关闭
    try server.run();
}

fn indexHandler(_: *RequestContext, res: *Response) !void {
    try res.text("Hello from core-only server!\n");
}

fn helloHandler(ctx: *RequestContext, res: *Response) !void {
    const name = ctx.getParam("name") orelse "world";
    const body = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name});
    defer ctx.allocator.free(body);
    try res.html(body);
}
