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

    /// 请求体最大字节数（0 表示不限制）
    body_size_limit: u64 = 10 * 1024 * 1024, // 10MB 默认限制

    /// 是否启用访问日志
    access_log_enabled: bool = true,

    // =========================================================================
    // 文件日志配置
    // =========================================================================

    /// 日志文件路径（null 表示不写文件日志）
    log_file_path: ?[]const u8 = null,

    /// 单个日志文件最大字节数（默认 10MB）
    log_max_file_size: u64 = 10 * 1024 * 1024,

    /// 最大日志备份数量（默认 10）
    log_max_backup_files: u32 = 10,

    /// 是否压缩轮转后的日志文件
    log_compress_rotated: bool = true,

    /// 是否异步写日志
    log_async_enabled: bool = false,

    /// 是否按日轮转日志文件
    log_rotate_daily: bool = true,

    // =========================================================================
    // TLS/HTTPS 配置
    // =========================================================================

    /// 是否启用 HTTPS/TLS
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
    try std.testing.expectEqual(true, config.access_log_enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), config.log_file_path);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), config.log_max_file_size);
    try std.testing.expectEqual(@as(u32, 10), config.log_max_backup_files);
    try std.testing.expectEqual(true, config.log_compress_rotated);
    try std.testing.expectEqual(false, config.log_async_enabled);
    try std.testing.expectEqual(true, config.log_rotate_daily);
    try std.testing.expectEqual(false, config.tls_enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), config.tls_cert_file);
    try std.testing.expectEqual(@as(?[]const u8, null), config.tls_key_file);
}
