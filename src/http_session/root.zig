//! http_session addon — 会话管理
//!
//! 依赖：http_app, http_protocol

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const session = @import("session.zig");
pub const SessionManager = session.SessionManager;
pub const SessionConfig = session.SessionConfig;
pub const SessionData = session.SessionData;

test {
    std.testing.refAllDecls(@This());
}
