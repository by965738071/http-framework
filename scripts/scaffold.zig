//! HTTP Framework 项目脚手架工具
//!
//! 快速生成新的 HTTP Framework 项目。
//!
//! 用法：
//! ```bash
//! zig run scripts/scaffold.zig -- new my-app
//! zig run scripts/scaffold.zig -- new my-app --name "My Project"
//! ```

const std = @import("std");
const mem = std.mem;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // 跳过程序名
    _ = args.next();

    const cmd = args.next() orelse {
        try printUsage(io);
        return error.MissingCommand;
    };

    if (!mem.eql(u8, cmd, "new")) {
        std.log.err("Unknown command: {s}", .{cmd});
        try printUsage(io);
        return error.InvalidCommand;
    }

    const project_dir = args.next() orelse {
        std.log.err("Missing project name", .{});
        return error.MissingProjectName;
    };

    var project_name: []const u8 = project_dir;
    // 解析 --name 参数
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--name") or mem.eql(u8, arg, "-n")) {
            project_name = args.next() orelse {
                std.log.err("Missing value for --name", .{});
                return error.InvalidArgs;
            };
        }
    }

    try scaffold(allocator, io, project_dir, project_name);
}

fn scaffold(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // 检查目录是否已存在
    cwd.statFile(io, dir, .{}) catch {
        try cwd.createDirPath(io, dir) catch |err| {
            std.log.err("Failed to create directory '{s}': {}", .{ dir, err });
            return err;
        };
    };

    std.log.info("Scaffolding project '{s}' in '{s}/'...", .{ name, dir });

    // 创建子目录
    inline for (.{ "src", "src/api", "public", "log" }) |sub| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, sub });
        defer allocator.free(path);
        cwd.createDirPath(io, path) catch {};
    }

    // 生成文件
    try writeFile(allocator, io, dir, "build.zig.zon", buildZonContent(name));
    try writeFile(allocator, io, dir, "build.zig", buildZigContent());
    try writeFile(allocator, io, dir, "src/main.zig", mainZigContent(name));
    try writeFile(allocator, io, dir, "src/api/home.zig", homeZigContent());
    try writeFile(allocator, io, dir, ".gitignore", gitignoreContent());
    try writeFile(allocator, io, dir, "README.md", readmeContent(name));

    std.log.info("", .{});
    std.log.info("Project '{s}' created successfully!", .{name});
    std.log.info("", .{});
    std.log.info("Next steps:", .{});
    std.log.info("  cd {s}", .{dir});
    std.log.info("  zig build run", .{});
    std.log.info("  # Open http://127.0.0.1:9000", .{});
}

fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    filename: []const u8,
    content: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
    defer allocator.free(path);

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    std.log.info("  Created {s}/{s}", .{ dir, filename });
}

fn printUsage(io: std.Io) !void {
    _ = io;
    std.log.info("Usage: zig run scripts/scaffold.zig -- new <project-dir> [--name <project-name>]", .{});
}

// =========================================================================
// 模板内容
// =========================================================================

fn buildZonContent(name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x0,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .http_framework = .{{
        \\            .path = "../http-framework",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "README.md",
        \\    }},
        \\}}
    , .{name});
}

fn buildZigContent() []const u8 {
    return
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const http_framework = b.dependency("http_framework", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "app",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\            .imports = &.{
    \\                .{ .name = "http_framework", .module = http_framework.module("http_framework") },
    \\            },
    \\        }),
    \\    });
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\
    \\    const run_step = b.step("run", "Run the app");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    ;
}

fn mainZigContent(name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\const std = @import("std");
        \\const http_framework = @import("http_framework");
        \\
        \\const Server = http_framework.Server;
        \\const Router = http_framework.Router;
        \\const Handler = http_framework.Handler;
        \\const RequestContext = http_framework.RequestContext;
        \\const Response = http_framework.Response;
        \\const Config = http_framework.Config;
        \\
        \\const SecurityHeaders = http_framework.SecurityHeaders;
        \\
        \\const HomeHandler = @import("api/home.zig");
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    var gpa = std.heap.DebugAllocator(.{{}}.{{}};
        \\    defer {{
        \\        const leaked = gpa.deinit();
        \\        if (leaked == .leak) @panic("Memory leak detected");
        \\    }}
        \\    const allocator = gpa.allocator();
        \\    const io = init.io;
        \\
        \\    // ── 安全响应头中间件 ──
        \\    var security = try SecurityHeaders.SecurityHeaders.create(allocator, io, .{{}});
        \\    defer security.deinit();
        \\
        \\    // ── 路由器 ──
        \\    var router = Router.init(allocator);
        \\    defer router.deinit();
        \\
        \\    try router.route(.GET, "/", try Handler.initPerRequest(HomeHandler, allocator));
        \\
        \\    // 404 处理
        \\    router.notFound(Handler.fromFn(struct {{
        \\        fn handler(ctx: *RequestContext, res: *Response) !void {{
        \\            _ = ctx;
        \\            try res.statusCode(.not_found).json(.{{ .error = "404 - Not Found" }});
        \\        }}
        \\    }}.handler));
        \\
        \\    // ── 服务器配置与启动 ──
        \\    const config = Config.defaults();
        \\    var server = try Server.init(allocator, io, config, router);
        \\    defer server.deinit();
        \\    try server.run();
        \\}}
    , .{name});
}

fn homeZigContent() []const u8 {
    return
    \\const std = @import("std");
    \\const http_framework = @import("http_framework");
    \\const RequestContext = http_framework.RequestContext;
    \\const Response = http_framework.Response;
    \\
    \\pub const HomeHandler = struct {
    \\    pub fn init(allocator: std.mem.Allocator) !*HomeHandler {
    \\        _ = allocator;
    \\        // 请求级 Handler，每次请求新建实例
    \\        const ptr = try allocator.create(HomeHandler);
    \\        ptr.* = .{};
    \\        return ptr;
    \\    }
    \\
    \\    pub fn handle(self: *HomeHandler, ctx: *RequestContext, res: *Response) !void {
    \\        _ = self;
    \\        _ = ctx;
    \\        try res.statusCode(.ok).json(.{
    \\            .message = "Hello, Zig!",
    \\            .framework = "http-framework",
    \\        });
    \\    }
    \\
    \\    pub fn deinit(self: *HomeHandler) void {
    \\        _ = self;
    \\        // 释放内部资源（框架自动 destroy self）
    \\    }
    \\};
    ;
}

fn gitignoreContent() []const u8 {
    return
    \\zig-out/
    \\.zig-cache/
    \\log/*.log
    \\log/*.gz
    ;
}

fn readmeContent(name: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\# {s}
        \\
        \\基于 [http-framework](https://github.com/your/http-framework) 构建的 HTTP 服务。
        \\
        \\## 运行
        \\
        \\```bash
        \\# 开发模式
        \\zig build run
        \\
        \\# 发布模式
        \\zig build run -Doptimize=ReleaseFast
        \\
        \\# 运行测试
        \\zig build test
        \\```
        \\
        \\## API
        \\
        \\| 方法 | 路径 | 说明 |
        \\|------|------|------|
        \\| GET | / | 返回 Hello World JSON |
        \\
        \\## 项目结构
        \\
        \\```
        \\src/
        \\├── main.zig          # 入口
        \\└── api/
        \\    └── home.zig     # Home 处理器
        \\```
    , .{name});
}
