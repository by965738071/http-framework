//! 分层配置（回应 bug.md §10）
//!
//! 原来的 Config 是一个 15+ 字段的扁平 struct，TCP 参数 / HTTP 参数 /
//! body 策略 / 内存池策略混在一起，无法做 profile diff。
//!
//! 现在分层：NetworkConfig / HttpConfig / BodyConfig / PoolConfig。
//! Config 全部不可变（const），RuntimeState 独立（可变）。
//!
//! 环境变量加载（见 `applyEnv` / `Config.fromEnv`）解决「部署时改端口/地址要重新
//! 编译」的问题；应用自己的配置字段用组合 + 同一个 `applyEnv` 承接，见 Config 注释。

const std = @import("std");

/// `applyEnv` 的错误集合。
pub const EnvError = std.mem.Allocator.Error || std.fmt.ParseIntError || error{BadEnvValue};

/// comptime 把字段名转大写（env 键命名用）。返回定长数组以便参与 `++` 拼接。
fn upperName(comptime name: []const u8) [name.len]u8 {
    var buf: [name.len]u8 = undefined;
    for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf;
}

/// 宽松布尔解析：1/true/yes/on 为真，0/false/no/off 为假（大小写不敏感）。
fn parseEnvBool(raw: []const u8) !bool {
    const truths = [_][]const u8{ "1", "true", "yes", "on" };
    const falses = [_][]const u8{ "0", "false", "no", "off" };
    for (truths) |t| if (std.ascii.eqlIgnoreCase(raw, t)) return true;
    for (falses) |f| if (std.ascii.eqlIgnoreCase(raw, f)) return false;
    return error.BadEnvValue;
}

/// 按字段类型把 env 字符串解析并赋值。类型从 `ptr` 自身推导（同 `Handler.initSingleton`
/// 的 anytype 套路，调用点不重复写类型）。支持：整数、bool、[]const u8、?[]const u8。
fn assignFromEnv(ptr: anytype, allocator: std.mem.Allocator, raw: []const u8) EnvError!void {
    const Ptr = @TypeOf(ptr);
    const info = @typeInfo(Ptr);
    // 只接受可变的单元素指针：用 `Ptr == *child` 一个判据同时拒绝
    // *const T（会把 const 洗掉）、[*]T/[]T 等非 one 指针——
    // 0.17 的 Pointer 元类型已没有 is_const 字段。
    if (info != .pointer or info.pointer.size != .one or Ptr != *info.pointer.child) {
        @compileError("assignFromEnv expects a mutable single-item pointer (e.g. &@field(target, name)), got " ++ @typeName(Ptr));
    }
    const T = info.pointer.child;
    if (T == bool) {
        ptr.* = try parseEnvBool(raw);
    } else if (T == []const u8) {
        ptr.* = try allocator.dupe(u8, raw);
    } else if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == []const u8) {
        ptr.* = try allocator.dupe(u8, raw);
    } else if (@typeInfo(T) == .int) {
        ptr.* = try std.fmt.parseInt(T, raw, 10);
    } else {
        @compileError("applyEnv: unsupported field type: " ++ @typeName(T));
    }
}

/// 按「`prefix` + 大写字段名」约定，把环境变量覆盖到 struct 字段上。
///
/// - 嵌套 struct 字段递归下钻，**键名只取叶子字段**（`network.port` → `APP_PORT`，
///   而不是 `APP_NETWORK_PORT`），避免最常见的 `PORT` 类变量被层级前缀淹没。
/// - 未设置的 env 保留字段默认值，因此可以在 `Config{ ... }` 字面量之后再调用，
///   实现「comptime 默认值 + 运行时覆盖」两级。
/// - 支持字段类型：整数、`bool`、`[]const u8`、`?[]const u8`、嵌套 struct；
///   其余类型 comptime 报错。
/// - 字符串值用 `allocator` dupe，返回的 struct 持有该内存——推荐直接传进程级
///   arena；否则调用方负责在配置生命周期结束后释放。
///
/// 这同时是**应用级配置的扩展点**：框架不猜应用需要哪些字段，应用把自己的配置
/// 声明成普通 struct、与 `Config` 组合，再对组合 struct 调本函数即可共享同一套
/// 加载约定：
///
/// ```zig
/// const AppConfig = struct { server: framework.Config = .{}, data_dir: []const u8 = "./data" };
/// var app: AppConfig = .{};
/// try framework.applyEnv(AppConfig, &app, arena, init.environ_map, "APP_");
/// // APP_PORT=8080 → server.network.port；APP_DATA_DIR=/srv → data_dir
/// ```
pub fn applyEnv(
    comptime T: type,
    target: *T,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    comptime prefix: []const u8,
) EnvError!void {
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.field_names, struct_info.field_types) |name, field_type| {
        if (@typeInfo(field_type) == .@"struct") {
            try applyEnv(field_type, &@field(target, name), allocator, environ, prefix);
            continue;
        }
        const key = comptime prefix ++ &upperName(name);
        if (environ.get(key)) |raw| {
            assignFromEnv(&@field(target, name), allocator, raw) catch |err| {
                std.log.warn("config: env {s}='{s}' 解析失败: {t}", .{ key, raw, err });
                return err;
            };
        }
    }
}

pub const Config = struct {
    network: NetworkConfig = .{},
    http: HttpConfig = .{},
    body: BodyConfig = .{},
    pool: PoolConfig = .{},

    /// 从环境变量构建 Config（见 `applyEnv`）。键 = `prefix` + 大写字段名，例如
    /// `prefix="APP_"` 时：`APP_ADDRESS`、`APP_PORT`、`APP_SERVER_NAME`、
    /// `APP_SIZE_LIMIT`、`APP_MAX_CONNECTIONS`、`APP_READ_TIMEOUT_NS` ……全部
    /// 叶子字段均可覆盖；未设置的保持默认值。
    ///
    /// `environ` 用 0.16+ 的非全局环境（`main(init)` 里的 `init.environ_map`）。
    /// `allocator` 推荐进程级 arena（address/server_name 等字符串由它持有）。
    ///
    /// ```zig
    /// pub fn main(init: std.process.Init) !void {
    ///     const cfg = try framework.Config.fromEnv(init.arena.allocator(), init.environ_map, "APP_");
    /// }
    /// ```
    ///
    /// 需要配置文件（而非 env）时不用新增框架入口：`Config` 是纯数据类型，
    /// `std.json.parseFromSlice(Config, gpa, text, .{ .ignore_unknown_fields = true })`
    /// 可以直接吃 JSON 配置，应用自行决定文件位置与格式。
    pub fn fromEnv(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        comptime prefix: []const u8,
    ) !Config {
        var cfg = Config{};
        try applyEnv(Config, &cfg, allocator, environ, prefix);
        return cfg;
    }
};

pub const NetworkConfig = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    tcp_backlog: u31 = 4096,
    reuse_address: bool = false,
    /// 同时存活的连接上限（背压）。达到后新连接在 accept 前挂起，
    /// 直到有连接结束释放名额。zio 下一个连接只占一个轻量协程，可设很高。
    max_connections: u32 = 1024,
    /// keep-alive 空闲超时（纳秒）。超过此时间无新请求则关闭连接。
    idle_timeout_ns: u64 = 60_000_000_000,
    /// 单次读超时（纳秒）。zio 原生 per-operation timeout（防慢攻击）。
    read_timeout_ns: u64 = 30_000_000_000,
    /// 单次写超时（纳秒）。zio 原生 per-operation timeout。
    write_timeout_ns: u64 = 30_000_000_000,
};

pub const HttpConfig = struct {
    server_name: []const u8 = "ZigHTTP",
    keep_alive_enabled: bool = true,
    read_buffer_size: usize = 16384,
    write_buffer_size: usize = 8192,
    access_log_enabled: bool = false,
    data_dir: ?[]const u8 = null,
};

pub const BodyConfig = struct {
    size_limit: u64 = 10 * 1024 * 1024,
    lazy_read_size: u64 = 0,
    trust_proxy_headers: bool = false,
};

pub const PoolConfig = struct {
    /// 请求 arena 在请求结束后保留的容量（>0 则 keep-alive 下复用内存、不归还 OS）。
    request_arena_retain_bytes: usize = 16 * 1024,
};

/// 运行时状态（可变，与 Config 分离）。
/// 回应 bug.md §10：Config 不可变，可以无锁共享给 worker。
pub const RuntimeState = struct {
    active_connections: std.atomic.Value(u32) = .init(0),
    total_connections: std.atomic.Value(u64) = .init(0),
    active_requests: std.atomic.Value(u32) = .init(0),
    accept_errors: std.atomic.Value(u64) = .init(0),
    shutting_down: std.atomic.Value(bool) = .init(false),
};

pub const ServerStats = struct {
    active_connections: u32,
    total_connections: u64,
    active_requests: u32,
    accept_errors: u64,
    shutting_down: bool,
};

test "Config defaults are sensible" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("0.0.0.0", cfg.network.address);
    try std.testing.expectEqual(@as(u16, 9000), cfg.network.port);
    try std.testing.expect(cfg.http.keep_alive_enabled);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), cfg.body.size_limit);
    // 超时默认值（fix.md §二.6）
    try std.testing.expectEqual(@as(u64, 60_000_000_000), cfg.network.idle_timeout_ns);
    try std.testing.expectEqual(@as(u64, 30_000_000_000), cfg.network.read_timeout_ns);
    try std.testing.expectEqual(@as(u64, 30_000_000_000), cfg.network.write_timeout_ns);
}

test "Config.fromEnv overrides leaf fields (flat keys)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    try map.put("APP_ADDRESS", "127.0.0.1");
    try map.put("APP_PORT", "8081");
    try map.put("APP_SERVER_NAME", "EnvApp");
    try map.put("APP_SIZE_LIMIT", "1024");
    try map.put("APP_REUSE_ADDRESS", "true");
    try map.put("APP_MAX_CONNECTIONS", "64");

    const cfg = try Config.fromEnv(a, &map, "APP_");
    try std.testing.expectEqualStrings("127.0.0.1", cfg.network.address);
    try std.testing.expectEqual(@as(u16, 8081), cfg.network.port);
    try std.testing.expectEqualStrings("EnvApp", cfg.http.server_name);
    try std.testing.expectEqual(@as(u64, 1024), cfg.body.size_limit);
    try std.testing.expect(cfg.network.reuse_address);
    try std.testing.expectEqual(@as(u32, 64), cfg.network.max_connections);
    // 未设置的字段保持默认
    try std.testing.expectEqual(@as(u64, 60_000_000_000), cfg.network.idle_timeout_ns);
    try std.testing.expectEqual(@as(usize, 16 * 1024), cfg.pool.request_arena_retain_bytes);
}

test "Config.fromEnv optional string + bad values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    try map.put("APP_DATA_DIR", "/srv/data");
    const cfg = try Config.fromEnv(a, &map, "APP_");
    try std.testing.expectEqualStrings("/srv/data", cfg.http.data_dir.?);

    var bad = std.process.Environ.Map.init(a);
    defer bad.deinit();
    try bad.put("APP_PORT", "not-a-number");
    try std.testing.expectError(error.InvalidCharacter, Config.fromEnv(a, &bad, "APP_"));

    var bad_bool = std.process.Environ.Map.init(a);
    defer bad_bool.deinit();
    try bad_bool.put("APP_REUSE_ADDRESS", "maybe");
    try std.testing.expectError(error.BadEnvValue, Config.fromEnv(a, &bad_bool, "APP_"));
}

test "applyEnv extends to app-owned structs (config extension point)" {
    const AppCfg = struct {
        server: Config = .{},
        data_dir: ?[]const u8 = null,
        db_path: []const u8 = "./db.sqlite",
        verbose: bool = false,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    try map.put("APP_PORT", "7070");
    try map.put("APP_DB_PATH", "/srv/db.sqlite");
    try map.put("APP_VERBOSE", "1");

    var app = AppCfg{ .server = .{ .network = .{ .port = 1 } } };
    try applyEnv(AppCfg, &app, a, &map, "APP_");
    // 框架子配置被 env 覆盖（在 comptime 字面量之后生效）
    try std.testing.expectEqual(@as(u16, 7070), app.server.network.port);
    try std.testing.expectEqualStrings("/srv/db.sqlite", app.db_path);
    try std.testing.expect(app.verbose);
    try std.testing.expectEqual(@as(?[]const u8, null), app.data_dir);
}

test "Config can be partially overridden (profile diff)" {
    const cfg = Config{
        .network = .{ .port = 8080 },
        .http = .{ .server_name = "MyApp" },
    };
    try std.testing.expectEqual(@as(u16, 8080), cfg.network.port);
    try std.testing.expectEqualStrings("MyApp", cfg.http.server_name);
    // body/pool still default
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), cfg.body.size_limit);
}

test {
    std.testing.refAllDecls(@This());
}
