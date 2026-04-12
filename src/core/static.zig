const std = @import("std");
const mem = std.mem;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");

/// 高性能、安全的静态文件服务器 (基于 Zig 0.16 std.Io)
allocator: std.mem.Allocator,
io: std.Io,
root_dir: []const u8,
url_prefix: []const u8,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    url_prefix: []const u8,
) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .url_prefix = url_prefix,
    };
}

/// 处理静态文件请求 (完美契合 Handler VTable 签名)
pub fn handle(self: *const Self, ctx: *RequestContext, res: *Response) !void {
    // 1. 提取相对路径 (去除 /static 前缀)
    const relative_path = self.stripPrefix(ctx.path, self.url_prefix) orelse {
        try res.statusCode(.bad_request).text("Invalid static path");
        return;
    };

    // 如果访问的就是 /static/ 本身，默认寻找 index.html
    const target_path = if (relative_path.len == 0) "index.html" else relative_path;

    // 2. 拼接绝对路径
    const full_path = try std.fs.path.join(self.allocator, &.{ self.root_dir, target_path });
    defer self.allocator.free(full_path);

    // 3. 🛡️ 安全核心：解析真实路径，防止目录遍历 (Path Traversal)
    // 使用 0.16 的 std.Io 接口，兼容 io_uring 和线程模型
    const real_root = std.Io.Dir.realPathFileAlloc(.cwd(), self.io, self.root_dir, self.allocator) catch |err| {
        try res.statusCode(.internal_server_error).text("Failed to resolve root path");
        return err;
    };
    defer self.allocator.free(real_root);

    const real_full = std.Io.Dir.realPathFileAlloc(.cwd(), self.io, full_path, self.allocator) catch |err| {
        // 解析失败通常意味着路径不存在或权限不够
        try res.statusCode(.not_found).text("File not found");
        return err;
    };
    defer self.allocator.free(real_full);

    // 确保解析后的路径依然被包裹在 root_dir 内部
    if (!mem.startsWith(u8, real_full, real_root)) {
        try res.statusCode(.forbidden).text("Access denied");
        return;
    }

    // 4. 读取文件内容 (使用 0.16 的 std.Io 异步读取)
    const file_content = std.Io.Dir.readFileAlloc(
        .cwd(),
        self.io,
        real_full,
        self.allocator,
        .unlimited, // 静态文件通常不大，直接全量读取
    ) catch |file_err| {
        switch (file_err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            error.AccessDenied => try res.statusCode(.forbidden).text("Access denied"),
            else => try res.statusCode(.internal_server_error).text(@errorName(file_err)),
        }
        return;
    };
    defer self.allocator.free(file_content);

    // 5. 根据扩展名获取 Content-Type 并响应
    const content_type = getContentType(real_full);
    try res.file(file_content, content_type);
}

/// 辅助函数：安全地去除 URL 前缀
/// 例如: ("/static/css/a.css", "/static") => "css/a.css"
fn stripPrefix(self: *const Self, path: []const u8, prefix: []const u8) ?[]const u8 {
    _ = self;
    if (mem.startsWith(u8, path, prefix)) {
        var rest = path[prefix.len..];
        // 去除前缀后可能紧跟的 '/' (例如 /static/ 变成 /)
        if (rest.len > 0 and rest[0] == '/') {
            rest = rest[1..];
        }
        return rest;
    }
    return null;
}

/// 编译期确定的 Content-Type 映射表 (零运行时开销)
fn getContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);

    // 使用匿名结构体元组 + inline for，在编译期展开为一系列 if 判断
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
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
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

    // 未知的文件类型，强制作为二进制流下载，防止浏览器直接渲染敏感内容
    return "application/octet-stream";
}
