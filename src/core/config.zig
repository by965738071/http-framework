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

    /// 是否启用访问日志
    access_log_enabled: bool = true,

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
