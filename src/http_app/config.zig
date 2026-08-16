//! 分层配置（回应 bug.md §10）
//!
//! 原来的 Config 是一个 15+ 字段的扁平 struct，TCP 参数 / HTTP 参数 /
//! body 策略 / 内存池策略混在一起，无法做 profile diff。
//!
//! 现在分层：NetworkConfig / HttpConfig / BodyConfig / PoolConfig。
//! Config 全部不可变（const），RuntimeState 独立（可变）。

const std = @import("std");

pub const Config = struct {
    network: NetworkConfig = .{},
    http: HttpConfig = .{},
    body: BodyConfig = .{},
    pool: PoolConfig = .{},
};

pub const NetworkConfig = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    tcp_backlog: u31 = 4096,
    reuse_address: bool = false,
    max_connections: u32 = 10000,
    /// keep-alive 空闲超时（纳秒）。超过此时间无新请求则关闭连接。
    /// 防止 Slowloris 慢攻击耗尽连接（fix.md §二.6）。
    idle_timeout_ns: u64 = 60_000_000_000,
    /// 单次读超时（纳秒）。setsockopt SO_RCVTIMEO。
    read_timeout_ns: u64 = 30_000_000_000,
    /// 单次写超时（纳秒）。setsockopt SO_SNDTIMEO。
    write_timeout_ns: u64 = 30_000_000_000,
};

pub const HttpConfig = struct {
    server_name: []const u8 = "ZigHTTP",
    keep_alive_enabled: bool = true,
    read_buffer_size: usize = 16384,
    write_buffer_size: usize = 8192,
    access_log_enabled: bool = false,
};

pub const BodyConfig = struct {
    size_limit: u64 = 10 * 1024 * 1024,
    lazy_read_size: u64 = 0,
    trust_proxy_headers: bool = false,
};

pub const PoolConfig = struct {
    conn_pool_size: u32 = 256,
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
