//! http_router 层 — radix trie 路由引擎（依赖 http_app, http_protocol）
//!
//! 回应 bug.md §5：用 radix trie 替代线性扫描，
//! O(路径段数) 匹配、前缀共享、注册时静态冲突检测。

pub const Trie = @import("trie.zig").Trie;
pub const Router = @import("router.zig").Router;

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
