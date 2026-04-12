const std = @import("std");
const http = std.http;

const Config = @import("config.zig");
const Middleware = @import("middleware.zig");

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");

allocator: std.mem.Allocator,
io: std.Io,
tcpServer: std.Io.net.Server,
router: Router,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, router: Router) !Self {
    const server = try address.listen(io, .{ .mode = .stream, .protocol = .tcp });

    return .{
        .allocator = allocator,
        .io = io,
        .tcpServer = server,
        .router = router,
    };
}

pub fn start(self: *Self) !void {
    //var group = std.Io.Group.init;
    while (true) {
        const stream = try self.tcpServer.accept(self.io);
        var readerBuf: [4096]u8 = undefined;
        var writerBuf: [4096]u8 = undefined;
        var in = stream.reader(self.io, &readerBuf);
        var out = stream.writer(self.io, &writerBuf);

        var httpServer = std.http.Server.init(&in.interface, &out.interface);

        _ = try self.io.concurrent(struct {
            fn handle(httpStream: *http.Server, allocator: std.mem.Allocator, io: std.Io, router: *const Router) !void {
                handleRequest(httpStream, allocator, io, router) catch |err| {
                    std.log.err("handle request error {s}", .{@errorName(err)});
                    return err;
                };
            }
        }.handle, .{ &httpServer, self.allocator, self.io, &self.router });
    }
}
/// 主请求处理器
pub fn handleRequest(
    httpStream: *http.Server,
    allocator: std.mem.Allocator,
    io: std.Io,
    router: *const Router,
) !void {
    // 1. 解析请求头
    var request = try httpStream.receiveHead();

    // 2. 初始化上下文和响应
    var ctx = try RequestContext.init(allocator, io, &request);
    defer ctx.deinit();

    var response = Response.init(allocator, &request);
    defer response.deinit();

    // ==========================================
    // 🚀 核心变化：一行代码完成所有路由、中间件、Handler 调用！
    // ==========================================
    const result = router.dispatch(allocator, &ctx, &response) catch |dispatchErr| {
        // 只有在极其底层（如内存分配失败）报错时，才会走到这里
        if (router.error_handler) |eh| {
            try eh(dispatchErr, &ctx, &response);
        } else {
            try response.statusCode(.internal_server_error).json(.{ .err = @errorName(dispatchErr), .message = "Internal server error" });
        }
        return;
    };

    // ==========================================
    // 根据 DispatchResult 枚举，处理最终收尾工作
    // ==========================================
    switch (result) {
        .handled => {
            // 🎉 成功！Handler 或 404处理器 内部已经通过 res.html/res.json 写入了响应。
            // 这里什么都不用做，直接返回，外层会自动发送 response。
        },
        .not_found => {
            // 只有在【没有注册 404 处理器】的情况下，dispatch 才会返回这个枚举
            try response.statusCode(.not_found).json(.{
                .err = "Not Found",
                .path = ctx.path,
            });
        },
        .method_not_allowed => {
            // 路径对了，但 HTTP Method 错误
            try response.statusCode(.method_not_allowed).json(.{
                .err = "Method Not Allowed",
                .method = @tagName(ctx.method),
            });
        },
        .middleware_blocked => {
            // 被中间件拦截了（比如鉴权失败返回了 err）。
            // 通常中间件内部已经设置了 401/403 状态码并写了 JSON。
            // 这里做一个兜底：如果中间件啥也没写，给个默认提示。
            if (response.status == .ok) {
                try response.statusCode(.forbidden).text("Request blocked by middleware");
            }
        },
    }
}

pub fn deinit(self: *Self) void {
    self.tcpServer.deinit(self.io);
}
