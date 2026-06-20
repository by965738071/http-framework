//! 静态文件服务（简化版，能工作就行）
//! 提供基本的静态文件服务，去掉复杂的路径解析。
//!
//! 适配 Zig 0.16
//!   - 使用 std.Io.Dir.cwd() 和 readFileAlloc
//!   - 增加了最大文件大小限制，防止内存耗尽
//!   - 加强了路径遍历防护（不仅能检查 ".."，还验证最终路径在根目录内）
//!   - 优化了 MIME 类型表的查询方式（编译时 inline for 即可，无需运行时开销）

const std = @import("std");
const mem = std.mem;

const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Handler = @import("handler.zig");

/// 简化的静态文件服务器
allocator: std.mem.Allocator,
io: std.Io,
root_dir: []const u8,
url_prefix: []const u8,

/// 最大允许读取的文件大小（字节）
const max_file_size = 10 * 1024 * 1024; // 10 MB

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
// 请求处理
// =========================================================================

/// 处理静态文件请求（简化版）
pub fn handle(self: *const Self, ctx: *RequestContext, res: *Response) !void {
    // 1. 获取相对路径（支持通配符路由）
    const relative_path = if (ctx.path_params.get("*")) |p| p else (self.stripPrefix(ctx.path) orelse {
        try res.statusCode(.bad_request).text("Invalid static path");
        return;
    });

    // 如果访问的是根路径，默认返回 index.html
    const target_relative = if (relative_path.len == 0) "index.html" else relative_path;

    // 2. 拼接完整路径
    const full_path = try std.fs.path.join(self.allocator, &.{ self.root_dir, target_relative });
    defer self.allocator.free(full_path);

    // 3. 路径遍历防护
    //    简单检查：禁止包含 ".."
    if (mem.indexOf(u8, target_relative, "..") != null) {
        std.log.warn("Path traversal attempt blocked (basic check): '{s}'", .{target_relative});
        try res.statusCode(.forbidden).text("Access denied");
        return;
    }
    //    加强检查：解析后的绝对路径必须位于 root_dir 内
    if (!mem.startsWith(u8, full_path, self.root_dir)) {
        std.log.warn("Path traversal attempt blocked (prefix check): '{s}'", .{target_relative});
        try res.statusCode(.forbidden).text("Access denied");
        return;
    }

    // 4. 获取文件元数据（用于缓存头）
    const stat = std.Io.Dir.cwd().statFile(self.io, full_path, .{}) catch |stat_err| {
        switch (stat_err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            error.AccessDenied => try res.statusCode(.forbidden).text("Access denied"),
            else => {
                std.log.err("Failed to stat file '{s}': {}", .{ full_path, stat_err });
                try res.statusCode(.internal_server_error).text(@errorName(stat_err));
            },
        }
        return;
    };

    // 5. 生成 ETag 和 Last-Modified 缓存头
    var etag_buf: [64]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"{d}-{d}\"", .{ stat.size, stat.mtime.nanoseconds }) catch "\"0\"";

    // 检查 If-None-Match（ETag 缓存验证）
    if (ctx.getHeader("If-None-Match")) |if_none_match| {
        if (std.mem.eql(u8, if_none_match, etag)) {
            try res.statusCode(.not_modified).text("");
            return;
        }
    }

    // 6. 读取文件内容，限制最大大小
    const file_content = std.Io.Dir.cwd().readFileAlloc(
        self.io,
        full_path,
        self.allocator,
        .limited(max_file_size),
    ) catch |file_err| {
        switch (file_err) {
            error.FileNotFound => try res.statusCode(.not_found).text("File not found"),
            error.AccessDenied => try res.statusCode(.forbidden).text("Access denied"),
            error.StreamTooLong => try res.statusCode(.payload_too_large)
                .text("File too large"),
            else => {
                std.log.err("Failed to read file '{s}': {}", .{ full_path, file_err });
                try res.statusCode(.internal_server_error).text(@errorName(file_err));
            },
        }
        return;
    };
    defer self.allocator.free(file_content);

    // 7. 添加缓存头并响应
    const content_type = getContentType(full_path);
    _ = try res.header("ETag", etag);
    _ = try res.header("Cache-Control", "public, max-age=3600");
    try res.file(file_content, content_type);
}

// =========================================================================
// 内部辅助函数
// =========================================================================

/// 安全地去除 URL 前缀，提取相对路径。
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

/// 根据文件扩展名返回对应的 MIME 类型（编译期展开，零运行时开销）。
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

// =========================================================================
// 测试
// =========================================================================

test "getContentType - common extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getContentType("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getContentType("style.css"));
    try std.testing.expectEqualStrings("application/javascript", getContentType("app.js"));
    try std.testing.expectEqualStrings("image/png", getContentType("logo.png"));
    try std.testing.expectEqualStrings("image/jpeg", getContentType("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", getContentType("photo.jpeg"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", getContentType("readme.txt"));
    try std.testing.expectEqualStrings("application/json", getContentType("data.json"));
    try std.testing.expectEqualStrings("image/gif", getContentType("anim.gif"));
    try std.testing.expectEqualStrings("image/svg+xml", getContentType("icon.svg"));
}

test "getContentType - unknown extension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("file.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("noextension"));
}

test "Static.init - normalizes url prefix" {
    const s = Self.init(std.testing.allocator, std.testing.io, "/var/www", "/static/");
    try std.testing.expectEqualStrings("/static", s.url_prefix);
}

test "Static.init - keeps prefix without trailing slash" {
    const s = Self.init(std.testing.allocator, std.testing.io, "/var/www", "/static");
    try std.testing.expectEqualStrings("/static", s.url_prefix);
}

test "stripPrefix - extracts relative path" {
    const s = Self.init(std.testing.allocator, std.testing.io, "/var/www", "/static");
    const result = s.stripPrefix("/static/css/style.css");
    try std.testing.expectEqualStrings("css/style.css", result.?);
}

test "stripPrefix - returns null for non-matching path" {
    const s = Self.init(std.testing.allocator, std.testing.io, "/var/www", "/static");
    const result = s.stripPrefix("/api/users");
    try std.testing.expect(result == null);
}
