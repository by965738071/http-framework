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
        // 修复 D5：去掉 root_dir 尾部 '/'，否则 isPathWithinRoot 的
        // full_path[root_dir.len]=='/' 检查会落到真实文件名字符上。
        var normalized_root = root_dir;
        while (normalized_root.len > 1 and normalized_root[normalized_root.len - 1] == '/') {
            normalized_root = normalized_root[0 .. normalized_root.len - 1];
        }
        return .{
            .allocator = allocator,
            .io = io,
            .root_dir = normalized_root,
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

        // 获取文件元数据。重要：用 ctx.io（当前连接协程的 io），不能用
        // 启动时捕获的 self.io——zio 的 io 绑定协程上下文，跨协程用会挂死。
        var stat = std.Io.Dir.cwd().statFile(ctx.io, full_path, .{}) catch |err| {
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

        // 目录请求：重定向到其下的 index.html。
        var resolved_path = full_path;
        var resolved_ct = getContentType(full_path);
        if (stat.kind == .directory) {
            resolved_path = try std.fs.path.join(ctx.arena, &.{ full_path, "index.html" });
            resolved_ct = getContentType(resolved_path);
            stat = std.Io.Dir.cwd().statFile(ctx.io, resolved_path, .{}) catch {
                _ = res.statusCode(.not_found);
                try res.text("File not found");
                return;
            };
        }
        const content_type = resolved_ct;

        // 修复 D4：符号链接逃逸防护。
        // isPathWithinRoot 只做词法校验，根目录内指向 /etc/passwd 的 symlink
        // 仍会被当作根内文件返回。这里在文件确认存在后，用 realPath 解析真实
        // 路径（跟随所有 symlink），再校验真实路径仍在真实根目录内。
        if (!self.isResolvedPathWithinRoot(ctx.io, resolved_path)) {
            _ = res.statusCode(.forbidden);
            try res.text("Access denied");
            return;
        }

        // ETag —— 叠入 size + mtime（弱验证器已够）
        var etag_buf: [80]u8 = undefined;
        const etag = std.fmt.bufPrint(&etag_buf, "\"{d}-{d}\"", .{
            stat.size,
            stat.mtime.nanoseconds,
        }) catch "\"0\"";

        // Last-Modified（HTTP-date）
        var lm_buf: [40]u8 = undefined;
        const last_modified: ?[]const u8 = formatHttpDate(&lm_buf, stat.mtime.nanoseconds);

        // 条件请求：If-None-Match 优先于 If-Modified-Since。
        const inm_match = if (ctx.request.getHeader("If-None-Match")) |inm| ifNoneMatch(inm, etag) else false;
        const ims_match = if (!inm_match)
            (if (ctx.request.getHeader("If-Modified-Since")) |ims| (last_modified != null and std.mem.eql(u8, ims, last_modified.?)) else false)
        else
            false;

        if (inm_match or ims_match) {
            // 304 仍应携带验证器（RFC 7232 §4.1）。
            _ = try res.header("ETag", etag);
            if (last_modified) |lm| _ = try res.header("Last-Modified", lm);
            _ = try res.header("Cache-Control", "public, max-age=3600");
            _ = res.statusCode(.not_modified);
            try res.text("");
            return;
        }

        _ = try res.header("ETag", etag);
        if (last_modified) |lm| _ = try res.header("Last-Modified", lm);
        _ = try res.header("Cache-Control", "public, max-age=3600");
        _ = try res.header("Accept-Ranges", "bytes");

        // HEAD：只发头，不发 body（RFC 9110 §9.3.2）。
        if (ctx.request.method == .HEAD) {
            _ = try res.header("Content-Type", content_type);
            var clen_buf: [24]u8 = undefined;
            const clen = std.fmt.bufPrint(&clen_buf, "{d}", .{stat.size}) catch "0";
            _ = try res.header("Content-Length", clen);
            _ = res.statusCode(.ok);
            try res.text("");
            return;
        }

        // Range 请求（RFC 9110 §14.2）：仅支持单一 `bytes=a-b` 区间。
        // Range 与 gzip 不同时做（范围针对 identity 表示）。
        if (ctx.request.getHeader("Range")) |range_hdr| {
            if (parseByteRange(range_hdr, stat.size)) |rng| {
                return self.serveRange(ctx, res, resolved_path, stat.size, content_type, rng);
            } else {
                // 不可满足的范围 → 416 + Content-Range: bytes */size
                var cr_buf: [48]u8 = undefined;
                const cr = std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{stat.size}) catch "bytes */0";
                _ = try res.header("Content-Range", cr);
                _ = res.statusCode(.range_not_satisfiable);
                try res.text("Range Not Satisfiable");
                return;
            }
        }

        // 修复 fix.md 架构缺陷 #2：流式响应绕过缓冲中间件 → 压缩失效。
        // 在 StaticFileServer 内部检测 Accept-Encoding，对可压缩的大文件
        // 直接用 gzip 流式编码。
        const accept_encoding = ctx.request.getHeader("accept-encoding") orelse "";
        const use_gzip = blk: {
            if (stat.size < 1024) break :blk false; // 太小不值得
            if (!http_compress.shouldCompressContentType(content_type, http_compress.default_skip_types)) break :blk false;
            const enc = http_compress.chooseEncoding(accept_encoding, &.{.gzip}) orelse break :blk false;
            break :blk enc == .gzip;
        };

        // 大文件流式响应
        if (stat.size > MAX_BUFFERED_SIZE) {
            const file = std.Io.Dir.cwd().openFile(ctx.io, resolved_path, .{}) catch |err| {
                _ = res.statusCode(.internal_server_error);
                try res.text(@errorName(err));
                return;
            };
            defer file.close(ctx.io);

            if (use_gzip) {
                // gzip 流式压缩：Content-Length 未知（压缩后大小不确定）
                _ = try res.header("Content-Encoding", "gzip");
                _ = try res.header("Vary", "Accept-Encoding");
                var stream_buf: [8192]u8 = undefined;
                var stream = try res.stream(&stream_buf, .{
                    .content_length = null,
                    .content_type = content_type,
                });

                // flate.Compress 是 ~224KB 的巨型 struct，hist_buf 64KB，都必须堆分配：
                // 放在 zio 协程栈上会溢出 guard page 崩溃（与 compress() 同根因）。
                const hist_buf = try ctx.arena.alloc(u8, std.compress.flate.max_window_len);
                const encoder = try ctx.arena.create(std.compress.flate.Compress);
                http_compress.initStreamingEncoder(
                    encoder,
                    stream.writer(),
                    hist_buf,
                    .gzip,
                    .default,
                ) catch {
                    try stream.end();
                    return;
                };

                var file_read_buf: [16 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (offset < stat.size) {
                    const to_read = @min(file_read_buf.len, stat.size - offset);
                    const bufs: []const []u8 = &.{file_read_buf[0..to_read]};
                    // 读错直接传播，不静默截断（否则 Content-Length 不符 / 连接错帧）。
                    const n = try file.readPositional(ctx.io, bufs, offset);
                    if (n == 0) break;
                    try encoder.writer.writeAll(file_read_buf[0..n]);
                    try stream.flush();
                    offset += n;
                }
                try encoder.finish();
                try stream.end();
            } else {
                // 不压缩的直接流式。
                // 修复 D6：旧代码用 stat.size 作 content_length，但文件可能在 stat 之后
                // 被并发截断，短读 break 后发送字节少于声明→content-length 不符
                // → keep-alive 连接错帧（Debug 下还会触 endUnflushed 的 len==0 断言）。
                // 改用 chunked（content_length=null），无论实际读到多少都能正确成帧。
                var stream_buf: [8192]u8 = undefined;
                var stream = try res.stream(&stream_buf, .{
                    .content_length = null,
                    .content_type = content_type,
                });

                var file_read_buf: [16 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (offset < stat.size) {
                    const to_read = @min(file_read_buf.len, stat.size - offset);
                    const bufs: []const []u8 = &.{file_read_buf[0..to_read]};
                    const n = try file.readPositional(ctx.io, bufs, offset);
                    if (n == 0) break;
                    try stream.writeAll(file_read_buf[0..n]);
                    offset += n;
                }
                try stream.end();
            }
        } else {
            // 小文件：整体读入内存
            const file_content = std.Io.Dir.cwd().readFileAlloc(
                ctx.io,
                resolved_path,
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

    /// 已解析的字节区间（包含 start..end）。
    const ByteRange = struct { start: u64, end: u64 };

    /// 响应单一字节区间：206 + Content-Range，流式发范围内字节。
    fn serveRange(
        self: *const StaticFileServer,
        ctx: *Context,
        res: *Response,
        path: []const u8,
        total: u64,
        content_type: []const u8,
        rng: ByteRange,
    ) !void {
        _ = self;
        const len = rng.end - rng.start + 1;

        var cr_buf: [64]u8 = undefined;
        const cr = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ rng.start, rng.end, total }) catch "";
        _ = try res.header("Content-Range", cr);

        const file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            _ = res.statusCode(.internal_server_error);
            try res.text(@errorName(err));
            return;
        };
        defer file.close(ctx.io);

        _ = res.statusCode(.partial_content);
        var stream_buf: [8192]u8 = undefined;
        var stream = try res.stream(&stream_buf, .{
            .content_length = len,
            .content_type = content_type,
        });

        var file_read_buf: [16 * 1024]u8 = undefined;
        var offset: u64 = rng.start;
        var remaining: u64 = len;
        while (remaining > 0) {
            const to_read = @min(file_read_buf.len, remaining);
            const bufs: []const []u8 = &.{file_read_buf[0..to_read]};
            const n = try file.readPositional(ctx.io, bufs, offset);
            if (n == 0) break;
            try stream.writeAll(file_read_buf[0..n]);
            offset += n;
            remaining -= n;
        }
        try stream.end();
    }

    fn stripPrefix(self: *const StaticFileServer, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, self.url_prefix)) return null;
        var rest = path[self.url_prefix.len..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        return rest;
    }

    /// 修复 D4：解析后的真实路径（跟随 symlink）必须仍在真实根目录内。
    /// 用 realPathFile 解析 root 与目标文件，再做词法前缀校验。
    /// 解析失败（如平台不支持）保守拒绝（返回 false）。
    fn isResolvedPathWithinRoot(self: *const StaticFileServer, io: std.Io, path: []const u8) bool {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_n = std.Io.Dir.cwd().realPathFile(io, self.root_dir, &root_buf) catch return false;
        const file_n = std.Io.Dir.cwd().realPathFile(io, path, &file_buf) catch return false;
        return isPathWithinRoot(file_buf[0..file_n], root_buf[0..root_n]);
    }
};

/// 解析 `Range: bytes=a-b` 头（单一区间），返回包含区间 [start, end]。
/// 支持：`bytes=0-499`、`bytes=500-`（到末尾）、`bytes=-500`（最后 500 字节）。
/// 不可满足（越界/格式错/多区间）返回 null（调用方回 416）。
fn parseByteRange(header: []const u8, size: u64) ?StaticFileServer.ByteRange {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, header, prefix)) return null;
    const spec = header[prefix.len..];
    // 多区间（含 `,`）不支持，返回 null。
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_str = std.mem.trim(u8, spec[0..dash], " \t");
    const end_str = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    if (size == 0) return null;

    if (start_str.len == 0) {
        // 后缀形式 `-N`：最后 N 字节。
        const n = std.fmt.parseInt(u64, end_str, 10) catch return null;
        if (n == 0) return null;
        const start = if (n >= size) 0 else size - n;
        return .{ .start = start, .end = size - 1 };
    }

    const start = std.fmt.parseInt(u64, start_str, 10) catch return null;
    if (start >= size) return null; // 起点越界 → 416
    const end = if (end_str.len == 0)
        size - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_str, 10) catch return null;
        break :blk @min(e, size - 1);
    };
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

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
    const ext_raw = std.fs.path.extension(path);
    // 小写化后比较（大小写不敏感：PHOTO.JPG 也能识别）。
    var buf: [16]u8 = undefined;
    if (ext_raw.len == 0 or ext_raw.len > buf.len) return "application/octet-stream";
    const ext = std.ascii.lowerString(buf[0..ext_raw.len], ext_raw);
    const type_map = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".wasm", "application/wasm" },
        .{ ".map", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".svg", "image/svg+xml; charset=utf-8" },
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

/// If-None-Match 匹配：支持 `*`、逗号列表、弱验证器 `W/` 前缀（RFC 7232 §3.2）。
fn ifNoneMatch(header: []const u8, etag: []const u8) bool {
    const trimmed = std.mem.trim(u8, header, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var it = std.mem.splitScalar(u8, header, ',');
    while (it.next()) |raw| {
        var t = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, t, "W/")) t = t[2..];
        var e = etag;
        if (std.mem.startsWith(u8, e, "W/")) e = e[2..];
        if (std.mem.eql(u8, t, e)) return true;
    }
    return false;
}

/// 把纳秒级 Unix 时间戳格式化为 HTTP-date（导出供诊断用）。
pub fn formatHttpDateForTest(buf: []u8, mtime_ns: i128) ?[]const u8 {
    return formatHttpDate(buf, mtime_ns);
}

/// 把纳秒级 Unix 时间戳格式化为 HTTP-date（IMF-fixdate，RFC 9110 §5.6.7）。
/// 失败时返回 null（调用方自行省略 Last-Modified）。
fn formatHttpDate(buf: []u8, mtime_ns: i128) ?[]const u8 {
    if (mtime_ns <= 0) return null;
    const secs: u64 = @intCast(@divTrunc(mtime_ns, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const weekday = @mod(ed.day + 4, 7); // 1970-01-01 是周四(4)
    const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wdays[weekday],
        md.day_index + 1,
        months[md.month.numeric() - 1],
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "getContentType" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getContentType("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getContentType("style.css"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", getContentType("app.js"));
    try std.testing.expectEqualStrings("image/png", getContentType("logo.png"));
    try std.testing.expectEqualStrings("application/wasm", getContentType("mod.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("unknown.xyz"));
    // 大小写不敏感
    try std.testing.expectEqualStrings("image/jpeg", getContentType("PHOTO.JPG"));
}

test "ifNoneMatch" {
    try std.testing.expect(ifNoneMatch("*", "\"abc\""));
    try std.testing.expect(ifNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatch("\"x\", \"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(!ifNoneMatch("\"other\"", "\"abc\""));
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

test "parseByteRange" {
    const R = StaticFileServer.ByteRange;
    // 完整区间
    try std.testing.expectEqual(R{ .start = 0, .end = 499 }, parseByteRange("bytes=0-499", 1000).?);
    // 开放结尾 → 到最后
    try std.testing.expectEqual(R{ .start = 500, .end = 999 }, parseByteRange("bytes=500-", 1000).?);
    // 后缀：最后 500 字节
    try std.testing.expectEqual(R{ .start = 500, .end = 999 }, parseByteRange("bytes=-500", 1000).?);
    // end 越界 → 截到 size-1
    try std.testing.expectEqual(R{ .start = 0, .end = 999 }, parseByteRange("bytes=0-5000", 1000).?);
    // start 越界 → 不可满足
    try std.testing.expect(parseByteRange("bytes=1000-", 1000) == null);
    // 多区间不支持
    try std.testing.expect(parseByteRange("bytes=0-1,2-3", 1000) == null);
    // 格式错
    try std.testing.expect(parseByteRange("items=0-1", 1000) == null);
    // 空文件
    try std.testing.expect(parseByteRange("bytes=0-0", 0) == null);
}

test {
    std.testing.refAllDecls(@This());
}
