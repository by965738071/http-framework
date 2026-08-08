//! HTTP/2 基础支持
//!
//! 提供 HTTP/2 协议升级检测和握手处理（h2c 明文升级）。
//! 完整的 HTTP/2 二进制帧处理较为复杂，本模块提供基础设施和升级入口，
//! 实际帧级协议处理留待后续完善。
//!
//! 支持的升级方式：
//! - h2c（HTTP/2 cleartext）：通过 `Upgrade: h2c` 头进行协议升级
//! - TLS ALPN：配合 TLS 使用（需要 TLS 支持）

const std = @import("std");
const http = std.http;
const mem = std.mem;

const RequestContext = @import("core").RequestContext;
const Response = @import("core").Response;

/// HTTP/2 配置
pub const Http2Config = struct {
    /// 是否启用 HTTP/2
    enabled: bool = false,

    /// 是否允许 HTTP/2 明文升级（h2c）
    allow_h2c_upgrade: bool = true,

    /// 最大并发流数（由服务器宣告给客户端）
    max_concurrent_streams: u32 = 100,

    /// 初始窗口大小（流量控制）
    initial_window_size: u32 = 65535,

    /// 最大帧大小（协商值）
    max_frame_size: u32 = 16384,

    /// 最大头部列表大小
    max_header_list_size: u32 = 65536,
};

/// HTTP/2 处理器 — 管理 HTTP/2 升级和连接
pub const Http2Handler = struct {
    config: Http2Config,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 创建 HTTP/2 处理器
    pub fn init(allocator: std.mem.Allocator, config: Http2Config) !*Self {
        const ptr = try allocator.create(Self);
        ptr.* = .{
            .config = config,
            .allocator = allocator,
        };
        return ptr;
    }

    /// 释放资源
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// 检查 HTTP 请求是否为 HTTP/2 升级请求（h2c）。
    ///
    /// 检查：
    /// - `Connection` 头包含 `Upgrade`
    /// - `Upgrade` 头为 `h2c`
    /// - `HTTP2-Settings` 头存在（RFC 7540 §3.2）
    pub fn isUpgradeRequest(ctx: *const RequestContext) bool {
        if (!isH2cUpgrade(ctx)) {
            return false;
        }
        return ctx.getHeader("HTTP2-Settings") != null;
    }

    /// 处理 h2c 升级：发送 101 Switching Protocols 响应。
    ///
    /// 升级成功后，连接切换到 HTTP/2 二进制帧协议。
    /// 后续的帧处理需要单独的 HTTP/2 连接处理器（参见下面的 FrameHandler 部分）。
    ///
    /// 调用此方法前应先通过 `isUpgradeRequest` 确认是升级请求。
    pub fn handleUpgrade(
        self: *Self,
        ctx: *RequestContext,
        res: *Response,
    ) !void {
        _ = self;

        // 设置 101 升级响应
        _ = res.statusCode(.switching_protocols);

        // 添加升级相关响应头
        _ = try res.header("Connection", "Upgrade");
        _ = try res.header("Upgrade", "h2c");

        // RFC 7540 §3.2：服务器必须忽略 HTTP2-Settings 中的未知参数，
        // 并在 SETTINGS 帧中宣告自己的参数（在实际二进制帧处理时）
        // 这里只做升级握手，帧级协商在后续的 FrameHandler 中处理

        // 触发发送 101 响应（空 body）
        try res.text("");

        ctx.is_websocket = true; // 借用 is_websocket 标志阻止 HTTP/1.1 keep-alive 继续
    }

    /// 检查请求的 TLS ALPN 是否协商为 h2
    pub fn isAlpnH2(ctx: *const RequestContext) bool {
        // ALPN 信息通常从 TLS 层获取，这里提供一个查询入口
        _ = ctx;
        return false; // 需要 TLS 支持后才能实际检测
    }

    /// 验证 HTTP/2 连接前言中的 Magic Octets
    pub fn verifyPreface(data: []const u8) bool {
        const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        return data.len >= preface.len and mem.eql(u8, data[0..preface.len], preface);
    }
};

// =========================================================================
// HTTP/2 帧处理（基础骨架）
// =========================================================================

/// HTTP/2 帧类型
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,

    pub fn fromByte(b: u8) ?FrameType {
        return switch (b) {
            0x0 => .data,
            0x1 => .headers,
            0x2 => .priority,
            0x3 => .rst_stream,
            0x4 => .settings,
            0x5 => .push_promise,
            0x6 => .ping,
            0x7 => .goaway,
            0x8 => .window_update,
            0x9 => .continuation,
            else => null,
        };
    }
};

/// HTTP/2 帧头（9 字节，RFC 7540 §4.1）
pub const FrameHeader = struct {
    length: u24,
    type: FrameType,
    flags: u8,
    stream_id: u31,

    /// 从字节切片解析帧头
    pub fn parse(data: []const u8) ?FrameHeader {
        if (data.len < 9) return null;

        const length = @as(u24, @intCast(data[0])) << 16 |
            @as(u24, @intCast(data[1])) << 8 |
            @as(u24, @intCast(data[2]));

        const frame_type = FrameType.fromByte(data[3]) orelse return null;

        return FrameHeader{
            .length = length,
            .type = frame_type,
            .flags = data[4],
            .stream_id = (@as(u31, @intCast(data[5])) << 24 |
                @as(u31, @intCast(data[6])) << 16 |
                @as(u31, @intCast(data[7])) << 8 |
                @as(u31, @intCast(data[8]))) & 0x7FFFFFFF, // 去掉保留位
        };
    }
};

/// HTTP/2 连接连接序言（Magic Octets）
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// 标准 SETTINGS 帧标志
pub const SettingFlags = struct {
    pub const ack: u8 = 0x1;
};

/// 已知 SETTINGS 参数（RFC 7540 §6.5.2）
pub const SettingId = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
};

/// 错误码（RFC 7540 §7）
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

// =========================================================================
// 使 RequestContext 支持 h2c 检测
// =========================================================================

/// 检查是否为 HTTP/2 cleartext 升级请求
fn isH2cUpgrade(ctx: *const RequestContext) bool {
    const connection = ctx.getHeader("Connection") orelse return false;
    const upgrade = ctx.getHeader("Upgrade") orelse return false;

    // Connection 头应包含 "Upgrade"（不区分大小写）
    if (!containsIgnoreCase(connection, "Upgrade")) return false;

    // Upgrade 头应为 "h2c"
    if (!std.ascii.eqlIgnoreCase(upgrade, "h2c")) return false;

    return true;
}

/// 不区分大小写的子串匹配
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// =========================================================================
// Tests
// =========================================================================

test "Http2Config defaults" {
    const cfg = Http2Config{};
    try std.testing.expectEqual(false, cfg.enabled);
    try std.testing.expectEqual(true, cfg.allow_h2c_upgrade);
    try std.testing.expectEqual(@as(u32, 100), cfg.max_concurrent_streams);
    try std.testing.expectEqual(@as(u32, 65535), cfg.initial_window_size);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
}

test "FrameHeader.parse valid header" {
    // 构造一个 SETTINGS 帧头：length=6, type=SETTINGS(0x4), flags=0, stream_id=0
    const data = [_]u8{ 0x00, 0x00, 0x06, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const header = FrameHeader.parse(&data);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(@as(u24, 6), header.?.length);
    try std.testing.expectEqual(FrameType.settings, header.?.type);
    try std.testing.expectEqual(@as(u8, 0), header.?.flags);
    try std.testing.expectEqual(@as(u31, 0), header.?.stream_id);
}

test "FrameHeader.parse invalid type returns null" {
    // 帧类型 0xFF 不合法
    const data = [_]u8{ 0x00, 0x00, 0x06, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const header = FrameHeader.parse(&data);
    try std.testing.expectEqual(@as(?FrameHeader, null), header);
}

test "FrameHeader.parse too short returns null" {
    const data = [_]u8{ 0x00, 0x00, 0x06 };
    const header = FrameHeader.parse(&data);
    try std.testing.expectEqual(@as(?FrameHeader, null), header);
}

test "verifyPreface valid" {
    try std.testing.expect(Http2Handler.verifyPreface("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"));
}

test "verifyPreface invalid" {
    try std.testing.expect(!Http2Handler.verifyPreface("GET / HTTP/1.1\r\n"));
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("keep-alive, Upgrade", "upgrade"));
    try std.testing.expect(containsIgnoreCase("Upgrade", "upgrade"));
    try std.testing.expect(!containsIgnoreCase("keep-alive", "upgrade"));
}
