//! middleware —— 只做横切关注点：错误渲染、鉴权、权限守卫。

pub const error_json = @import("error_json.zig");
pub const auth = @import("auth.zig");

pub const ErrorJson = error_json.ErrorJson;
pub const SessionAuth = auth.SessionAuth;
pub const OptionalAuth = auth.OptionalAuth;
pub const PermissionGuard = auth.PermissionGuard;
