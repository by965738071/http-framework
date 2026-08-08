//! `policy` — 内容安全策略构建 addon
//!
//! 纯字符串构建工具（CSP 指令、SRI 摘要），生成的值交给 `security` 或
//! 用户自己写入响应头。不依赖 core。

const std = @import("std");

pub const csp = @import("csp.zig");
pub const sri = @import("sri.zig");

pub const CspBuilder = csp.CspBuilder;
pub const SRIHash = sri.SRIHash;

test {
    std.testing.refAllDecls(@This());
}
