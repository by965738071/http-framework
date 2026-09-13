//! model —— 领域实体：ORM 行结构、状态机、对外视图。
//!
//! 约束：ORM 只支持 int / float / bool / string（见 src/http_orm/model.zig
//! 的 `fieldTypeOf`），所以行结构里的枚举一律存字符串，对外视图再转成业务结构。

pub const user = @import("user.zig");
pub const org = @import("org.zig");
pub const rbac = @import("rbac.zig");
pub const audit = @import("audit.zig");
pub const approval = @import("approval.zig");
pub const dto = @import("dto.zig");
