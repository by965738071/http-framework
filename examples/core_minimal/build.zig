const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 只把 core 模块接进来：零 addon，零外部依赖
    const core = b.addModule("core", .{
        .root_source_file = b.path("../../src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // multipart 是依赖 core 的 addon，按需接进来即可用 `multipart.from(ctx)`
    const multipart = b.addModule("multipart", .{
        .root_source_file = b.path("../../src/multipart/multipart.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // observability 提供 FileLogger（实现 core.Logger），同样依赖 core
    const observability = b.addModule("observability", .{
        .root_source_file = b.path("../../src/observability/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    const exe = b.addExecutable(.{
        .name = "minimal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "multipart", .module = multipart },
                .{ .name = "observability", .module = observability },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the minimal server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
