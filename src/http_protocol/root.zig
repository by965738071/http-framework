//! http_protocol 层 — HTTP 协议解析（零框架依赖）
//!
//! 这是最底层的模块，只负责"字节 ↔ 报文"：
//! - Request：不可变的请求解析结果
//! - Response：响应构建器（只持 Writer，不持 *http.Server.Request）— 回应 bug.md §8
//! - ConnectionLoop：keep-alive 状态机 — 回应 bug.md §7
//!
//! 不包含路由、中间件、handler 生命周期管理——那些在 http_app 层。

pub const Request = @import("request.zig").Request;
pub const BodyReader = @import("request.zig").Request.BodyReader;
/// 共享的 percent/form-urlencoded 解码器（Context.queryDecoded 等复用同一规则）。
pub const urlDecode = @import("request.zig").urlDecode;
/// 同一解码器的 RFC 3986 变体（`+` 保持字面量），供路径参数使用。
pub const urlDecodePath = @import("request.zig").urlDecodePath;
pub const Response = @import("response.zig").Response;
pub const Cookie = @import("response.zig").Cookie;
pub const Sink = @import("response.zig").Sink;
pub const ConnectionLoop = @import("conn_loop.zig").ConnectionLoop;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
