//! 静态文件服务器
//!
//! 提供安全、高效的静态资源文件服务。
//! 内置**目录遍历攻击防护**，确保请求路径始终被限制在根目录内。
//!
//! # 使用示例
//!
//! ```zig
//! var static = Static.init(allocator, io, "./public", "/static");
//! // 使用 Handler.init 注册到路由器
//! try router.route(.GET, "/static/*", Handler.init(Static, &static));
//! ```

const std = @import("std");
const mem = std.mem;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Handler = @import("handler.zig");

/// 高性能、安全的静态文件服务器
allocator: std.mem.Allocator,
io: std.Io,
root_dir: []const u8,
url_prefix: []const u8,

const Self = @This();

// =========================================================================
// 初始化
// =========================================================================

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    url_prefix: []const u8,
) Self {
    // 规范化 url_prefix：确保不以 '/' 结尾
    var normalized_prefix = url_prefix;
    if (normalized_prefix.len > 1 and normalized_prefix[normalized_prefix.len - 1] == '/') {
        normalized_prefix = normalized_prefix[0 .. normalized_prefix.len - 1];
    }

    return .{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .url_prefix = normalized_prefix,
    };
}

// =========================================================================
// 请求处理（兼容 Handler VTable 要求的方法签名）
// =========================================================================

/// 处理静态文件请求
pub fn handle(self: *const Self, ctx: *RequestContext, res: *Response) !void {
    // 1. 去除 URL 前缀，提取相对路径
    const relative_path = self.stripPrefix(ctx.path) orelse {
        try res.statusCode(.bad_request).text("Invalid static path");
        return;
    };

    // 如果访问的是根路径，默认返回 index.html
    const target_relative = if (relative_path.len == 0) "index.html" else relative_path;

    // 2. 拼接完整路径
    const full_path = try std.fs.path.join(self.allocator, &.{ self.root_dir, target_relative });
    defer self.allocator.free(full_path);

    // 3. 🛡️ 安全核心：解析真实路径，防止目录遍历
    //
    //    `realPathFileAlloc` 会解析符号链接和 `..` 等，
    //    返回规范化的绝对路径。然后我们验证解析后的路径
    //    是否仍在 root_dir 之下。
    const cwd_dir = std.Io.Dir.cwd();

    const real_root = std.Io.Dir.realPathFileAlloc(cwd_dir, self.io, self.root_dir, self.allocator) catch |err| {
        std.log.err("Failed to resolve root dir '{s}': {}", .{ self.root_dir, err });
        try res.statusCode(.internal_server_error).text("Failed to resolve root path");
        return;
    };
    defer self.allocator.free(real_root);

    const real_full = std.Io.Dir.realPathFileAlloc(cwd_dir, self.io, full_path, self.allocator) catch |err| {
        // 文件不存在或权限不足是常见情况
        switch (err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            error.AccessDenied => try res.statusCode(.forbidden).text("Access denied"),
            else => {
                std.log.err("Failed to resolve path '{s}': {}", .{ full_path, err });
                try res.statusCode(.internal_server_error).text(@errorName(err));
            },
        }
        return;
    };
    defer self.allocator.free(real_full);

    // 安全检查：确保解析后的真实路径以根目录开头
    if (!mem.startsWith(u8, real_full, real_root)) {
        std.log.warn("Path traversal attempt blocked: '{s}' -> '{s}'", .{ full_path, real_full });
        try res.statusCode(.forbidden).text("Access denied");
        return;
    }

    // 4. 读取文件内容
    const file_content = std.Io.Dir.readFileAlloc(
        cwd_dir,
        self.io,
        real_full,
        self.allocator,
        .unlimited, // 静态文件通常不大，全量读取
    ) catch |file_err| {
        switch (file_err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            error.AccessDenied => try res.statusCode(.forbidden).text("Access denied"),
            else => {
                std.log.err("Failed to read file '{s}': {}", .{ real_full, file_err });
                try res.statusCode(.internal_server_error).text(@errorName(file_err));
            },
        }
        return;
    };
    defer self.allocator.free(file_content);

    // 5. 根据扩展名确定 Content-Type 并响应
    const content_type = getContentType(real_full);

    // 添加缓存头（默认缓存 1 小时）
    try res.header("Cache-Control", "public, max-age=3600");

    try res.file(file_content, content_type);
}

// =========================================================================
// 内部辅助函数
// =========================================================================

/// 安全地去除 URL 前缀，提取相对路径。
///
/// 例如：`stripPrefix("/static/css/a.css")` => `"css/a.css"`
fn stripPrefix(self: *const Self, path: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, path, self.url_prefix)) {
        return null;
    }

    var rest = path[self.url_prefix.len..];

    // 去除紧随前缀的 '/'（例如 "/static" → ""，"/static/" → "/"）
    if (rest.len > 0 and rest[0] == '/') {
        rest = rest[1..];
    }

    return rest;
}

/// 根据文件扩展名返回对应的 MIME 类型。
///
/// 对于未知扩展名，返回 `application/octet-stream`，
/// 强制浏览器以二进制流下载，防止直接渲染敏感内容。
fn getContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);

    // 编译期确定的 MIME 映射表（inline for 在编译期展开为零开销的 if 链）
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

    return "application/octet-stream";
}
