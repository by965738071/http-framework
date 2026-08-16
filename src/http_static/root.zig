//! http_static addon — 静态文件服务
//!
//! 依赖：http_app, http_protocol

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const static = @import("static.zig");
pub const StaticFileServer = static.StaticFileServer;

test {
    std.testing.refAllDecls(@This());
}
