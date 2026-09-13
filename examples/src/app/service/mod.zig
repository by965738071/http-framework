//! service —— 业务规则层。
//!
//! 只在这里做：校验、业务规则、状态机流转、组合操作、写审计日志、发实时通知。
//! 不直接认识 ORM（读写都经 repo），HTTP 上下文只在「抛结构化错误」与
//! 「审计取 IP / request_id」时使用。

pub const actor = @import("actor.zig");
pub const container = @import("container.zig");
pub const audit_service = @import("audit_service.zig");
pub const auth_service = @import("auth_service.zig");
pub const user_service = @import("user_service.zig");
pub const org_service = @import("org_service.zig");
pub const rbac_service = @import("rbac_service.zig");
pub const approval_service = @import("approval_service.zig");
pub const seed = @import("seed.zig");

// 仓储层真实读写路径的集成测试（用临时 data 目录）
pub const integration_test = @import("integration_test.zig");

pub const Actor = actor.Actor;
pub const AppServices = container.AppServices;
