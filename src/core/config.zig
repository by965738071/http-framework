//! HTTP 服务器配置
//!
//! 定义服务器的基本运行时参数。
//! 使用 Zig 0.17.0-dev API 规范。

const std = @import("std");

pub const Config = struct {
    /// 监听地址
    address: []const u8 = "127.0.0.1",

    /// 监听端口
    port: u16 = 9000,

    /// 服务器名称（用于 Server 响应头）
    server_name: []const u8 = "ZigHTTP",

    /// TCP backlog 大小
    tcp_backlog: u31 = 4096,

    /// 是否重用地址
    reuse_address: bool = true,

    /// 读取缓冲区大小
    read_buffer_size: usize = 16384,

    /// 写入缓冲区大小
    write_buffer_size: usize = 8192,

    /// 是否启用 HTTP keep-alive
    keep_alive_enabled: bool = true,

    /// 连接空闲超时（纳秒），0 表示无超时
    idle_timeout_ns: u64 = 30_000_000_000, // 30 秒

    /// 最大并发连接数（0 表示不限制）。
    /// 达到上限时 accept 循环会阻塞，新连接由内核 backlog 排队，
    /// 形成背压，避免连接洪峰耗尽文件描述符/内存资源。
    max_connections: u32 = 10000,

    /// 请求体最大字节数（0 表示不限制）
    body_size_limit: u64 = 10 * 1024 * 1024, // 10MB 默认限制

    /// 是否启用访问日志
    access_log_enabled: bool = true,

    /// 是否信任代理头（X-Forwarded-For / X-Real-IP）用于获取客户端 IP。
    /// 仅在服务器部署于可信反向代理之后时开启；
    /// 直连部署开启会导致客户端可任意伪造 IP（绕过限流/审计）。
    trust_proxy_headers: bool = false,

    // 注：文件日志的轮转/压缩/异步等配置**不在这里**。
    // 核心只认识 `core.Logger` 接口，具体实现（含其配置）属于 observability：
    //
    //     var flog = try FileLogger.init(allocator, io, "logs/app.log", .{ ... });
    //     defer flog.deinit();
    //     server.setLogger(flog.logger());

    // =========================================================================
    // TLS/HTTPS 配置
    // =========================================================================

    /// 是否启用 HTTPS/TLS。
    /// 注意：TLS 尚未实现——启用后 Server.init 会返回 error.TlsNotSupported，
    /// 而不是静默退回明文 HTTP。生产环境请使用反向代理（nginx 等）终结 TLS。
    tls_enabled: bool = false,

    /// TLS 证书文件路径（PEM 格式）
    tls_cert_file: ?[]const u8 = null,

    /// TLS 私钥文件路径（PEM 格式）
    tls_key_file: ?[]const u8 = null,

    /// 返回默认配置
    pub fn defaults() Config {
        return .{};
    }
};

// ===========================================================================
// 测试
// ===========================================================================

test "Config.defaults - returns default values" {
    const config = Config.defaults();

    try std.testing.expectEqualStrings("127.0.0.1", config.address);
    try std.testing.expectEqual(@as(u16, 9000), config.port);
    try std.testing.expectEqualStrings("ZigHTTP", config.server_name);
    try std.testing.expectEqual(@as(u31, 4096), config.tcp_backlog);
    try std.testing.expectEqual(true, config.reuse_address);
    try std.testing.expectEqual(@as(usize, 16384), config.read_buffer_size);
    try std.testing.expectEqual(@as(usize, 8192), config.write_buffer_size);
    try std.testing.expectEqual(true, config.keep_alive_enabled);
    try std.testing.expectEqual(@as(u64, 30_000_000_000), config.idle_timeout_ns);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), config.body_size_limit);
    try std.testing.expectEqual(@as(u32, 10000), config.max_connections);
    try std.testing.expectEqual(true, config.access_log_enabled);
    try std.testing.expectEqual(false, config.trust_proxy_headers);
    try std.testing.expectEqual(false, config.tls_enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), config.tls_cert_file);
    try std.testing.expectEqual(@as(?[]const u8, null), config.tls_key_file);
}

test "Config - custom values override defaults" {
    const config = Config{
        .address = "0.0.0.0",
        .port = 8080,
        .server_name = "MyServer",
        .keep_alive_enabled = false,
        .read_buffer_size = 4096,
    };

    try std.testing.expectEqualStrings("0.0.0.0", config.address);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expectEqualStrings("MyServer", config.server_name);
    try std.testing.expectEqual(false, config.keep_alive_enabled);
    try std.testing.expectEqual(@as(usize, 4096), config.read_buffer_size);
    // Unchanged fields should still be defaults
    try std.testing.expectEqual(@as(u31, 4096), config.tcp_backlog);
    try std.testing.expectEqual(true, config.reuse_address);
    try std.testing.expectEqual(@as(u64, 30_000_000_000), config.idle_timeout_ns);
}

test "Config - TLS enabled configuration" {
    const config = Config{
        .tls_enabled = true,
        .tls_cert_file = "/etc/certs/server.crt",
        .tls_key_file = "/etc/certs/server.key",
    };

    try std.testing.expectEqual(true, config.tls_enabled);
    try std.testing.expectEqualStrings("/etc/certs/server.crt", config.tls_cert_file.?);
    try std.testing.expectEqualStrings("/etc/certs/server.key", config.tls_key_file.?);
}

test "Config - TLS with custom port" {
    const config = Config{
        .tls_enabled = true,
        .tls_cert_file = "/etc/ssl/certs/server.crt",
        .tls_key_file = "/etc/ssl/private/server.key",
        .port = 443,
    };

    try std.testing.expectEqual(true, config.tls_enabled);
    try std.testing.expectEqualStrings("/etc/ssl/certs/server.crt", config.tls_cert_file.?);
    try std.testing.expectEqualStrings("/etc/ssl/private/server.key", config.tls_key_file.?);
    try std.testing.expectEqual(@as(u16, 443), config.port);
}
