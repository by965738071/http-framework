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
            fn handle(httpStream: *http.Server, allocator: std.mem.Allocator, io: std.Io, router: Router) !void {
                handleRequest(httpStream, allocator, io, router) catch |err| {
                    std.log.err("handle request error {s}", .{@errorName(err)});
                    return err;
                };
            }
        }.handle, .{ &httpServer, self.allocator, self.io, self.router });
    }
}

/// 主请求处理器
pub fn handleRequest(httpStream: *http.Server, allocator: std.mem.Allocator, io: std.Io, router: Router) !void {
    var request = try httpStream.receiveHead();

    var ctx = try RequestContext.init(allocator, io, &request);
    defer ctx.deinit();

    var response = Response.init(allocator, &request);
    defer response.deinit();

    if (router.match(&ctx) catch |matchErr| {
        if (router.error_handler) |eh| {
            try eh(matchErr, &ctx, &response);
        } else {
            try response.statusCode(.internal_server_error).json(.{ .err = @errorName(matchErr), .message = "Internal server error" });
        }
        return;
    }) |handler| {
        handler(&ctx, &response) catch |err| {
            if (router.error_handler) |eh| {
                try eh(err, &ctx, &response);
            } else {
                try response.statusCode(.internal_server_error).json(.{ .err = @errorName(err), .message = "Internal server error" });
            }
        };
    } else if (router.not_found_handler) |nf| {
        nf(&ctx, &response) catch {};
    } else {
        try response.statusCode(.not_found).json(.{
            .err = "Not Found",
            .path = ctx.path,
        });
    }
}

pub fn deinit(self: *Self) void {
    self.tcpServer.deinit(self.io);
}
