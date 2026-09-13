//! repo —— ORM 封装层。
//!
//! 职责边界：只做查询与持久化的封装，**不含任何业务规则**（谁能不能删、状态
//! 能不能改都属于 service）。所有读方法都接收一个 allocator（通常传请求
//! arena），返回的行内字符串由它拥有，请求结束统一回收，不需要手动 free。

const std = @import("std");
const model = @import("../model/mod.zig");

pub const Database = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    users: *model.user.Store,
    orgs: *model.org.Store,
    roles: *model.rbac.RoleStore,
    permissions: *model.rbac.PermissionStore,
    user_roles: *model.rbac.UserRoleStore,
    role_permissions: *model.rbac.RolePermissionStore,
    audit_logs: *model.audit.Store,
    approvals: *model.approval.Store,

    /// 打开（必要时创建）全部表。目录不存在会自动创建。
    pub fn open(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*Database {
        const self = try allocator.create(Database);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .users = try model.user.Store.open(allocator, io, data_dir),
            .orgs = try model.org.Store.open(allocator, io, data_dir),
            .roles = try model.rbac.RoleStore.open(allocator, io, data_dir),
            .permissions = try model.rbac.PermissionStore.open(allocator, io, data_dir),
            .user_roles = try model.rbac.UserRoleStore.open(allocator, io, data_dir),
            .role_permissions = try model.rbac.RolePermissionStore.open(allocator, io, data_dir),
            .audit_logs = try model.audit.Store.open(allocator, io, data_dir),
            .approvals = try model.approval.Store.open(allocator, io, data_dir),
        };
        return self;
    }

    /// 关闭并持久化所有表（JsonStore.close 内部会 flush 一次）。
    pub fn close(self: *Database) void {
        inline for (comptime std.meta.fieldNames(Database)) |name| {
            if (comptime std.mem.eql(u8, name, "allocator") or std.mem.eql(u8, name, "io")) continue;
            if (@field(self, name).close()) |_| {} else |err| {
                std.log.err("close store {s}: {s}", .{ name, @errorName(err) });
            }
        }
        self.allocator.destroy(self);
    }

    /// 立即把某张表的改动落盘。ORM 的改动只在内存里，不 flush 就不持久。
    pub fn flush(self: *Database, comptime table: []const u8) !void {
        return @field(self, table).flush();
    }
};

/// 分页查询结果。`items` 已经是当前页的切片。
pub fn SearchResult(comptime T: type) type {
    return struct {
        items: []T,
        total: usize,
    };
}

pub const user_repo = @import("user_repo.zig");
pub const org_repo = @import("org_repo.zig");
pub const rbac_repo = @import("rbac_repo.zig");
pub const audit_repo = @import("audit_repo.zig");
pub const approval_repo = @import("approval_repo.zig");

pub const UserFilter = user_repo.Filter;
pub const AuditFilter = audit_repo.AuditFilter;
pub const ApprovalFilter = approval_repo.ApprovalFilter;

pub const UserRepository = user_repo.UserRepository;
pub const OrgRepository = org_repo.OrgRepository;
pub const RbacRepository = rbac_repo.RbacRepository;
pub const AuditRepository = audit_repo.AuditRepository;
pub const ApprovalRepository = approval_repo.ApprovalRepository;

test {
    std.testing.refAllDecls(@This());
}
