const std = @import("std");
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const NextAction = @import("middleware.zig").NextAction;
const Middle = @import("middleware.zig");

pub const LogMiddleware = struct {
    prefix: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    // 🚨 改变 1：返回指针，不再返回值
    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*LogMiddleware {
        // 🚨 改变 2：必须在堆上创建，保证地址不会变
        const ptr = try allocator.create(LogMiddleware);

        // 先初始化除 middle 以外的字段
        ptr.* = .{
            .prefix = "hello",
            .allocator = allocator,
            .io = io,
            .middle = undefined, // 临时占位
        };

        // 🚨 改变 3：现在有了稳定的堆指针，才能初始化 vtable
        ptr.middle = Middle.init(LogMiddleware, ptr);

        return ptr;
    }

    pub fn process(self: *LogMiddleware, ctx: *RequestContext) anyerror!NextAction {
        _ = self;
        // 注意：0.16 的 std.log.info 格式化可能有变，这里用 debug.print 替代确保能编译
        std.log.debug("请求路径：[{s}] 请求方法：[{s}]\n", .{
            ctx.request.head.target,
            @tagName(ctx.request.head.method),
        });
        return .err;
    }

    pub fn deinit(self: *LogMiddleware) void {
        std.debug.print("[{s}] 日志中间件销毁\n", .{self.prefix});
        // 🚨 改变 4：销毁时必须释放堆内存
        self.allocator.destroy(self);
    }
};

// === 鉴权中间件同样需要修改 ===
pub const AuthMiddleware = struct {
    token: []const u8,
    middle: Middle,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*AuthMiddleware {
        const ptr = try allocator.create(AuthMiddleware);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .middle = undefined,
            .token = "world",
        };
        ptr.middle = Middle.init(AuthMiddleware, ptr);
        return ptr;
    }

    pub fn process(self: *AuthMiddleware, ctx: *RequestContext) anyerror!NextAction {
        _ = ctx;
        if (std.mem.eql(u8, self.token, "secret")) {
            return .next;
        }
        return .next;
    }

    pub fn deinit(self: *AuthMiddleware) void {
        self.allocator.destroy(self);
    }
};
