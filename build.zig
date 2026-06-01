const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coreMod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("http_framework", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = coreMod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "http_framework",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = mod },
                .{ .name = "core", .module = coreMod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // ── Tests ──────────────────────────────────────

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // ORM tests (file-relative @import resolves automatically)
    const orm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/orm/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_orm_tests = b.addRunArtifact(orm_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_orm_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
