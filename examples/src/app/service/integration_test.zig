//! 数据层集成测试：用真实的临时 data 目录跑 ORM + 仓储。
//!
//! 业务规则（service）的错误路径依赖 `framework.Context`（抛错要往 ctx 的
//! user_data 槽里写东西），框架没有可构造的测试用 Context，所以规则层只能
//! 测纯函数 + 走真实 HTTP 冒烟；这里补的是仓储层的真实读写路径。
//!
//! 所有读查询统一走 arena：仓储返回的行内字符串由传入的 allocator 拥有，
//! 逐条 free 容易漏，而且 `search` 返回的是大缓冲区的子切片——直接 free 会因
//!「长度 ≠ 容量」被 DebugAllocator 判定为非法释放。

const std = @import("std");
const model = @import("../model/mod.zig");
const repo = @import("../repo/mod.zig");
const container = @import("container.zig");

const AppServices = container.AppServices;

const TestEnv = struct {
    arena: *std.heap.ArenaAllocator,
    svc: *AppServices,
    name: []const u8,

    /// `a` 用于所有读查询（arena，请求结束一次性回收）。
    fn a(self: TestEnv) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: TestEnv, io: std.Io) void {
        self.svc.deinit();
        // arena 本身是用 testing.allocator 分配的，deinit 只回收它托管的内存，
        // 结构体本体还要 destroy，否则每次跑测试都漏一块。
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
        const dir = std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp/app-it-{s}", .{self.name}) catch return;
        defer std.testing.allocator.free(dir);
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, dir) catch {};
    }
};

fn env(name: []const u8) !TestEnv {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    const dir = try std.fmt.allocPrint(allocator, "zig-cache/tmp/app-it-{s}", .{name});
    defer allocator.free(dir);
    const svc = try AppServices.init(allocator, io, dir);
    return .{ .arena = arena, .svc = svc, .name = name };
}

test "用户仓储：按组织 / 状态 / 关键字检索" {
    const e = try env("user-search");
    defer e.deinit(std.testing.io);

    const tech = (try e.svc.orgs.findByCode(e.a(), "tech")).?;
    const result = try e.svc.users.search(e.a(), .{ .org_id = tech.id }, 0, 10);
    try std.testing.expect(result.total >= 2); // manager + operator
    for (result.items) |u| try std.testing.expectEqual(tech.id, u.org_id);

    const disabled = try e.svc.users.search(e.a(), .{ .status = "disabled" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), disabled.total);
    try std.testing.expectEqualStrings("bob", disabled.items[0].username);

    const kw = try e.svc.users.search(e.a(), .{ .keyword = "ALICE" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), kw.total);
}

test "用户仓储：分页切片正确" {
    const e = try env("user-page");
    defer e.deinit(std.testing.io);

    const all = try e.svc.users.search(e.a(), .{}, 0, 100);
    const p0 = try e.svc.users.search(e.a(), .{}, 0, 2);
    const p1 = try e.svc.users.search(e.a(), .{}, 1, 2);

    try std.testing.expectEqual(all.total, p0.total);
    try std.testing.expectEqual(@as(usize, 2), p0.items.len);
    // seed 有 7 个用户，第 1 页（从 0 开始）还能取满 2 条；写成跟 total 相关的
    // 期望值，以后加演示用户不用改测试。
    const expect_p1 = if (all.total > 2) @min(2, all.total - 2) else 0;
    try std.testing.expectEqual(expect_p1, p1.items.len);
    try std.testing.expect(p0.items[0].id != p1.items[0].id);

    // 越界页返回空而不是 panic
    const far = try e.svc.users.search(e.a(), .{}, 99, 2);
    try std.testing.expectEqual(@as(usize, 0), far.items.len);
}

test "RBAC 仓储：角色权限全量替换 + 用户权限合并去重" {
    const e = try env("rbac");
    defer e.deinit(std.testing.io);

    const role = (try e.svc.rbac.findRoleByCode(e.a(), "operator")).?;
    try e.svc.rbac.setRolePermissions(role.id, &.{ "user:view", "user:create", "org:view" });
    var perms = try e.svc.rbac.permissionsOfRole(e.a(), role.id);
    try std.testing.expectEqual(@as(usize, 3), perms.len);

    // 全量替换：旧的不该残留
    try e.svc.rbac.setRolePermissions(role.id, &.{"user:view"});
    perms = try e.svc.rbac.permissionsOfRole(e.a(), role.id);
    try std.testing.expectEqual(@as(usize, 1), perms.len);
    try std.testing.expectEqualStrings("user:view", perms[0]);

    const alice = (try e.svc.users.findByUsername(e.a(), "alice")).?;
    const operator_role = (try e.svc.rbac.findRoleByCode(e.a(), "operator")).?;
    const auditor = (try e.svc.rbac.findRoleByCode(e.a(), "auditor")).?;
    try e.svc.rbac.setUserRoles(alice.id, &.{ operator_role.id, auditor.id });

    const merged = try e.svc.rbac.permissionsOfUser(e.a(), alice.id);
    // operator 1 个 + auditor 6 个，user:view / org:view 重复 → 6 个
    try std.testing.expectEqual(@as(usize, 6), merged.len);
    try std.testing.expect(model.rbac.hasPermission(merged, "log:export"));
    try std.testing.expect(!model.rbac.hasPermission(merged, "user:delete"));

    // seed 给演示用户 operator 也发了 operator 角色，加上刚分配的 alice 共 2 人。
    try std.testing.expectEqual(@as(usize, 2), try e.svc.rbac.countRoleUsers(operator_role.id));

    // 清空角色后权限归零
    try e.svc.rbac.setUserRoles(alice.id, &.{});
    try std.testing.expectEqual(@as(usize, 0), (try e.svc.rbac.permissionsOfUser(e.a(), alice.id)).len);
}

// ── 唯一约束（F-01 修复后的回归）────────────────────────────────────────
// service 层原来用「先查一遍再插入」实现唯一性，既有 TOCTOU 竞态，也让
// 约束散落在业务代码里。现在唯一性下沉到 ORM，service 只负责把
// error.UniqueViolation 翻回契约里的 USERNAME_TAKEN / EMAIL_TAKEN 等码，
// 所以这里锁的是**约束本身**——它漏了，上层映射得再对也没用。

fn userRow(username: []const u8, email: []const u8) model.user.Row {
    return .{
        .username = username,
        .display_name = username,
        .email = email,
        .password_hash = "x",
        .org_id = 0,
        .status = "active",
    };
}

test "ORM 唯一约束：用户名重复 → UniqueViolation" {
    const e = try env("uniq-username");
    defer e.deinit(std.testing.io);

    _ = try e.svc.users.insert(userRow("neo", "neo@example.com"));
    try std.testing.expectError(error.UniqueViolation, e.svc.users.insert(userRow("neo", "other@example.com")));
    // 冲突后什么都没写进去：表还是原来那 8 行（seed 7 + 上面 1）
    try std.testing.expectEqual(@as(usize, 8), try e.svc.users.countAll());
}

test "ORM 唯一约束：邮箱重复 → UniqueViolation" {
    const e = try env("uniq-email");
    defer e.deinit(std.testing.io);

    _ = try e.svc.users.insert(userRow("neo", "neo@example.com"));
    try std.testing.expectError(error.UniqueViolation, e.svc.users.insert(userRow("trinity", "neo@example.com")));
}

test "ORM 唯一约束：update 改成别人的邮箱 → UniqueViolation" {
    const e = try env("uniq-update");
    defer e.deinit(std.testing.io);

    const alice = (try e.svc.users.findByUsername(e.a(), "alice")).?;
    var dup = alice;
    dup.email = "bob@example.com"; // bob 的邮箱
    try std.testing.expectError(error.UniqueViolation, e.svc.users.update(dup));

    // 改成自己的邮箱不该冲突（except_id 把自己排除掉）
    var same = alice;
    same.display_name = "爱丽丝2";
    try std.testing.expect(try e.svc.users.update(same));
}

test "ORM 唯一约束：组织编码 / 角色编码重复 → UniqueViolation" {
    const e = try env("uniq-code");
    defer e.deinit(std.testing.io);

    try std.testing.expectError(
        error.UniqueViolation,
        e.svc.orgs.insert(.{ .name = "重名", .code = "hq", .parent_id = 0, .leader = "", .sort_order = 0 }),
    );
    try std.testing.expectError(
        error.UniqueViolation,
        e.svc.rbac.insertRole(.{ .code = "operator", .name = "重名", .description = "", .is_builtin = false }),
    );
}

test "审计仓储：写入后可按模块/时间范围/关键字检索并倒序返回" {
    const e = try env("audit");
    defer e.deinit(std.testing.io);

    try insertLog(e.svc, 1, "admin", "user", "user.create", 1000);
    try insertLog(e.svc, 2, "manager", "org", "org.move", 2000);
    try insertLog(e.svc, 1, "admin", "user", "user.delete", 3000);

    var r = try e.svc.audit.search(e.a(), .{ .module = "user" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 2), r.total);
    // 倒序：最新在前
    try std.testing.expectEqualStrings("user.delete", r.items[0].action);

    r = try e.svc.audit.search(e.a(), .{ .from = 1500, .to = 2500 }, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), r.total);

    r = try e.svc.audit.search(e.a(), .{ .keyword = "MANAGER" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), r.total);

    r = try e.svc.audit.search(e.a(), .{ .actor_id = 1 }, 0, 10);
    try std.testing.expectEqual(@as(usize, 2), r.total);
}

test "审计仓储：清理旧日志" {
    const e = try env("audit-purge");
    defer e.deinit(std.testing.io);

    try insertLog(e.svc, 1, "admin", "user", "user.create", 1000);
    try insertLog(e.svc, 1, "admin", "user", "user.update", 5000);
    const removed = try e.svc.audit.purgeBefore(3000);
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), try e.svc.audit.countAll());
}

fn insertLog(svc: *AppServices, actor_id: u64, actor: []const u8, module: []const u8, action: []const u8, at: u64) !void {
    _ = try svc.audit.insert(.{
        .actor_id = actor_id,
        .actor_name = actor,
        .module = module,
        .action = action,
        .target_type = "user",
        .target_id = 1,
        .target_label = "target",
        .result = "success",
        .message = "m",
        .changes = "[]",
        .ip = "127.0.0.1",
        .request_id = "rid",
        .created_at = at,
    });
}

test "审批仓储：状态过滤与待审批计数" {
    const e = try env("approval");
    defer e.deinit(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), try e.svc.approvals.countPending());

    var r = try e.svc.approvals.search(e.a(), .{ .status = "pending" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), r.total);

    r = try e.svc.approvals.search(e.a(), .{ .status = "approved" }, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), r.total);

    // 审批通过后待办数归零
    var row = (try e.svc.approvals.findById(e.a(), 1)).?;
    row.status = "approved";
    try std.testing.expect(try e.svc.approvals.update(row));
    try std.testing.expectEqual(@as(usize, 0), try e.svc.approvals.countPending());
}

test "组织仓储：成员数与子组织数统计" {
    const e = try env("org");
    defer e.deinit(std.testing.io);

    const hq = (try e.svc.orgs.findByCode(e.a(), "hq")).?;
    try std.testing.expectEqual(@as(usize, 2), try e.svc.orgs.countChildren(hq.id));
    try std.testing.expectEqual(@as(usize, 1), try e.svc.orgs.countMembers(hq.id));

    const tech = (try e.svc.orgs.findByCode(e.a(), "tech")).?;
    const rows = try e.svc.orgs.all(e.a());
    const subtree = try model.org.subtreeIds(e.a(), rows, tech.id);
    // tech + backend + frontend
    try std.testing.expectEqual(@as(usize, 3), subtree.len);
}

test "组织树：构建出来的树形结构与种子数据一致" {
    const e = try env("org-tree");
    defer e.deinit(std.testing.io);

    const rows = try e.svc.orgs.all(e.a());
    const tree = try buildTreeVia(e, rows);
    defer model.org.freeTree(e.a(), tree);

    try std.testing.expectEqual(@as(usize, 1), tree.len); // 单根 hq
    try std.testing.expectEqualStrings("总公司", tree[0].name);
    try std.testing.expectEqual(@as(usize, 2), tree[0].children.len); // tech / market
    const backend = tree[0].children[0].children[0];
    try std.testing.expectEqualStrings("后端组", backend.name);
}

fn buildTreeVia(e: TestEnv, rows: []const model.org.Row) ![]model.org.TreeNode {
    const views = try e.a().alloc(model.org.View, rows.len);
    for (rows, 0..) |r, i| {
        views[i] = .{
            .id = r.id,
            .name = r.name,
            .code = r.code,
            .parent_id = r.parent_id,
            .leader = r.leader,
            .sort_order = r.sort_order,
            .member_count = 0,
            .created_at = r.created_at,
            .updated_at = r.updated_at,
        };
    }
    return model.org.buildTree(e.a(), views);
}

test {
    std.testing.refAllDecls(@This());
}
