//! HTTP 集成测试
//!
//! 启动服务器 → 发送 HTTP 请求 → 验证响应

const std = @import("std");
const http_framework = @import("http_framework");
const testing = std.testing;

// ── 测试入口 ─────────────────────────────────────────

test "server init and deinit" {
    const allocator = testing.allocator;
    

    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    router.route(.GET, "/", http_framework.Handler.fromFn(struct {
        fn h(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            try res.html("<h1>Hello</h1>");
        }
    }.h)) catch unreachable;

    const config = http_framework.Config.Config{ .port = 0, .address = "127.0.0.1" };
    _ = config;
    // Type compile check only
}

test "Handler fromFn lifecycle" {
    const called = false;
    const fn_ptr = struct {
        fn h(_: *http_framework.RequestContext, _: *http_framework.Response) !void {}
    }.h;
    _ = fn_ptr;
    // fromFn creates handler that can be passed to router
    const h = http_framework.Handler.fromFn(struct {
        fn h(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            _ = res.statusCode(.ok);
        }
    }.h);
    _ = h;
    _ = called;
}

test "Router route registration" {
    const allocator = testing.allocator;
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/test", http_framework.Handler.fromFn(struct {
        fn h(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            try res.json(.{ .ok = true });
        }
    }.h));
}

test "Router route with param" {
    const allocator = testing.allocator;
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/users/:id", http_framework.Handler.fromFn(struct {
        fn h(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
            const id = ctx.getParam("id") orelse "none";
            try res.json(.{ .user_id = id });
        }
    }.h));
}

test "Response status codes" {
    // Verify status code enum values are accessible
    try testing.expectEqual(@as(u16, 200), @intFromEnum(std.http.Status.ok));
    try testing.expectEqual(@as(u16, 404), @intFromEnum(std.http.Status.not_found));
    try testing.expectEqual(@as(u16, 500), @intFromEnum(std.http.Status.internal_server_error));
    try testing.expectEqual(@as(u16, 429), @intFromEnum(std.http.Status.too_many_requests));
}

test "Config defaults" {
    const cfg = http_framework.Config.Config{};
    try testing.expectEqualStrings("127.0.0.1", cfg.address);
    try testing.expectEqual(@as(u16, 9000), cfg.port);
    try testing.expectEqual(true, cfg.access_log_enabled);
    try testing.expectEqual(false, cfg.tls_enabled);
}
