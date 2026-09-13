//! 服务容器 —— 进程级单例，持有 DB 句柄与各个仓储实例。
//!
//! 分层铁律：`handler` 拿到的只有 `*AppServices`，但**只能调用 service 层的
//! 函数**；`repo` 与 `db` 字段只被 service 层使用。

const std = @import("std");
const repo = @import("../repo/mod.zig");
const core = @import("../core/mod.zig");
const seed = @import("seed.zig");

pub const AppServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *repo.Database,

    users: repo.UserRepository,
    orgs: repo.OrgRepository,
    rbac: repo.RbacRepository,
    audit: repo.AuditRepository,
    approvals: repo.ApprovalRepository,

    notifier: *core.notify.Notifier,

    /// 打开（必要时创建并 seed）全部数据表。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !*AppServices {
        const db = try repo.Database.open(allocator, io, data_dir);
        errdefer db.close();

        const notifier = try allocator.create(core.notify.Notifier);
        errdefer allocator.destroy(notifier);
        notifier.* = core.notify.Notifier.init(allocator, io);

        const self = try allocator.create(AppServices);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .db = db,
            .users = .{ .db = db },
            .orgs = .{ .db = db },
            .rbac = .{ .db = db },
            .audit = .{ .db = db },
            .approvals = .{ .db = db },
            .notifier = notifier,
        };

        const seeded = try seed.run(self);
        std.log.info(
            "seed done: permissions={d} roles={d} orgs={d} users={d} approvals={d}",
            .{ seeded.permissions, seeded.roles, seeded.orgs, seeded.users, seeded.approvals },
        );
        return self;
    }

    pub fn deinit(self: *AppServices) void {
        const allocator = self.allocator;
        self.notifier.deinit();
        allocator.destroy(self.notifier);
        self.db.close();
        allocator.destroy(self);
    }

    pub fn nowMs(self: *const AppServices) u64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms));
    }
};

test {
    std.testing.refAllDecls(@This());
}
