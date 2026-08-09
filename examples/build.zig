const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_framework = b.dependency("http_framework", .{
        .target = target,
        .optimize = optimize,
    });
    const fw_mod = http_framework.module("http_framework");
    const orm_mod = http_framework.module("orm");

    // ── 示例可执行文件 ────────────────────────────────
    const examples = [_]struct {
        name: []const u8,
        src: []const u8,
        uses_orm: bool,
    }{
        .{ .name = "server", .src = "src/server.zig", .uses_orm = false },
        .{ .name = "api_server", .src = "src/api_server.zig", .uses_orm = false },
        .{ .name = "basic_server", .src = "src/basic_server.zig", .uses_orm = false },
        .{ .name = "fullstack_app", .src = "src/fullstack_app.zig", .uses_orm = false },
        .{ .name = "middleware_demo", .src = "src/middleware_demo.zig", .uses_orm = false },
        .{ .name = "user_management", .src = "src/user_management.zig", .uses_orm = true },
        .{ .name = "admin_system", .src = "src/admin_system.zig", .uses_orm = true },
        .{ .name = "websocket", .src = "src/websocket.zig", .uses_orm = false },
        .{ .name = "streaming", .src = "src/streaming.zig", .uses_orm = false },
        .{ .name = "streaming_upload", .src = "src/streaming_upload.zig", .uses_orm = false },
    };

    var server_exe: ?*std.Build.Step.Compile = null;
    var user_mgmt_exe: ?*std.Build.Step.Compile = null;
    var admin_exe: ?*std.Build.Step.Compile = null;

    inline for (examples) |ex| {
        const imports: []const std.Build.Module.Import = if (ex.uses_orm)
            &.{
                .{ .name = "http_framework", .module = fw_mod },
                .{ .name = "orm", .module = orm_mod },
            }
        else
            &.{
                .{ .name = "http_framework", .module = fw_mod },
            };
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = mod,
        });
        b.installArtifact(exe);

        if (std.mem.eql(u8, ex.name, "server")) server_exe = exe;
        if (std.mem.eql(u8, ex.name, "user_management")) user_mgmt_exe = exe;
        if (std.mem.eql(u8, ex.name, "admin_system")) admin_exe = exe;
    }

    // ── 运行步骤 ──────────────────────────────────────
    const run_step = b.step("run", "Run the demo server");
    const run_cmd = b.addRunArtifact(server_exe.?);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_user_mgmt_step = b.step("run-user-mgmt", "Run the user management system");
    const run_user_mgmt_cmd = b.addRunArtifact(user_mgmt_exe.?);
    run_user_mgmt_step.dependOn(&run_user_mgmt_cmd.step);
    run_user_mgmt_cmd.step.dependOn(b.getInstallStep());

    const run_admin_step = b.step("run-admin", "Run the unified admin system (users + products)");
    const run_admin_cmd = b.addRunArtifact(admin_exe.?);
    run_admin_step.dependOn(&run_admin_cmd.step);
    run_admin_cmd.step.dependOn(b.getInstallStep());

    // ── HTTP 集成测试 ──────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_framework", .module = fw_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run HTTP integration tests");
    test_step.dependOn(&run_tests.step);
}
