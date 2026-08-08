//! HTTP 集成测试
//!
//! IMPORTANT: Run via build system, not directly:
//!   cd examples && zig build test
//!
//! Direct `zig test` will fail because http_framework is a build-system dependency.
//! Configure your IDE to use `zig build test` in the examples directory.

const std = @import("std");
const testing = std.testing;

// This import works because the build system wires it up (build.zig.zon + build.zig)
const http_framework = @import("http_framework");

test "Router init and deinit" {
    const allocator = testing.allocator;
    var router = http_framework.Router.init(allocator);
    defer router.deinit();
    try testing.expect(@intFromPtr(&router) > 0);
}

test "Route registration" {
    const allocator = testing.allocator;
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/test", http_framework.Handler.fromFn(struct {
        fn h(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            _ = try res.json(.{ .ok = true });
        }
    }.h));
}

test "Route with param" {
    const allocator = testing.allocator;
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    try router.route(.GET, "/users/:id", http_framework.Handler.fromFn(struct {
        fn h(ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
            const id = ctx.getParam("id") orelse "none";
            _ = try res.json(.{ .user_id = id });
        }
    }.h));
}

test "HTTP status codes" {
    try testing.expectEqual(@as(u16, 200), @backingInt(std.http.Status.ok));
    try testing.expectEqual(@as(u16, 404), @backingInt(std.http.Status.not_found));
    try testing.expectEqual(@as(u16, 500), @backingInt(std.http.Status.internal_server_error));
    try testing.expectEqual(@as(u16, 429), @backingInt(std.http.Status.too_many_requests));
}

test "Config defaults" {
    const cfg = http_framework.Config{};
    try testing.expectEqualStrings("127.0.0.1", cfg.address);
    try testing.expectEqual(@as(u16, 9000), cfg.port);
    try testing.expectEqual(true, cfg.access_log_enabled);
}
