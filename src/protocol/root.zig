//! `protocol` — 协议扩展 addon
//!
//! WebSocket 升级已可用；HTTP/2 仍是半成品（见 `experimental`）。

const std = @import("std");

pub const websocket = @import("websocket.zig");

pub const WebSocketManager = websocket.WebSocketManager;
pub const WsEchoHandler = websocket.WsEchoHandler;

/// 实验性：
/// - `http2.zig` 只实现了 h2c 升级检测与帧头解析，HPACK 未实现，未接入 Server。
pub const experimental = struct {
    pub const http2 = @import("http2.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(experimental);
}
