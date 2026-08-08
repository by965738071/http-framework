const std = @import("std");

/// 模块依赖图（由 Zig 的模块系统在编译期强制，不是文档约定）
///
///     core  ← codec, multipart, security, observability, background,
///             session, static, rate_limit, protocol
///     (无依赖) policy, template, pool, orm
///
///     http_framework  → 以上全部（伞形聚合，方便一把梭）
///
/// `core` 的 imports 列表是空的。任何人往 core 里 `@import("session")`
/// 之类的都会直接编译失败——这就是这次重构真正想要的东西：
/// 依赖方向由构建系统保证，而不是靠自觉。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── core：最小 HTTP 服务器，零依赖 ────────────────────────────
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── 依赖 core 的 addon ────────────────────────────────────────
    const AddonSpec = struct { name: []const u8, path: []const u8 };
    const core_addons = [_]AddonSpec{
        .{ .name = "codec", .path = "src/codec/root.zig" },
        .{ .name = "multipart", .path = "src/multipart/multipart.zig" },
        .{ .name = "security", .path = "src/security/root.zig" },
        .{ .name = "observability", .path = "src/observability/root.zig" },
        .{ .name = "background", .path = "src/background/background.zig" },
        .{ .name = "session", .path = "src/session/session.zig" },
        .{ .name = "static", .path = "src/static/static.zig" },
        .{ .name = "rate_limit", .path = "src/rate_limit/root.zig" },
        .{ .name = "protocol", .path = "src/protocol/root.zig" },
    };

    // ── 不依赖 core 的独立工具模块 ────────────────────────────────
    const standalone = [_]AddonSpec{
        .{ .name = "policy", .path = "src/policy/root.zig" },
        .{ .name = "template", .path = "src/template/root.zig" },
        .{ .name = "pool", .path = "src/pool/connection_pool.zig" },
        .{ .name = "orm", .path = "src/orm/root.zig" },
    };

    // 伞形模块的 imports 列表边建边攒
    var umbrella_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    defer umbrella_imports.deinit(b.allocator);
    umbrella_imports.append(b.allocator, .{ .name = "core", .module = core }) catch @panic("OOM");

    for (core_addons) |spec| {
        const m = b.addModule(spec.name, .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        });
        umbrella_imports.append(b.allocator, .{ .name = spec.name, .module = m }) catch @panic("OOM");
    }

    for (standalone) |spec| {
        const m = b.addModule(spec.name, .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
        umbrella_imports.append(b.allocator, .{ .name = spec.name, .module = m }) catch @panic("OOM");
    }

    // ── 测试 ──────────────────────────────────────────────────────
    // 每个模块单独编译并测试。
    //
    // 这不只是为了跑用例：**编译本身就是依赖方向的回归测试**。
    // `core` 的测试目标只包含 core 模块，一旦有人往 core 里
    // `@import("session")` 之类的，这一步会直接编译失败。
    const test_step = b.step("test", "Run tests");
    for (umbrella_imports.items) |imp| {
        const t = b.addTest(.{ .root_module = imp.module });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── http_framework：伞形聚合模块 ──────────────────────────────
    const mod = b.addModule("http_framework", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = umbrella_imports.items,
    });

    // ── 可执行示例 ────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "http_framework",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // 伞形模块（含 src/test 集成测试）与可执行入口
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}
