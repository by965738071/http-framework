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
        if (!shouldCompress(res, self.config.skip_content_types)) {
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
/// 修复 F7：按 token 解析并尊重 q=0（显式拒绝），避免 `gzip;q=0` 仍选 gzip、
/// 以及 `x-gzip` 之类子串误匹配。
pub fn chooseEncoding(accept: []const u8, supported: []const Encoding) ?Encoding {
    for (supported) |enc| {
        if (acceptsEncoding(accept, enc.headerValue())) return enc;
    }
    return null;
}

/// 在 Accept-Encoding 列表里查找某个 token，返回它是否被接受（q!=0）。
fn acceptsEncoding(accept: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, accept, ',');
    while (it.next()) |raw| {
        var part = std.mem.trim(u8, raw, " \t");
        // 拆出 coding 与参数（q 值）
        var q_zero = false;
        if (std.mem.indexOfScalar(u8, part, ';')) |semi| {
            const params = part[semi + 1 ..];
            part = std.mem.trim(u8, part[0..semi], " \t");
            // 查找 q=0（允许 q=0, q=0.0 等）
            if (std.mem.indexOf(u8, params, "q=")) |qi| {
                const qval = std.mem.trim(u8, params[qi + 2 ..], " \t");
                if (parseQZero(qval)) q_zero = true;
            }
        }
        if (std.ascii.eqlIgnoreCase(part, token)) return !q_zero;
    }
    return false;
}

/// 判断 q 值字符串是否等价于 0（如 "0", "0.0", "0.00"）。
fn parseQZero(qval: []const u8) bool {
    const v = std.fmt.parseFloat(f32, qval) catch return false;
    return v == 0;
}

/// 检查 Content-Type 是否可压缩（对照给定的 skip 前缀列表）。
pub fn shouldCompressContentType(content_type: []const u8, skip_list: []const []const u8) bool {
    for (skip_list) |prefix| {
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

/// 检查 Response 是否可压缩（修复 F8：使用配置的 skip_content_types 而非模块常量）。
fn shouldCompress(res: *const Response, skip_list: []const []const u8) bool {
    var ct: ?[]const u8 = null;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            ct = h.value;
            break;
        }
    }
    const content_type = ct orelse return true; // 无 CT 默认压缩
    return shouldCompressContentType(content_type, skip_list);
}

/// 默认不压缩的 Content-Type 前缀列表（供 static 等无自定义配置的调用方使用）。
pub const default_skip_types = &[_][]const u8{
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
    // 修复 F12：用会动态增长的 Allocating writer 作为输出缓冲，避免旧的
    // 固定 `body.len + 64` 缓冲在不可压缩输入膨胀超 64 字节时写失败。
    // 预分配 body.len + 64 作为常见情况的初始容量，超出时自动 grow。
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, body.len + 64);
    defer out.deinit();

    // history window 必须 ≥ max_window_len (64KB)。堆分配，避开大栈帧。
    const hist_buf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(hist_buf);

    // flate.Compress 本体是 ~224KB 的巨型 struct（128K lookup + 96K tokens）。
    // 若用 `var encoder = try Compress.init(...)` 放栈上，在 zio 协程（约
    // 256KB 提交栈）里会直接溢出到 guard page，触发 zio 栈增长 fault
    // 处理路径崩溃/死循环（表现为请求挂起、WriteFailed/EFAULT）。
    // 改为堆分配，避开超大栈帧。
    const encoder = try allocator.create(flate.Compress);
    defer allocator.destroy(encoder);
    encoder.* = try flate.Compress.init(&out.writer, hist_buf, encoding.toContainer(), level);
    try encoder.writer.writeAll(body);
    try encoder.finish();

    // 复制实际写入的字节到 arena（out 的 buffer 由 defer 释放）。
    return try allocator.dupe(u8, out.written());
}

/// 初始化流式 gzip/deflate 编码器,写入 `encoder`(由调用方堆分配)。
/// 用于流式响应(res.stream())场景,弥补缓冲中间件模型的缺陷
/// (回应 fix.md 架构缺陷 #2:流式响应绕过缓冲模式 → 压缩失效)。
///
/// **重要**:`flate.Compress` 是 ~224KB 的巨型 struct。必须由调用方
/// `allocator.create(flate.Compress)` 堆分配后把指针传进来,**不能**放在
/// zio 协程栈上(会溢出 guard page 崩溃——见 compress() 的注释)。
/// `hist_buf` 长度必须 ≥ flate.max_window_len,同样建议堆分配。
///
/// 使用方式:
/// ```zig
/// const hist_buf = try allocator.alloc(u8, flate.max_window_len);
/// defer allocator.free(hist_buf);
/// const encoder = try allocator.create(flate.Compress);
/// defer allocator.destroy(encoder);
/// try http_compress.initStreamingEncoder(encoder, stream.writer(), hist_buf, .gzip, .default);
/// try encoder.writer.writeAll(file_data);
/// try encoder.finish();
/// ```
pub fn initStreamingEncoder(
    encoder: *flate.Compress,
    out: *std.Io.Writer,
    hist_buf: []u8,
    encoding: Encoding,
    level: flate.Compress.Options,
) !void {
    encoder.* = try flate.Compress.init(out, hist_buf, encoding.toContainer(), level);
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
