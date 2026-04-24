//! 服务器配置
//!
//! 定义 HTTP 服务器所需的运行时参数。

const std = @import("std");

/// HTTP 服务器配置
text: []const u8,
port: u16,

const Self = @This();

/// 返回默认配置（监听 `127.0.0.1:9000`）
pub fn defaults() Self {
    return .{
        .text = "127.0.0.1",
        .port = 9000,
    };
}
