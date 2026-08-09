//! 流式**请求体**示例
//!
//! 和 `streaming.zig`（流式响应）相对：这里是请求进来的方向。
//!
//! - `/upload`  用 `ctx.bodyStream()` 边收边算 SHA-256，body 不进内存
//! - `/echo`    先试 `ctx.readBody()`，超过阈值再退回流式
//! - `/discard` 故意不读完 body，演示框架会关掉这条连接
//!
//! # 为什么需要它
//!
//! `ctx.readBody()` 把整个 body 攒进内存，传 1GiB 就吃 1GiB 堆，而且
//! `body_size_limit`（默认 10MiB）会直接把大上传挡在门外。`bodyStream()`
//! 的内存占用只有调用方给的那个缓冲区，多大的上传都是常数内存。
//!
//! `lazy_read_size` 是两者之间的开关：`Content-Length` 超过它，
//! `readBody()` 就不再去读，而是返回 `error.BodyTooLargeToBuffer`
//! 提醒你改用流式——报错时**一个字节都还没消费**，所以还来得及改。
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build && ./zig-out/bin/streaming_upload
//! # 128MiB 上传，服务器内存不会涨
//! head -c 134217728 /dev/urandom | curl -s --data-binary @- http://127.0.0.1:9012/upload
//! ```

const std = @import("std");
pub const http_framework = @import("http_framework");

const RequestContext = http_framework.RequestContext;
const Response = http_framework.Response;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();

    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/", http_framework.Handler.fromFn(indexHandler));
    try router.route(.POST, "/upload", http_framework.Handler.fromFn(uploadHandler));
    try router.route(.POST, "/echo", http_framework.Handler.fromFn(echoHandler));
    try router.route(.POST, "/discard", http_framework.Handler.fromFn(discardHandler));

    var server = try http_framework.Server.init(allocator, init.io, .{
        .port = 9012,
        // 超过 64KiB 的 body 不再整体缓冲，handler 必须走流式
        .lazy_read_size = 64 * 1024,
        // 流式路径下不需要硬上限兜底：内存占用与 body 大小无关
        .body_size_limit = 0,
    }, &router);
    defer server.deinit();

    std.log.info("streaming upload example on http://127.0.0.1:9012", .{});
    try server.run();
}

fn indexHandler(_: *RequestContext, res: *Response) !void {
    try res.html(
        \\<!DOCTYPE html>
        \\<html><body>
        \\<h1>Streaming upload</h1>
        \\<ul>
        \\  <li>POST /upload  &mdash; 流式读体，返回 SHA-256</li>
        \\  <li>POST /echo    &mdash; 小 body 缓冲，大 body 自动退回流式</li>
        \\  <li>POST /discard &mdash; 故意不读完，连接会被关闭</li>
        \\</ul>
        \\</body></html>
    );
}

/// 流式读体：常数内存算完整个 body 的 SHA-256。
fn uploadHandler(ctx: *RequestContext, res: *Response) !void {
    var buf: [64 * 1024]u8 = undefined;
    const reader = try ctx.bodyStream(&buf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [8192]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
        total += n;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // 读完之后请求头依然可用——head 在带 body 时已经复制到请求 arena 了
    const ct = ctx.getHeader("Content-Type") orelse "(none)";

    try res.json(.{
        .bytes = total,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
        .content_type = ct,
        .path = ctx.path,
    });
}

/// 先试缓冲，超阈值再退回流式——把 lazy_read_size 的用法演示完整。
fn echoHandler(ctx: *RequestContext, res: *Response) !void {
    if (ctx.readBody()) |body| {
        try res.json(.{ .mode = "buffered", .bytes = body.len });
        return;
    } else |err| switch (err) {
        // 此时一个字节都还没读，可以无缝改走流式
        error.BodyTooLargeToBuffer => {},
        else => return err,
    }

    var buf: [32 * 1024]u8 = undefined;
    const reader = try ctx.bodyStream(&buf);
    var chunk: [8192]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        total += n;
    }
    try res.json(.{ .mode = "streamed", .bytes = total });
}

/// 开了流却不读完。框架检测到 body 没消费干净，会关掉这条连接，
/// 避免残余字节被当成下一个请求的头部（HTTP 请求走私的经典成因）。
fn discardHandler(ctx: *RequestContext, res: *Response) !void {
    var buf: [1024]u8 = undefined;
    const reader = try ctx.bodyStream(&buf);
    var chunk: [16]u8 = undefined;
    const n = try reader.readSliceShort(&chunk);
    try res.json(.{ .read = n, .note = "connection will be closed" });
}
