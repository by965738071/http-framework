//! 审计日志服务：写日志 + 检索 + 导出。
//!
//! 所有会改变系统状态的操作都要经这里留痕，含字段级 diff。

const std = @import("std");
const framework = @import("http_framework");
const repo = @import("../repo/mod.zig");
const model = @import("../model/mod.zig");
const core = @import("../core/mod.zig");
const container = @import("container.zig");

const AppServices = container.AppServices;
const Row = model.audit.Row;

pub const Record = struct {
    module: []const u8,
    action: []const u8,
    target_type: []const u8 = "",
    target_id: u64 = 0,
    target_label: []const u8 = "",
    result: []const u8 = "success",
    message: []const u8 = "",
    /// 字段级 diff 的 JSON 文本（core.diff.changesToJson），无变更时为 "[]"
    changes: []const u8 = "[]",
};

/// 写一条审计日志。`ctx` 用于取 IP 与 request_id，可传 null（如系统内部动作）。
pub fn record(
    svc: *AppServices,
    ctx: ?*const framework.Context,
    actor_id: u64,
    actor_name: []const u8,
    rec: Record,
) !void {
    var ip_buf: [64]u8 = undefined;
    const ip: []const u8 = if (ctx) |c| (c.peerIpString(&ip_buf) orelse "") else "";
    var rid: []const u8 = "";
    if (ctx) |c| {
        if (c.getUserData(framework.RequestId)) |r| rid = r.slice();
    }
    const entry = Row{
        .actor_id = actor_id,
        .actor_name = actor_name,
        .module = rec.module,
        .action = rec.action,
        .target_type = rec.target_type,
        .target_id = rec.target_id,
        .target_label = rec.target_label,
        .result = rec.result,
        .message = rec.message,
        .changes = rec.changes,
        .ip = ip,
        .request_id = rid,
        .created_at = svc.nowMs(),
    };
    _ = try svc.audit.insert(entry);
}

pub fn search(
    svc: *AppServices,
    alloc: std.mem.Allocator,
    filter: repo.AuditFilter,
    page: usize,
    page_size: usize,
) !repo.SearchResult(Row) {
    return svc.audit.search(alloc, filter, page, page_size);
}

/// 导出（忽略分页）。
pub fn searchAll(svc: *AppServices, alloc: std.mem.Allocator, filter: repo.AuditFilter) ![]Row {
    return svc.audit.searchAll(alloc, filter);
}

/// 清理 `before_ms` 之前的日志，返回删除条数。
pub fn purge(svc: *AppServices, before_ms: u64) !usize {
    const n = try svc.audit.purgeBefore(before_ms);
    try record(svc, null, 0, "system", .{
        .module = "log",
        .action = "log.purge",
        .target_type = "audit_log",
        .message = "清理历史审计日志",
    });
    return n;
}

/// 把审计行导出成 CSV（UTF-8 带 BOM，Excel 直接打开不乱码）。
/// 纯函数，可单测。
pub fn toCsv(allocator: std.mem.Allocator, rows: []const Row) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("\xEF\xBB\xBF");
    try w.writeAll("id,actor_id,actor_name,module,action,target_type,target_id,target_label,result,message,changes,ip,created_at\n");
    for (rows) |r| {
        const ts = try core.util.formatTimestamp(allocator, @intCast(r.created_at));
        defer allocator.free(ts);
        try w.writeAll(try std.fmt.allocPrint(allocator, "{d},", .{r.id}));
        try w.writeAll(try std.fmt.allocPrint(allocator, "{d},", .{r.actor_id}));
        try writeCsvField(w, r.actor_name);
        try w.writeAll(",");
        try writeCsvField(w, r.module);
        try w.writeAll(",");
        try writeCsvField(w, r.action);
        try w.writeAll(",");
        try writeCsvField(w, r.target_type);
        try w.writeAll(",");
        try w.writeAll(try std.fmt.allocPrint(allocator, "{d},", .{r.target_id}));
        try writeCsvField(w, r.target_label);
        try w.writeAll(",");
        try writeCsvField(w, r.result);
        try w.writeAll(",");
        try writeCsvField(w, r.message);
        try w.writeAll(",");
        try writeCsvField(w, r.changes);
        try w.writeAll(",");
        try writeCsvField(w, r.ip);
        try w.writeAll(",");
        try w.writeAll(ts);
        try w.writeAll("\n");
    }
    return allocator.dupe(u8, out.written());
}

fn writeCsvField(w: *std.Io.Writer, value: []const u8) !void {
    const needs_quote = std.mem.indexOfAny(u8, value, &.{ ',', '"', '\n', '\r' }) != null;
    if (!needs_quote) {
        try w.writeAll(value);
        return;
    }
    try w.writeByte('"');
    for (value) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

// ── 测试 ──────────────────────────────────────────────────────────

fn row(id: u64, actor: []const u8, module: []const u8, action: []const u8) Row {
    return .{
        .id = id,
        .actor_id = 1,
        .actor_name = actor,
        .module = module,
        .action = action,
        .target_type = "user",
        .target_id = 2,
        .target_label = "alice",
        .result = "success",
        .message = "msg",
        .changes = "[{\"field\":\"name\",\"before\":\"a\",\"after\":\"b\"}]",
        .ip = "127.0.0.1",
        .request_id = "r",
        .created_at = 0,
    };
}

test "toCsv 输出 BOM 与表头" {
    const csv = try toCsv(std.testing.allocator, &.{});
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.startsWith(u8, csv, "\xEF\xBB\xBFid,actor_id"));
}

test "toCsv 含逗号的字段被引号包裹并转义" {
    const rows = [_]Row{row(1, "ad,min", "user", "user.create")};
    const csv = try toCsv(std.testing.allocator, &rows);
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "\"ad,min\"") != null);
}

test "toCsv JSON 里的双引号被转义成两个" {
    const rows = [_]Row{row(1, "admin", "user", "user.create")};
    const csv = try toCsv(std.testing.allocator, &rows);
    defer std.testing.allocator.free(csv);
    // CSV 里 JSON 的双引号应被转义成两个：{"field":...} → ""{""field""...
    try std.testing.expect(std.mem.indexOf(u8, csv, "[{\"\"field\"\":\"\"name\"\"") != null);
}

test {
    std.testing.refAllDecls(@This());
}
