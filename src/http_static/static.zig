//! 静态文件服务 — 迁移到新架构
//!
//! 修复 bug.md Part 2 P2：
//! - 路径遍历防护：检查 full_path[root_dir.len] == '/'
//!   （旧代码只用 startsWith，root="/foo" 能匹配 "/foobar/../../etc/passwd"）
//! - 大文件流式响应：用 res.stream() 而非整体读入内存

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");
const http_compress = @import("http_compress");

const Context = http_app.Context;
const Response = http_protocol.Response;

/// 最大允许整体读入内存的文件大小（超过此大小则流式响应）
const MAX_BUFFERED_SIZE = 1 * 1024 * 1024; // 1 MB

pub const StaticFileServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    url_prefix: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: []const u8,
        url_prefix: []const u8,
    ) StaticFileServer {
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

    /// 静态文件 handler
    pub fn handle(self: *const StaticFileServer, ctx: *Context, res: *Response) !void {
        const relative_path = if (ctx.param("*")) |p| p else (self.stripPrefix(ctx.request.path) orelse {
            _ = res.statusCode(.bad_request);
            try res.text("Invalid static path");
            return;
        });

        const target = if (relative_path.len == 0) "index.html" else relative_path;

        // 基本检查：禁止 ".."
        if (std.mem.indexOf(u8, target, "..") != null) {
            _ = res.statusCode(.forbidden);
            try res.text("Access denied");
            return;
        }

        const full_path = try std.fs.path.join(ctx.arena, &.{ self.root_dir, target });

        // 修复 P2：路径遍历防护加强
        // 旧代码只用 startsWith(root_dir)，root="/foo" 能匹配 "/foobar/../../etc/passwd"
        // 修复：检查 full_path 紧跟 root_dir 之后的是 '/' 或 exactly root_dir
        if (!isPathWithinRoot(full_path, self.root_dir)) {
            _ = res.statusCode(.forbidden);
            try res.text("Access denied");
            return;
        }

        // 获取文件元数据
        const stat = std.Io.Dir.cwd().statFile(self.io, full_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    _ = res.statusCode(.not_found);
                    try res.text("File not found");
                },
                error.AccessDenied => {
                    _ = res.statusCode(.forbidden);
                    try res.text("Access denied");
                },
                else => {
                    _ = res.statusCode(.internal_server_error);
                    try res.text(@errorName(err));
                },
            }
            return;
        };

        // ETag
        var etag_buf: [64]u8 = undefined;
        const etag = std.fmt.bufPrint(&etag_buf, "\"{d}-{d}\"", .{
            stat.size,
            stat.mtime.nanoseconds,
        }) catch "\"0\"";

        // If-None-Match 缓存验证
        if (ctx.request.getHeader("If-None-Match")) |if_none_match| {
            if (std.mem.eql(u8, if_none_match, etag)) {
                _ = res.statusCode(.not_modified);
                try res.text("");
                return;
            }
        }

        const content_type = getContentType(full_path);
        _ = try res.header("ETag", etag);
        _ = try res.header("Cache-Control", "public, max-age=3600");

        // 修复 fix.md 架构缺陷 #2：流式响应绕过缓冲中间件 → 压缩失效。
        // 在 StaticFileServer 内部检测 Accept-Encoding，对可压缩的大文件
        // 直接用 gzip 流式编码。
        const accept_encoding = ctx.request.getHeader("accept-encoding") orelse "";
        const use_gzip = blk: {
            if (stat.size < 1024) break :blk false; // 太小不值得
            if (!http_compress.shouldCompressContentType(content_type)) break :blk false;
            const enc = http_compress.chooseEncoding(accept_encoding, &.{.gzip}) orelse break :blk false;
            break :blk enc == .gzip;
        };

        // 修复 P2：大文件流式响应
        if (stat.size > MAX_BUFFERED_SIZE) {
            const file = std.Io.Dir.cwd().openFile(self.io, full_path, .{}) catch |err| {
                _ = res.statusCode(.internal_server_error);
                try res.text(@errorName(err));
                return;
            };
            defer file.close(self.io);

            if (use_gzip) {
                // gzip 流式压缩：Content-Length 未知（压缩后大小不确定）
                _ = try res.header("Content-Encoding", "gzip");
                _ = try res.header("Vary", "Accept-Encoding");
                var stream_buf: [8192]u8 = undefined;
                var stream = try res.stream(&stream_buf, .{
                    .content_length = null,
                    .content_type = content_type,
                });

                var hist_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var encoder = http_compress.initStreamingEncoder(
                    stream.writer(),
                    &hist_buf,
                    .gzip,
                    .default,
                ) catch {
                    // 压缩初始化失败，降级为不压缩
                    try stream.end();
                    return;
                };

                var file_read_buf: [16 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (offset < stat.size) {
                    const to_read = @min(file_read_buf.len, stat.size - offset);
                    const bufs: []const []u8 = &.{file_read_buf[0..to_read]};
                    const n = file.readPositional(self.io, bufs, offset) catch break;
                    if (n == 0) break;
                    try encoder.writer.writeAll(file_read_buf[0..n]);
                    try stream.flush();
                    offset += n;
                }
                try encoder.finish();
                try stream.end();
            } else {
                // 不压缩的直接流式
                var stream_buf: [8192]u8 = undefined;
                var stream = try res.stream(&stream_buf, .{
                    .content_length = stat.size,
                    .content_type = content_type,
                });

                var file_read_buf: [16 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (offset < stat.size) {
                    const to_read = @min(file_read_buf.len, stat.size - offset);
                    const bufs: []const []u8 = &.{file_read_buf[0..to_read]};
                    const n = file.readPositional(self.io, bufs, offset) catch break;
                    if (n == 0) break;
                    try stream.writeAll(file_read_buf[0..n]);
                    offset += n;
                }
                try stream.end();
            }
        } else {
            // 小文件：整体读入内存
            const file_content = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                full_path,
                ctx.arena,
                .limited(MAX_BUFFERED_SIZE),
            ) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        _ = res.statusCode(.not_found);
                        try res.text("File not found");
                    },
                    error.StreamTooLong => {
                        _ = res.statusCode(.payload_too_large);
                        try res.text("File too large");
                    },
                    else => {
                        _ = res.statusCode(.internal_server_error);
                        try res.text(@errorName(err));
                    },
                }
                return;
            };

            try res.statusCode(.ok).raw(file_content, content_type);
        }
    }

    fn stripPrefix(self: *const StaticFileServer, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, self.url_prefix)) return null;
        var rest = path[self.url_prefix.len..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        return rest;
    }
};

/// 修复 P2：路径遍历防护
/// 检查 full_path 要么等于 root_dir，要么紧跟 root_dir 后面是 '/'。
/// 这样 root="/foo" 不会匹配 "/foobar/../../etc/passwd"。
fn isPathWithinRoot(full_path: []const u8, root_dir: []const u8) bool {
    if (full_path.len < root_dir.len) return false;
    if (!std.mem.eql(u8, full_path[0..root_dir.len], root_dir)) return false;
    if (full_path.len == root_dir.len) return true;
    // 紧跟 root_dir 之后必须是路径分隔符
    return full_path[root_dir.len] == '/';
}

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
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

// ===========================================================================
// Tests
// ===========================================================================

test "getContentType" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getContentType("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getContentType("style.css"));
    try std.testing.expectEqualStrings("application/javascript", getContentType("app.js"));
    try std.testing.expectEqualStrings("image/png", getContentType("logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("unknown.xyz"));
}

test "isPathWithinRoot - exact match" {
    try std.testing.expect(isPathWithinRoot("/var/www", "/var/www"));
}

test "isPathWithinRoot - valid subpath" {
    try std.testing.expect(isPathWithinRoot("/var/www/index.html", "/var/www"));
    try std.testing.expect(isPathWithinRoot("/var/www/subdir/file.txt", "/var/www"));
}

test "isPathWithinRoot - blocks traversal (prefix match without separator)" {
    // 修复 P2：root="/foo" 不应匹配 "/foobar/../../etc/passwd"
    try std.testing.expect(!isPathWithinRoot("/foobar/../../etc/passwd", "/foo"));
    try std.testing.expect(!isPathWithinRoot("/foobar", "/foo"));
}

test "isPathWithinRoot - shorter path rejected" {
    try std.testing.expect(!isPathWithinRoot("/var", "/var/www"));
}

test "isPathWithinRoot - different root rejected" {
    try std.testing.expect(!isPathWithinRoot("/etc/passwd", "/var/www"));
}

test {
    std.testing.refAllDecls(@This());
}
