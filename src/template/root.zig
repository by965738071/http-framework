//! `template` — 模板渲染 addon
//!
//! 不依赖 core：渲染出的字符串由调用方自行写入响应。

const std = @import("std");

pub const Template = @import("template.zig").Template;

/// 实验性：block / extends / include 尚未完成。
pub const experimental = struct {
    pub const engine = @import("template_engine.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(experimental);
}
