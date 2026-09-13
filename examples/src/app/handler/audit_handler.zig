//! 审计日志 handler：检索 / 导出 / 清理。

const std = @import("std");
const framework = @import("http_framework");
const core = @import("../core/mod.zig");
const repo = @import("../repo/mod.zig");
const service = @import("../service/mod.zig");
const mod = @import("mod.zig");

const AppServices = service.AppServices;

fn parseFilter(ctx: *framework.Context) !repo.AuditFilter {
    var filter = repo.AuditFilter{
        .module = core.util.queryStr(ctx, "module", ""),
        .action = core.util.queryStr(ctx, "action", ""),
        .result = core.util.queryStr(ctx, "result", ""),
        .keyword = core.util.queryStr(ctx, "keyword", ""),
        .from = core.util.queryInt(ctx, "from", 0),
        .to = core.util.queryInt(ctx, "to", 0),
    };
    const actor_raw = core.util.queryStr(ctx, "actor_id", "");
    if (actor_raw.len > 0) {
        filter.actor_id = std.fmt.parseInt(u64, actor_raw, 10) catch {
            try core.errors.fail(ctx, core.errors.ApiError.badRequest(core.errors.codes.validation_error, "actor_id 必须是整数"));
            return error.Unreachable;
        };
    }
    return filter;
}

pub fn list(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const p = mod.paging(ctx);
    const result = try service.audit_service.search(svc, ctx.arena, try parseFilter(ctx), p.page, p.page_size);
    try core.respond.page(res, result.items, result.total, p.page + 1, p.page_size);
}

/// 导出 CSV 文件下载。
pub fn exportCsv(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const rows = try service.audit_service.searchAll(svc, ctx.arena, try parseFilter(ctx));
    const csv = try service.audit_service.toCsv(ctx.arena, rows);
    try service.audit_service.record(svc, ctx, actor.id, actor.username, .{
        .module = "log",
        .action = "log.export",
        .target_type = "audit_log",
        .message = try std.fmt.allocPrint(ctx.arena, "导出 {d} 条审计日志", .{rows.len}),
    });
    _ = try res.setHeader("Content-Disposition", "attachment; filename=\"audit-logs.csv\"");
    try res.raw(csv, "text/csv; charset=utf-8");
}

/// 清理 N 天前的日志。
pub fn purge(svc: *AppServices, ctx: *framework.Context, res: *framework.Response) !void {
    const actor = try mod.requireActor(ctx);
    const days = core.util.queryInt(ctx, "days", 90);
    const before = svc.nowMs() -| (days * 24 * 60 * 60 * 1000);
    const n = try service.audit_service.purge(svc, before);
    _ = actor;
    try core.respond.ok(res, .{ .deleted = n });
}
