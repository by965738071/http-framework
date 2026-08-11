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

    /// 最大并发连接数（0 表示不限制）。
    /// 达到上限时 accept 循环会阻塞，新连接由内核 backlog 排队，
    /// 形成背压，避免连接洪峰耗尽文件描述符/内存资源。
    ///
    /// **这个值应当 ≤ 底层 `std.Io` 实际能跑的并发任务数**
    /// （`Io.Threaded` 默认是 `cpu_count - 1`，可用 `async_limit` 调高）。
    /// 配得太高时信号量会放行、而 `Io` 派发不出任务，连接只能退化为在
    /// accept 线程上就地处理——`Server.stats().inline_fallbacks` 会计数。
    /// 那个数非 0 就是这里配错了的信号。
    ///
    /// core 没法自己推断这个上限：它只看得到 `std.Io` 这个 vtable，
    /// 看不到背后是几线程。所以这里给的是一个保守的默认值，
    /// 真正的调优必须由搭建 `Io` 的那一方来做。
    max_connections: u32 = 10000,

    /// 请求体最大字节数（0 表示不限制）
    body_size_limit: u64 = 10 * 1024 * 1024, // 10MB 默认限制

    /// 请求体「不再缓冲」的阈值（字节），0 表示关闭。
    ///
    /// `Content-Length` 超过此值时 `ctx.readBody()` 不会去读，而是直接返回
    /// `error.BodyTooLargeToBuffer`（此时一个字节都还没消费），handler 应改用
    /// `ctx.bodyStream()` 边收边处理。没接住这个错误的话，Server 会回 413。
    ///
    /// 为什么默认关闭：打开后 `readBody()` 会对大 body 报错，
    /// 这对既有 handler 是行为变更。需要扛大上传的服务显式配上，
    /// 例如 `.lazy_read_size = 1 << 20`（1MiB 以上一律走流式）。
    ///
    /// 只对声明了 `Content-Length` 的请求生效。`chunked` 事先不知道长度，
    /// 无法在读之前判断，仍受 `body_size_limit` 约束。
    lazy_read_size: u64 = 0,

    /// 连接状态池的容量：启动时预分配多少套「读缓冲 + 写缓冲 + 请求 arena」，
    /// 同时也是空闲池的上限（超过就直接销毁，让高水位之后自动缩容）。
    ///
    /// 池空时不排队，直接现场堆分配——宁可这一条连接慢一点，
    /// 也不要卡住 accept。命中/落空次数见 `Server.poolStats()`。
    ///
    /// 默认 256：够覆盖常见的稳态并发，又不至于启动就占掉几十 MB
    /// （256 × (16KiB + 8KiB) ≈ 6MiB）。
    conn_pool_size: u32 = 256,

    /// 每请求 arena 在请求结束后保留的容量上限（字节）。
    ///
    /// keep-alive 连接上每个请求都完全归还内存的话，下一个请求又要重新
    /// 向 OS 要一次；保留一小段「热身容量」可以让稳态请求的分配全部
    /// 命中已有内存。设为 0 表示每个请求后彻底释放。
    request_arena_retain_bytes: usize = 16 * 1024,

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
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), config.body_size_limit);
    try std.testing.expectEqual(@as(u32, 10000), config.max_connections);
    try std.testing.expectEqual(@as(u32, 256), config.conn_pool_size);
    try std.testing.expectEqual(@as(usize, 16 * 1024), config.request_arena_retain_bytes);
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
