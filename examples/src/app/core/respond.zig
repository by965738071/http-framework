//! 统一响应封装。
//!
//! 成功：`{"code":"OK","data":...}`
//! 分页：`{"code":"OK","data":{"items":[...],"total":42,"page":1,"page_size":20}}`
//! 失败：`{"code":"XXX","message":"...","details":{...}}`
//!
//! 所有 handler 只准通过这里写响应，避免各写一套字段名。

const std = @import("std");
const framework = @import("http_framework");
const errors = @import("errors.zig");

pub const OK: []const u8 = "OK";

pub fn ok(res: *framework.Response, data: anytype) !void {
    try res.json(.{ .code = OK, .data = data });
}

/// 无业务数据时回一个空对象，前端不用判断 null。
pub fn okEmpty(res: *framework.Response) !void {
    try res.json(.{ .code = OK, .data = .{} });
}

pub fn okMessage(res: *framework.Response, message: []const u8) !void {
    try res.json(.{ .code = OK, .message = message, .data = .{} });
}

pub fn page(
    res: *framework.Response,
    items: anytype,
    total: usize,
    page_no: usize,
    page_size: usize,
) !void {
    try res.json(.{
        .code = OK,
        .data = .{
            .items = items,
            .total = total,
            .page = page_no,
            .page_size = page_size,
        },
    });
}

/// 把 ApiError 渲染成 JSON 响应。
pub fn writeError(allocator: std.mem.Allocator, res: *framework.Response, err: errors.ApiError) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"code\":");
    try writeJsonString(w, err.code);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, err.message);
    if (err.details_json) |d| {
        try w.writeAll(",\"details\":");
        try w.writeAll(d);
    }
    try w.writeAll("}");
    _ = res.statusCode(err.status);
    try res.raw(out.written(), "application/json");
}

/// 最小 JSON 字符串转义（只处理必须转义的字符）。
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// 把任意值序列化成 JSON 文本（用于 error details 片段）。
pub fn toJson(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(value);
    return allocator.dupe(u8, out.written());
}

test "writeJsonString 转义特殊字符" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeJsonString(&buf.writer, "a\"b\\c\nd\te\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", buf.written());
}

test "toJson 序列化匿名结构体" {
    const s = try toJson(std.testing.allocator, .{ .a = 1, .b = "x" });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":\"x\"}", s);
}

test {
    std.testing.refAllDecls(@This());
}
