const std = @import("std");

/// 新架构模块依赖图（DAG，不是星形）
///
///     http_protocol  (零依赖)
///     http_app       → http_protocol
///     http_router    → http_app, http_protocol
///     http_server    → http_router, http_app, http_protocol
///
///     Addons（依赖 http_app / http_protocol，可互相依赖）：
///       http_security / http_session / http_rate_limit / http_compress /
///       http_static / http_logging / http_codec / http_multipart / http_orm
///
///     http_framework  → 以上全部（伞形聚合）
///
/// 回应 bug.md §1：core 不再是一个"最小核心"，而是按 5 层职责拆分。
/// 回应 bug.md §6：addon 可以互相依赖（DAG），不再是星形。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zio 异步运行时（io_uring/kqueue/iocp + 协程）。http_server 全面基于 zio
    // 实现，统一跨平台 API，不再有 std.Io.Threaded 的 poll/信号平台分支。
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    // ── 新架构：4 层模块 ──────────────────────────────────────

    // Layer 1: http_protocol — 字节 ↔ 报文（零依赖）
    const http_protocol = b.addModule("http_protocol", .{
        .root_source_file = b.path("src/http_protocol/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Layer 2: http_app — 生命周期 + 管道（依赖 http_protocol）
    const http_app = b.addModule("http_app", .{
        .root_source_file = b.path("src/http_app/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
        },
    });

    // Layer 3: http_router — radix trie 路由（依赖 http_app, http_protocol）
    const http_router = b.addModule("http_router", .{
        .root_source_file = b.path("src/http_router/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Layer 4: http_server — 组装（依赖 http_router, http_app, http_protocol, zio）
    const http_server = b.addModule("http_server", .{
        .root_source_file = b.path("src/http_server/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
            .{ .name = "http_router", .module = http_router },
            .{ .name = "zio", .module = zio },
        },
    });

    // Addon: http_security — CSRF/Auth/CORS/安全头（依赖 http_app, http_protocol）
    const http_security = b.addModule("http_security", .{
        .root_source_file = b.path("src/http_security/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_session — 会话管理（依赖 http_app, http_protocol）
    const http_session = b.addModule("http_session", .{
        .root_source_file = b.path("src/http_session/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_rate_limit — 速率限制（依赖 http_app, http_protocol）
    const http_rate_limit = b.addModule("http_rate_limit", .{
        .root_source_file = b.path("src/http_rate_limit/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_compress — 响应压缩（依赖 http_app, http_protocol）
    const http_compress = b.addModule("http_compress", .{
        .root_source_file = b.path("src/http_compress/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_static — 静态文件服务（依赖 http_app, http_protocol, http_compress）
    const http_static = b.addModule("http_static", .{
        .root_source_file = b.path("src/http_static/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
            .{ .name = "http_compress", .module = http_compress },
        },
    });

    // Addon: http_logging — 结构化日志（依赖 http_app, http_protocol）
    const http_logging = b.addModule("http_logging", .{
        .root_source_file = b.path("src/http_logging/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
        .link_libc = true,
    });

    // Addon: http_codec — JSON body 解析（依赖 http_app, http_protocol）
    const http_codec = b.addModule("http_codec", .{
        .root_source_file = b.path("src/http_codec/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_multipart — multipart/form-data 解析（依赖 http_app, http_protocol）
    const http_multipart = b.addModule("http_multipart", .{
        .root_source_file = b.path("src/http_multipart/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // Addon: http_orm — JSON 文件存储 ORM（零外部依赖，作为独立 addon 挂在伞形模块下）
    const http_orm = b.addModule("http_orm", .{
        .root_source_file = b.path("src/http_orm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Addon: http_websocket — WebSocket (RFC 6455) 握手 + 帧编解码 + 连接 API
    // （依赖 http_app 的 Context、http_protocol 的 Response；帧编解码独立于二者）
    const http_websocket = b.addModule("http_websocket", .{
        .root_source_file = b.path("src/http_websocket/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_protocol", .module = http_protocol },
            .{ .name = "http_app", .module = http_app },
        },
    });

    // ── 测试 ──────────────────────────────────────────────────
    const test_step = b.step("test", "Run tests");

    for ([_]*std.Build.Module{
        http_protocol,
        http_app,
        http_router,
        http_server,
        http_security,
        http_session,
        http_rate_limit,
        http_static,
        http_codec,
        http_multipart,
        http_compress,
        http_logging,
        http_orm,
        http_websocket,
    }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── http_framework：伞形聚合模块 ──────────────────────────
    const umbrella_imports: []const std.Build.Module.Import = &.{
        .{ .name = "http_protocol", .module = http_protocol },
        .{ .name = "http_app", .module = http_app },
        .{ .name = "http_router", .module = http_router },
        .{ .name = "http_server", .module = http_server },
        .{ .name = "http_security", .module = http_security },
        .{ .name = "http_session", .module = http_session },
        .{ .name = "http_rate_limit", .module = http_rate_limit },
        .{ .name = "http_static", .module = http_static },
        .{ .name = "http_codec", .module = http_codec },
        .{ .name = "http_multipart", .module = http_multipart },
        .{ .name = "http_compress", .module = http_compress },
        .{ .name = "http_logging", .module = http_logging },
        .{ .name = "http_orm", .module = http_orm },
        .{ .name = "http_websocket", .module = http_websocket },
    };

    const mod = b.addModule("http_framework", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = umbrella_imports,
    });

    // ── 可执行入口 ─────────────────────────────────────────────
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

    const umbrella_test = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(umbrella_test).step);

    const exe_test = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_test).step);

    // ── 性能基准（内存内 Router.dispatch 热路径）────────────
    // 用法：zig build bench -Doptimize=ReleaseFast
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_framework", .module = mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Run performance micro-benchmarks");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);
}
