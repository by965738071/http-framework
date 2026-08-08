//! `codec` — 请求体编解码 addon
//!
//! 依赖 `core`，为其提供反序列化、压缩、签名校验与字段校验能力。
//! core 本身只把请求体当作字节流，这里的一切都是可选的。

const std = @import("std");

pub const deserialize = @import("deserialize.zig");
pub const compression = @import("compression.zig");
pub const body_signature = @import("body_signature.zig");
pub const validation = @import("validation.zig");

pub const Parsed = deserialize.Parsed;
pub const bodyAs = deserialize.bodyAs;
pub const queryAs = deserialize.queryAs;

test {
    std.testing.refAllDecls(@This());
}
