const std = @import("std");
const RequestContext = @import("request_context.zig");
const Response = @import("response.zig");

/// 中间件接口
///
const Self = @This();
before: ?*const fn (*RequestContext) anyerror!void = null,
after: ?*const fn (*RequestContext, *Response) anyerror!void = null,

/// 日志中间件
pub const LoggingMiddleware = struct {
    pub fn before(ctx: *RequestContext) !void {
        const time = std.time.timestamp();
        std.log.info("[{d}] {s} {s}", .{
            time,
            @tagName(ctx.method),
            ctx.path,
        });
    }

    pub fn after(ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        _ = res;
        std.log.info("Request completed", .{});
    }
};

/// CORS 中间件
pub const CorsMiddleware = struct {
    allow_origin: []const u8 = "*",
    allow_methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS",
    allow_headers: []const u8 = "Content-Type, Authorization",

    pub fn before(self: @This(), ctx: *RequestContext) !void {
        _ = self;
        _ = ctx;
    }

    pub fn after(self: @This(), ctx: *RequestContext, res: *Response) !void {
        _ = ctx;
        try res.header("Access-Control-Allow-Origin", self.allow_origin);
        try res.header("Access-Control-Allow-Methods", self.allow_methods);
        try res.header("Access-Control-Allow-Headers", self.allow_headers);
    }
};
