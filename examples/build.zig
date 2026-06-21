const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_framework = b.dependency("http_framework", .{
        .target = target,
        .optimize = optimize,
    });

    // ── 演示服务器（唯一可执行文件）─────────────────────
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = http_framework.module("http_framework") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // ── HTTP 集成测试 ──────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_framework", .module = http_framework.module("http_framework") },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run HTTP integration tests");
    test_step.dependOn(&run_tests.step);
}
