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
pub const Response = @import("response.zig").Response;
pub const Cookie = @import("response.zig").Cookie;
pub const Sink = @import("response.zig").Sink;
pub const ConnectionLoop = @import("conn_loop.zig").ConnectionLoop;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
