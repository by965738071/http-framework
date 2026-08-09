//! 流式响应示例
//!
//! 演示 `res.stream()`：响应体不整个进内存，边生成边发。
//!
//! - `/download`  chunked 大文件下载（长度未知）
//! - `/report`    定长流（提前算得出 Content-Length）
//! - `/events`    Server-Sent Events
//! - `/rows`      流式 JSON 数组
//!
//! # 与普通响应的区别
//!
//! `res.text()` / `res.json()` 要求整个响应体先在内存里备好。生成 100MB
//! 报表就要占 100MB 堆。`res.stream()` 只需要一个调用方自备的小缓冲区
//! （下面都用 4KiB 栈数组），全程零堆分配。
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build && ./zig-out/bin/streaming
//! curl -N http://127.0.0.1:9010/events
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
    const io = init.io;

    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/", http_framework.Handler.fromFn(indexHandler));
    try router.route(.GET, "/download", http_framework.Handler.fromFn(downloadHandler));
    try router.route(.GET, "/report", http_framework.Handler.fromFn(reportHandler));
    try router.route(.GET, "/events", http_framework.Handler.fromFn(eventsHandler));
    try router.route(.GET, "/rows", http_framework.Handler.fromFn(rowsHandler));

    var server = try http_framework.Server.init(allocator, io, .{ .port = 9010 }, &router);
    defer server.deinit();

    std.log.info("streaming example on http://127.0.0.1:9010", .{});
    try server.run();
}

fn indexHandler(_: *RequestContext, res: *Response) !void {
    try res.html(
        \\<!DOCTYPE html>
        \\<html><body>
        \\<h1>Streaming examples</h1>
        \\<ul>
        \\  <li><a href="/download">/download</a> — chunked，长度未知</li>
        \\  <li><a href="/report">/report</a> — 定长流</li>
        \\  <li><a href="/events">/events</a> — SSE</li>
        \\  <li><a href="/rows">/rows</a> — 流式 JSON 数组</li>
        \\</ul>
        \\</body></html>
    );
}

/// chunked 下载：总长度事先不知道，交给 Transfer-Encoding: chunked。
fn downloadHandler(_: *RequestContext, res: *Response) !void {
    var buf: [4096]u8 = undefined;
    var s = try res.statusCode(.ok).stream(&buf, .{
        .content_type = "text/plain; charset=utf-8",
    });

    // HEAD 请求下响应体会被丢弃，这里可以省掉生成开销
    if (!s.isEliding()) {
        for (0..10_000) |i| {
            try s.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
        }
    }

    try s.end();
}

/// 定长流：长度算得出来就给 Content-Length，客户端能显示进度条。
///
/// 注意 content_length 必须和实际写入字节数完全一致，否则 `end()` 会断言失败。
fn reportHandler(_: *RequestContext, res: *Response) !void {
    const line = "row placeholder\n";
    const rows = 500;

    var buf: [4096]u8 = undefined;
    var s = try res.statusCode(.ok).stream(&buf, .{
        .content_length = line.len * rows,
        .content_type = "text/plain; charset=utf-8",
    });

    if (!s.isEliding()) {
        for (0..rows) |_| try s.writeAll(line);
    }

    try s.end();
}

/// Server-Sent Events。
///
/// 关键点：**不开线程**。handler 就在自己这条连接的任务里循环，
/// 由 `Io.Group` 统一管并发上限和取消——这正是 http.zig 的
/// `startEventStream`（每个 SSE 连接 `Thread.spawn` + `detach`，
/// 无上限也无法 join）应该避免的地方。
fn eventsHandler(ctx: *RequestContext, res: *Response) !void {
    _ = try res.header("Cache-Control", "no-cache");

    var buf: [1024]u8 = undefined;
    var s = try res.statusCode(.ok).stream(&buf, .{
        .content_type = "text/event-stream",
    });

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try s.print("event: tick\ndata: {{\"n\":{d}}}\n\n", .{i});
        // SSE 要即时可见，每条都得把缓冲推出去，不能攒着
        try s.flush();
        try std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake);
    }

    try s.writeAll("event: done\ndata: bye\n\n");
    try s.end();
}

/// 流式 JSON 数组：逐行写出，不先把整个数组建成内存里的一棵树。
fn rowsHandler(_: *RequestContext, res: *Response) !void {
    var buf: [4096]u8 = undefined;
    var s = try res.statusCode(.ok).stream(&buf, .{
        .content_type = "application/json",
    });

    // stream 的 writer 就是普通 *std.Io.Writer，std.json 直接能用
    const w = s.writer();
    try w.writeAll("[");
    for (0..1000) |i| {
        if (i != 0) try w.writeAll(",");
        var stringify: std.json.Stringify = .{ .writer = w, .options = .{} };
        try stringify.write(.{ .id = i, .name = "row" });
    }
    try w.writeAll("]");

    try s.end();
}
