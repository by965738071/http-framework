//! 内置 seed 数据（幂等）。
//!
//! fresh clone（data/ 为空）时启动即可登录。判定依据是「按唯一键查不到才插」，
//! 已存在的记录不改动，所以重复启动不会重复插入。

const std = @import("std");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");

const AppServices = container.AppServices;
const rbac = model.rbac;

pub const SeedResult = struct {
    permissions: usize = 0,
    roles: usize = 0,
    orgs: usize = 0,
    users: usize = 0,
    approvals: usize = 0,
};

pub const DEFAULT_ADMIN_USERNAME = "admin";
pub const DEFAULT_ADMIN_PASSWORD = "admin123";

pub fn run(svc: *AppServices) !SeedResult {
    // seed 期间所有读查询都走临时 arena：ORM 的 all/findBy 返回的行内字符串
    // 由传入的 allocator 拥有，若用进程级 allocator 就得逐行 free，
    // 一次性 arena 更不容易漏。
    var arena = std.heap.ArenaAllocator.init(svc.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var result = SeedResult{};
    result.permissions = try seedPermissions(svc, a);
    result.roles = try seedRoles(svc, a);
    result.orgs = try seedOrgs(svc, a);
    result.users = try seedUsers(svc, a);
    result.approvals = try seedApprovals(svc, a);
    return result;
}

fn seedPermissions(svc: *AppServices, a: std.mem.Allocator) !usize {
    var n: usize = 0;
    for (rbac.ALL_PERMISSIONS) |p| {
        if (try svc.rbac.findPermissionByCode(a, p.code) != null) continue;
        _ = try svc.rbac.insertPermission(.{
            .code = p.code,
            .module = p.module,
            .name = p.name,
            .description = p.name,
        });
        n += 1;
    }
    return n;
}

const RoleSeed = struct {
    code: []const u8,
    name: []const u8,
    description: []const u8,
    builtin: bool,
    permissions: []const []const u8,
};

const ROLE_SEEDS = [_]RoleSeed{
    .{
        .code = "super_admin",
        .name = "超级管理员",
        .description = "持有全部权限，不可删除",
        .builtin = true,
        .permissions = &.{rbac.WILDCARD},
    },
    .{
        .code = "org_admin",
        .name = "组织管理员",
        .description = "管理部门与成员，不能删除组织、不能删除角色",
        .builtin = true,
        .permissions = &.{
            "user:view", "user:create", "user:update", "user:reset-password",
            "user:assign-role", "user:unlock",
            "org:view", "org:create", "org:update", "org:move",
            "role:view", "role:assign",
            "log:view",
            "approval:view", "approval:create", "approval:review",
        },
    },
    .{
        .code = "auditor",
        .name = "审计员",
        .description = "只读 + 导出审计日志",
        .builtin = true,
        .permissions = &.{ "user:view", "org:view", "role:view", "log:view", "log:export", "approval:view" },
    },
    .{
        .code = "operator",
        .name = "运营",
        .description = "维护用户与查看组织",
        .builtin = false,
        .permissions = &.{ "user:view", "user:create", "user:update", "org:view" },
    },
};

fn seedRoles(svc: *AppServices, a: std.mem.Allocator) !usize {
    const now = svc.nowMs();
    var n: usize = 0;
    for (ROLE_SEEDS) |rs| {
        const existing = try svc.rbac.findRoleByCode(a, rs.code);
        if (existing) |e| {
            a.free(e.code);
            continue;
        }
        const id = try svc.rbac.insertRole(.{
            .code = rs.code,
            .name = rs.name,
            .description = rs.description,
            .is_builtin = rs.builtin,
            .created_at = now,
            .updated_at = now,
        });
        try svc.rbac.setRolePermissions(id, rs.permissions);
        n += 1;
    }
    return n;
}

const OrgSeed = struct {
    code: []const u8,
    name: []const u8,
    parent_code: ?[]const u8,
    leader: []const u8,
};

const ORG_SEEDS = [_]OrgSeed{
    .{ .code = "hq", .name = "总公司", .parent_code = null, .leader = "admin" },
    .{ .code = "tech", .name = "技术中心", .parent_code = "hq", .leader = "manager" },
    .{ .code = "market", .name = "市场部", .parent_code = "hq", .leader = "auditor" },
    .{ .code = "backend", .name = "后端组", .parent_code = "tech", .leader = "manager" },
    .{ .code = "frontend", .name = "前端组", .parent_code = "tech", .leader = "" },
};

fn seedOrgs(svc: *AppServices, a: std.mem.Allocator) !usize {
    const now = svc.nowMs();
    var n: usize = 0;
    for (ORG_SEEDS) |os| {
        if (try svc.orgs.findByCode(a, os.code) != null) continue;
        var parent_id: u64 = model.org.ROOT_PARENT;
        if (os.parent_code) |pc| {
            if (try svc.orgs.findByCode(a, pc)) |p| {
                parent_id = p.id;
            }
        }
        _ = try svc.orgs.insert(.{
            .name = os.name,
            .code = os.code,
            .parent_id = parent_id,
            .leader = os.leader,
            .sort_order = n,
            .created_at = now,
            .updated_at = now,
        });
        n += 1;
    }
    return n;
}

const UserSeed = struct {
    username: []const u8,
    password: []const u8,
    display_name: []const u8,
    email: []const u8,
    org_code: ?[]const u8,
    status: model.user.Status,
    roles: []const []const u8,
};

const USER_SEEDS = [_]UserSeed{
    .{
        .username = "admin",
        .password = "admin123",
        .display_name = "系统管理员",
        .email = "admin@example.com",
        .org_code = "hq",
        .status = .active,
        .roles = &.{"super_admin"},
    },
    .{
        .username = "manager",
        .password = "manager123",
        .display_name = "张管理",
        .email = "manager@example.com",
        .org_code = "tech",
        .status = .active,
        .roles = &.{"org_admin"},
    },
    .{
        .username = "auditor",
        .password = "auditor123",
        .display_name = "李审计",
        .email = "auditor@example.com",
        .org_code = "market",
        .status = .active,
        .roles = &.{"auditor"},
    },
    .{
        .username = "operator",
        .password = "operator123",
        .display_name = "王运营",
        .email = "operator@example.com",
        .org_code = "tech",
        .status = .active,
        .roles = &.{"operator"},
    },
    .{
        .username = "alice",
        .password = "alice123",
        .display_name = "爱丽丝",
        .email = "alice@example.com",
        .org_code = "backend",
        .status = .active,
        .roles = &.{},
    },
    .{
        .username = "bob",
        .password = "bob123",
        .display_name = "鲍勃（已禁用）",
        .email = "bob@example.com",
        .org_code = "backend",
        .status = .disabled,
        .roles = &.{},
    },
    .{
        .username = "carol",
        .password = "carol123",
        .display_name = "卡罗尔（已锁定）",
        .email = "carol@example.com",
        .org_code = "frontend",
        .status = .locked,
        .roles = &.{},
    },
};

fn seedUsers(svc: *AppServices, a: std.mem.Allocator) !usize {
    const now = svc.nowMs();
    var n: usize = 0;
    for (USER_SEEDS) |us| {
        if (try svc.users.findByUsername(a, us.username) != null) continue;

        var org_id: u64 = 0;
        if (us.org_code) |oc| {
            if (try svc.orgs.findByCode(a, oc)) |o| org_id = o.id;
        }
        const hash = try core.password.encode(a, us.password, core.password.randomSalt(svc.io));
        defer a.free(hash);

        const locked_until: u64 = if (us.status == .locked) now + 15 * 60 * 1000 else 0;
        const id = try svc.users.insert(.{
            .username = us.username,
            .display_name = us.display_name,
            .email = us.email,
            .password_hash = hash,
            .org_id = org_id,
            .status = @tagName(us.status),
            .failed_attempts = 0,
            .locked_until = locked_until,
            .last_login_at = 0,
            .created_at = now,
            .updated_at = now,
        });

        var role_ids = std.ArrayList(u64).empty;
        defer role_ids.deinit(a);
        for (us.roles) |rc| {
            if (try svc.rbac.findRoleByCode(a, rc)) |r| {
                try role_ids.append(a, r.id);
            }
        }
        if (role_ids.items.len > 0) try svc.rbac.setUserRoles(id, role_ids.items);
        n += 1;
    }
    return n;
}

/// 演示用审批单：只在表为空时插入，避免重复启动堆积。
fn seedApprovals(svc: *AppServices, a: std.mem.Allocator) !usize {
    const all = try svc.approvals.all(a);
    if (all.len > 0) return 0;

    const manager = (try svc.users.findByUsername(a, "manager")) orelse return 0;
    const alice = (try svc.users.findByUsername(a, "alice")) orelse return 0;
    const role = (try svc.rbac.findRoleByCode(a, "operator")) orelse return 0;
    const now = svc.nowMs();

    _ = try svc.approvals.insert(.{
        .kind = @tagName(model.approval.Kind.role_change),
        .applicant_id = manager.id,
        .applicant_name = manager.display_name,
        .target_user_id = alice.id,
        .target_user_name = alice.display_name,
        .role_id = role.id,
        .role_name = role.name,
        .reason = "爱丽丝需要运营后台权限",
        .status = "pending",
        .reviewer_id = 0,
        .reviewer_name = "",
        .review_comment = "",
        .created_at = now,
        .updated_at = now,
    });
    return 1;
}

// ── 测试：幂等性用临时数据目录实测 ─────────────────────────────────

test "seed 幂等：连续两次 run 不重复插入" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/tmp/app-seed-test";
    defer {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, dir) catch {};
    }

    // 注意：`AppServices.init` 内部已经跑过一次 seed，所以第一次显式 `run`
    // 就该什么都不插——幂等性正是靠这个断言兜住的。
    const svc = try AppServices.init(allocator, io, dir);
    const users_seeded = try svc.users.countAll();
    try std.testing.expect(users_seeded > 0);

    const r1 = try run(svc);
    try std.testing.expectEqual(@as(usize, 0), r1.users);
    try std.testing.expectEqual(@as(usize, 0), r1.orgs);
    try std.testing.expectEqual(@as(usize, 0), r1.roles);
    try std.testing.expectEqual(@as(usize, 0), r1.permissions);
    try std.testing.expectEqual(@as(usize, 0), r1.approvals);

    const r2 = try run(svc);
    try std.testing.expectEqual(@as(usize, 0), r2.users);
    try std.testing.expectEqual(users_seeded, try svc.users.countAll());

    // 重新打开（模拟重启，数据在磁盘上）后仍然不重复插入
    svc.deinit();
    const second = try AppServices.init(allocator, io, dir);
    const r3 = try run(second);
    try std.testing.expectEqual(@as(usize, 0), r3.users);
    try std.testing.expectEqual(users_seeded, try second.users.countAll());
    second.deinit();
}

test "seed 后的 admin 可用默认口令登录（哈希校验通过）" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/tmp/app-seed-test2";
    defer {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, dir) catch {};
    }

    const svc = try AppServices.init(allocator, io, dir);
    defer svc.deinit();

    // 读查询统一走 arena：findByUsername 返回的行里字符串由传入的 allocator
    // 拥有，用 testing.allocator 就得逐字段 free。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const user = (try svc.users.findByUsername(a, DEFAULT_ADMIN_USERNAME)).?;
    try std.testing.expect(try core.password.verify(DEFAULT_ADMIN_PASSWORD, user.password_hash));
    try std.testing.expect(!(try core.password.verify("wrong", user.password_hash)));
}

test "seed 建出组织树与权限点" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/tmp/app-seed-test3";
    defer {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, dir) catch {};
    }

    const svc = try AppServices.init(allocator, io, dir);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const perms = try svc.rbac.allPermissions(a);
    try std.testing.expectEqual(rbac.ALL_PERMISSIONS.len, perms.len);

    const admin = (try svc.users.findByUsername(a, "admin")).?;
    const granted = try svc.rbac.permissionsOfUser(a, admin.id);
    try std.testing.expect(rbac.hasPermission(granted, "user:create"));

    const alice = (try svc.users.findByUsername(a, "alice")).?;
    try std.testing.expectEqual(@as(usize, 0), (try svc.rbac.permissionsOfUser(a, alice.id)).len);
}

test {
    std.testing.refAllDecls(@This());
}
