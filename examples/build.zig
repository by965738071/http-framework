const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_framework = b.dependency("http_framework", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Basic Server Example ──
    const exe = b.addExecutable(.{
        .name = "examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/basic_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = http_framework.module("http_framework") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the basic server example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // ── User Management Example ──
    const user_mgmt_exe = b.addExecutable(.{
        .name = "user_management",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user_management.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = http_framework.module("http_framework") },
            },
        }),
    });
    b.installArtifact(user_mgmt_exe);

    const run_user_mgmt_step = b.step("run-user-mgmt", "Run the user management system");
    const run_user_mgmt_cmd = b.addRunArtifact(user_mgmt_exe);
    run_user_mgmt_step.dependOn(&run_user_mgmt_cmd.step);
    run_user_mgmt_cmd.step.dependOn(b.getInstallStep());

    // ── HTTP Integration Tests ──
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
