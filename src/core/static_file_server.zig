const std = @import("std");
const mem = std.mem;
const RequestContext = @import("request_context.zig");
const Response = @import("response.zig");

/// 静态文件服务器
allocator: std.mem.Allocator,
root_path: []const u8,
prefix: []const u8,
io: std.Io,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, prefix: []const u8) Self {
    return .{
        .allocator = allocator,
        .root_path = root_path,
        .prefix = prefix,
        .io = io,
    };
}

/// 处理静态文件请求
pub fn handle(self: *const Self, ctx: *RequestContext, res: *Response) !void {
    // 移除前缀获取文件路径
    const file_path = if (mem.startsWith(u8, ctx.path, self.prefix))
        ctx.path[self.prefix.len..]
    else
        ctx.path;

    // 构建完整路径
    const full_path = try std.fs.path.join(self.allocator, &.{ self.root_path, file_path });
    defer self.allocator.free(full_path);

    const resolved_path = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), self.io, full_path, self.allocator);
    defer self.allocator.free(resolved_path);
    // 安全检查：防止目录遍历攻击
    // const resolved_path = try std.fs.realpathAlloc(self.allocator, full_path);
    // defer self.allocator.free(resolved_path);

    const real_root = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), self.io, self.root_path, self.allocator);
    // const real_root = try std.fs.realpathAlloc(self.allocator, self.root_path);
    defer self.allocator.free(real_root);

    if (!mem.startsWith(u8, resolved_path, real_root)) {
        try res.statusCode(.forbidden).text("Access denied");
        return;
    }

    const file_content = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        self.io,
        resolved_path,
        self.allocator,
        .unlimited,
    ) catch |file_err| {
        switch (file_err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            else => try res.statusCode(.internal_server_error).text(@errorName(file_err)),
        }
        return;
    };
    defer self.allocator.free(file_content);

    // 根据扩展名设置 Content-Type
    const content_type = getContentType(resolved_path);

    try res.file(file_content, content_type);
}

/// 根据文件扩展名获取 Content-Type
fn getContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);

    const type_map = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".mp4", "video/mp4" },
        .{ ".mp3", "audio/mpeg" },
    };

    inline for (type_map) |entry| {
        if (mem.eql(u8, ext, entry[0])) {
            return entry[1];
        }
    }

    return "application/octet-stream";
}
