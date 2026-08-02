const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ORM tests (file-relative @import resolves automatically)
    const ormMod = b.addModule("orm", .{
        .root_source_file = b.path("src/orm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("http_framework", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "orm", .module = ormMod },
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
                .{ .name = "orm", .module = ormMod },
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

    // ORM tests
    const orm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/orm/root.zig"),
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
