//! 只依赖 core 模块的最小 HTTP 服务器。
//!
//! 不用伞形模块 http_framework，不引任何 addon（无中间件、无静态文件、
//! 无日志器……），核心只有四件事：Router 注册路由 → Server.init →
//! server.run()。

const std = @import("std");
const core = @import("core");
const multipart = @import("multipart");
const observability = @import("observability");

const Router = core.Router;
const Server = core.Server;
const RequestContext = core.RequestContext;
const Response = core.Response;
const Handler = core.Handler;
const FileLogger = observability.FileLogger;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 1. 路由表
    var router = Router.init(gpa);
    defer router.deinit();

    try router.route(.GET, "/", Handler.fromFn(indexHandler));
    try router.route(.POST, "/hello/:name", Handler.fromFn(helloHandler));

    // multipart 上传：字段 + 文件一次全拿（类似 Spring）
    try router.route(.POST, "/upload", Handler.fromFn(uploadHandler));

    // 2. 文件日志：core 只认 Logger 接口，轮转/异步都在 observability 里
    var file_logger = try FileLogger.init(gpa, io, "log/minimal.log", .{
        .async_enabled = true,
        .min_level = .debug,
        .utc_offset_seconds = 8 * 3600,
    });
    defer file_logger.deinit();

    // 3. 服务器（Config 全走默认值）
    var server = try Server.init(gpa, io, .{}, &router);
    defer server.deinit();
    server.setLogger(file_logger.logger());

    // 4. 阻塞运行，Ctrl+C 优雅关闭
    try server.run();
}

fn indexHandler(_: *RequestContext, res: *Response) !void {
    try res.text("Hello from core-only server!\n");
}

fn helloHandler(ctx: *RequestContext, res: *Response) !void {
    const name = ctx.getParam("name") orelse "world";
    const body = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name});
    defer ctx.allocator.free(body);
    try res.html(body);
}

/// multipart 上传处理器：普通字段和文件一起拿到，互不耽误（类似 Spring）。
///
/// 用 curl 测试（`-F` 会自动拼出 multipart/form-data 格式）：
///   curl -X POST -F "username=bob" -F "avatar=@photo.png" http://127.0.0.1:9000/upload
fn uploadHandler(ctx: *RequestContext, res: *Response) !void {
    var form = try multipart.from(ctx);
    defer form.deinit();

    // 普通字段
    const username = form.getText("username") orelse "anonymous";

    // 文件
    if (form.getFile("avatar")) |file| {
        const file_name = file.file_name orelse "upload.bin";
        const dir = std.Io.Dir.cwd();
        var out = try dir.createFile(ctx.io, file_name, .{});
        defer out.close(ctx.io);
        try out.writeStreamingAll(ctx.io, file.data);

        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "uploaded \"{s}\" ({d} bytes, {s}) by {s}",
            .{ file_name, file.data.len, file.content_type orelse "unknown", username },
        );
        defer ctx.allocator.free(msg);
        try res.text(msg);
        return;
    }

    try res.text("no file field \"avatar\" found\n");
}

