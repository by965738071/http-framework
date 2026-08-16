//! http_compress — 响应压缩中间件（依赖 http_app, http_protocol）
//!
//! 支持 gzip / deflate（基于 std.compress.flate）。
//!
//! 工作原理：
//! 1. 检查 Accept-Encoding 头
//! 2. 如果客户端接受 gzip/deflate，启用缓冲模式
//! 3. 调用 next()（handler 产生响应）
//! 4. 在 flush 之前压缩 pending_body
//! 5. 设置 Content-Encoding + Vary 头
//!
//! 跳过条件（不压缩）：
//! - 响应未设置 body
//! - body 太小（< min_size，默认 1KB，压缩反而变大）
//! - Content-Type 不可压缩（image/*, video/*, application/zip 等）
//! - 响应已经设置了 Content-Encoding

const std = @import("std");
const flate = std.compress.flate;
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Context = http_app.Context;
pub const Response = http_protocol.Response;
pub const Next = http_app.Next;

pub const Encoding = enum {
    gzip,
    deflate,

    pub fn headerValue(self: Encoding) []const u8 {
        return switch (self) {
            .gzip => "gzip",
            .deflate => "deflate",
        };
    }

    pub fn toContainer(self: Encoding) flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .zlib, // deflate 在 HTTP 语境里实际是 zlib 格式
        };
    }
};

pub const CompressConfig = struct {
    /// 最小压缩 body 大小（字节）。小于此值不压缩。
    min_size: usize = 1024,
    /// 压缩等级（1=最快, 6=默认, 9=最佳）
    level: flate.Compress.Options = .default,
    /// 支持的编码（按优先级）
    encodings: []const Encoding = &.{ .gzip, .deflate },
    /// 不压缩的 Content-Type 前缀列表
    skip_content_types: []const []const u8 = &.{
        "image/",
        "video/",
        "audio/",
        "application/zip",
        "application/gzip",
        "application/x-gzip",
        "application/x-bzip2",
        "application/x-xz",
        "application/octet-stream",
    },
};

/// 响应压缩中间件。
///
/// 用法：
/// ```zig
/// var compress_mw = CompressMiddleware{ .config = .{} };
/// router.use(Middleware.init(CompressMiddleware, &compress_mw));
/// ```
pub const CompressMiddleware = struct {
    config: CompressConfig = .{},

    const Self = @This();

    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        const accept = ctx.request.getHeader("accept-encoding") orelse {
            return next.call(ctx, res);
        };

        // 选择编码
        const encoding = chooseEncoding(accept, self.config.encodings) orelse {
            return next.call(ctx, res);
        };

        // 启用缓冲模式——让 handler 的响应延迟到我们压缩之后
        res.setBuffered();

        // Vary: Accept-Encoding（让缓存正确处理）
        _ = res.header("Vary", "Accept-Encoding") catch {};

        try next.call(ctx, res);

        // 检查是否有 pending body 需要压缩
        const body = res.pendingBody() orelse {
            try res.flush();
            return;
        };
        if (body.len == 0) {
            try res.flush();
            return;
        }

        // 跳过条件：太小
        if (body.len < self.config.min_size) {
            try res.flush();
            return;
        }

        // 跳过条件：已有 Content-Encoding
        if (hasHeader(res, "content-encoding")) {
            try res.flush();
            return;
        }

        // 跳过条件：Content-Type 不可压缩
        if (!shouldCompress(res)) {
            try res.flush();
            return;
        }

        // 压缩
        const compressed = compress(ctx.arena, body, encoding, self.config.level) catch {
            // 压缩失败，发送原始 body
            try res.flush();
            return;
        };

        // 只有压缩后更小才替换
        if (compressed.len < body.len) {
            _ = res.replacePendingBody(compressed);
            _ = res.header("Content-Encoding", encoding.headerValue()) catch {};
        }

        try res.flush();
    }
};

/// 根据 Accept-Encoding 头选择编码。
pub fn chooseEncoding(accept: []const u8, supported: []const Encoding) ?Encoding {
    for (supported) |enc| {
        if (std.mem.indexOf(u8, accept, enc.headerValue()) != null) {
            return enc;
        }
    }
    return null;
}

/// 检查 Content-Type 是否可压缩。
pub fn shouldCompressContentType(content_type: []const u8) bool {
    for (skip_types) |prefix| {
        if (std.mem.startsWith(u8, content_type, prefix)) return false;
    }
    return true;
}

/// 检查 Response 是否已有某个头（大小写不敏感）。
fn hasHeader(res: *const Response, name: []const u8) bool {
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

/// 检查 Content-Type 是否可压缩。
fn shouldCompress(res: *const Response) bool {
    var ct: ?[]const u8 = null;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            ct = h.value;
            break;
        }
    }
    const content_type = ct orelse return true; // 无 CT 默认压缩
    return shouldCompressContentType(content_type);
}

const skip_types = &[_][]const u8{
    "image/",
    "video/",
    "audio/",
    "application/zip",
    "application/gzip",
    "application/x-gzip",
    "application/x-bzip2",
    "application/x-xz",
    "application/octet-stream",
};

/// 压缩 body，返回 arena 分配的压缩字节。
fn compress(allocator: std.mem.Allocator, body: []const u8, encoding: Encoding, level: flate.Compress.Options) ![]const u8 {
    // 用 ArrayList 做输出缓冲——Compress.init 要求 output.buffer.len > 8
    var out_list = std.ArrayList(u8).empty;
    defer out_list.deinit(allocator);
    // 预分配足够容量
    try out_list.ensureTotalCapacity(allocator, body.len + 64);
    var out_writer = std.Io.Writer.fixed(out_list.allocatedSlice());

    var hist_buf: [flate.max_window_len]u8 = undefined;
    var encoder = try flate.Compress.init(&out_writer, &hist_buf, encoding.toContainer(), level);
    try encoder.writer.writeAll(body);
    try encoder.finish();

    // 复制实际写入的字节到 arena
    const written = out_writer.buffered();
    return try allocator.dupe(u8, written);
}

/// 初始化流式 gzip/deflate 编码器，包装一个 writer。
/// 用于流式响应（res.stream()）场景，弥补缓冲中间件模型的缺陷
/// （回应 fix.md 架构缺陷 #2：流式响应绕过缓冲模式 → 压缩失效）。
///
/// `hist_buf` 必须由调用方提供（栈数组），生命周期需覆盖编码器使用期。
///
/// 使用方式：
/// ```zig
/// var hist_buf: [flate.max_window_len]u8 = undefined;
/// var encoder = try http_compress.initStreamingEncoder(
///     stream.writer(), &hist_buf, .gzip, .default,
/// );
/// try encoder.writer.writeAll(file_data);
/// try encoder.finish();
/// ```
pub fn initStreamingEncoder(
    out: *std.Io.Writer,
    hist_buf: *[flate.max_window_len]u8,
    encoding: Encoding,
    level: flate.Compress.Options,
) !flate.Compress {
    return try flate.Compress.init(out, hist_buf, encoding.toContainer(), level);
}

// ===========================================================================
// Tests
// ===========================================================================

test "chooseEncoding selects gzip when accepted" {
    const enc = chooseEncoding("gzip, deflate, br", &.{ .gzip, .deflate }).?;
    try std.testing.expectEqual(Encoding.gzip, enc);
}

test "chooseEncoding selects deflate when only deflate accepted" {
    const enc = chooseEncoding("deflate", &.{ .gzip, .deflate }).?;
    try std.testing.expectEqual(Encoding.deflate, enc);
}

test "chooseEncoding returns null when no supported encoding" {
    try std.testing.expect(chooseEncoding("br", &.{ .gzip, .deflate }) == null);
}

test "compress and decompress roundtrip with gzip" {
    const allocator = std.testing.allocator;
    // 准备可压缩的重复数据
    var data_buf: [600]u8 = undefined;
    var data_writer = std.Io.Writer.fixed(&data_buf);
    for (0..10) |_| {
        data_writer.writeAll("Hello, world! This is a test of gzip compression. ") catch unreachable;
    }
    const repeated_data = data_buf[0..data_writer.end];

    const compressed = try compress(allocator, repeated_data, .gzip, .default);
    defer allocator.free(compressed);

    // 解压验证
    var decompressed = std.ArrayList(u8).empty;
    defer decompressed.deinit(allocator);

    var hist_buf: [flate.max_window_len]u8 = undefined;
    var reader: std.Io.Reader = .fixed(compressed);
    var decompress: flate.Decompress = .init(&reader, .gzip, &hist_buf);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = decompress.reader.streamRemaining(&out.writer) catch {};
    try decompressed.appendSlice(allocator, out.written());

    try std.testing.expectEqualStrings(repeated_data, decompressed.items);
}

test "compress small data might not compress well but doesn't crash" {
    const allocator = std.testing.allocator;
    const data = "hi";

    const compressed = try compress(allocator, data, .gzip, .default);
    defer allocator.free(compressed);
    // 压缩后可能更大，但不应该崩溃
    try std.testing.expect(compressed.len > 0);
}

test {
    std.testing.refAllDecls(@This());
}
