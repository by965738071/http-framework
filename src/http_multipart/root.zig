//! http_multipart — multipart/form-data 解析（依赖 http_app, http_protocol）
//!
//! 实现 RFC 2046 multipart/form-data 解析，支持普通字段 + 文件上传。
//!
//! 设计：
//! - 解析结果存入 arena，请求结束自动回收
//! - 提供 `FormData` 封装，handler 用 `form.getText("name")` / `form.getFile("avatar")`
//! - 不依赖 std.http（没有），纯字节解析
//!
//! 用法（handler 里）：
//! ```zig
//! fn upload(ctx: *Context, res: *Response) !void {
//!     var form = try http_multipart.from(ctx, 10 * 1024 * 1024); // 10MB
//!     const username = form.getText("username") orelse "anonymous";
//!     if (form.getFile("avatar")) |file| {
//!         // file.file_name, file.content_type, file.data
//!     }
//! }
//! ```

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Request = http_protocol.Request;
pub const Context = http_app.Context;

/// 解析后的文件字段。
pub const FileField = struct {
    name: []const u8, // field name (e.g. "avatar")
    file_name: ?[]const u8, // filename from Content-Disposition（原始，未清洗）
    content_type: ?[]const u8, // Content-Type of this part
    data: []const u8, // file content

    /// 返回可安全用于文件系统的基名：剥掉任何路径成分（`/`、`\`），
    /// 拒绝 `.`/`..`。防止调用方直接用 file_name 拼盘造成路径穿越/覆盖。
    /// 无有效基名时返回 null——调用方应改用自己生成的名字。
    pub fn safeBaseName(self: FileField) ?[]const u8 {
        const raw = self.file_name orelse return null;
        if (raw.len == 0) return null;
        // 取最后一个 `/` 或 `\` 之后的部分。
        var start: usize = 0;
        for (raw, 0..) |c, i| {
            if (c == '/' or c == '\\') start = i + 1;
        }
        const base = raw[start..];
        if (base.len == 0) return null;
        if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
        // 含 NUL 的名字拒绝（防止截断攻击）。
        if (std.mem.indexOfScalar(u8, base, 0) != null) return null;
        return base;
    }
};

/// 单个 multipart 请求允许的最大 part 数，防止构造海量极小 part 放大内存/CPU。
pub const MAX_PARTS = 1024;

/// 解析后的 multipart 表单。
/// 所有字段切片都指向 arena 分配的内存。
pub const FormData = struct {
    fields: std.StringHashMapUnmanaged([]const u8) = .empty,
    files: std.StringHashMapUnmanaged(FileField) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FormData) void {
        // HashMap 内部桶需要释放；key/value 在 arena 上自动回收。
        self.fields.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    /// 获取普通文本字段值。
    pub fn getText(self: *const FormData, key: []const u8) ?[]const u8 {
        return self.fields.get(key);
    }

    /// 获取文件字段。
    pub fn getFile(self: *const FormData, key: []const u8) ?FileField {
        return self.files.get(key);
    }
};

/// 解析 Content-Type 头里的 boundary 参数。
/// `multipart/form-data; boundary=----WebKitFormBoundaryxxx`
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const boundary_key = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, boundary_key) orelse return null;
    var boundary = content_type[idx + boundary_key.len ..];
    // boundary 可能被引号包围
    if (boundary.len > 0 and boundary[0] == '"') {
        boundary = boundary[1..];
        const end = std.mem.indexOfScalar(u8, boundary, '"') orelse return null;
        return boundary[0..end];
    }
    // 无引号：在第一个 `;` 或空白处截断（否则 `boundary=xyz; charset=..` 会把
    // 后面的参数当成分隔符的一部分，导致解析不出 parts）。
    for (boundary, 0..) |c, i| {
        if (c == ';' or c == ' ' or c == '\t') return boundary[0..i];
    }
    return boundary;
}

/// 从 Context 解析 multipart 表单。
/// `limit` 是 body 最大字节数。
pub fn from(ctx: *Context, limit: u64) !FormData {
    const ct = ctx.request.content_type orelse return error.NotMultipart;
    // 媒体类型大小写不敏感（RFC 9110 §8.3.1）。
    if (!std.ascii.startsWithIgnoreCase(ct, "multipart/form-data")) {
        return error.NotMultipart;
    }
    const boundary_raw = extractBoundary(ct) orelse return error.MissingBoundary;
    // 实际分隔符是 "--" + boundary
    const delimiter = try std.fmt.allocPrint(ctx.arena, "--{s}", .{boundary_raw});

    const body = try ctx.readBody(ctx.arena, limit);
    return parseBody(ctx.arena, body, delimiter);
}

/// 从 body 字节解析 multipart 表单。
pub fn parseBody(allocator: std.mem.Allocator, body: []const u8, delimiter: []const u8) !FormData {
    var form = FormData{ .allocator = allocator };

    // 每个 part 以 \r\n--boundary\r\n 分隔
    // 第一个 part 前面有 --boundary\r\n
    // 最后一个 part 后面有 --boundary--\r\n
    var pos: usize = 0;

    // 找第一个 delimiter
    const first_delim = std.mem.indexOf(u8, body, delimiter) orelse return form;
    pos = first_delim + delimiter.len;

    // 修复 M3：next_delim_search 在循环外分配一次复用（而非每轮 allocPrint），
    // 并限制 part 数上限，防止海量极小 part 放大内存/CPU。
    const next_delim_search = try std.fmt.allocPrint(allocator, "\r\n{s}", .{delimiter});
    var part_count: usize = 0;

    while (pos < body.len) {
        // 检查是否是结束标记 --\r\n
        if (pos + 2 <= body.len and body[pos] == '-' and body[pos + 1] == '-') {
            break;
        }
        // 跳过 \r\n（delimiter 后面）
        if (pos + 2 <= body.len and body[pos] == '\r' and body[pos + 1] == '\n') {
            pos += 2;
        }

        part_count += 1;
        if (part_count > MAX_PARTS) return error.TooManyParts;

        // 找下一个 delimiter（以 \r\n 开头）
        const part_end = std.mem.indexOfPos(u8, body, pos, next_delim_search) orelse break;
        const part_data = body[pos..part_end];

        // 解析这个 part
        try parsePart(allocator, part_data, &form);

        // 移动到下一个 part
        pos = part_end + 2 + delimiter.len;
    }

    return form;
}

fn parsePart(allocator: std.mem.Allocator, part: []const u8, form: *FormData) !void {
    // part 结构：
    // Content-Disposition: form-data; name="field"; filename="file.txt"\r\n
    // Content-Type: application/octet-stream\r\n
    // \r\n
    // <body>\r\n

    // 找 \r\n\r\n 分隔头和体
    const header_body_sep = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return;
    const header_block = part[0..header_body_sep];
    const body_data = part[header_body_sep + 4 ..];

    var field_name: ?[]const u8 = null;
    var file_name: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;

    // 逐行解析头
    var header_it = std.mem.splitSequence(u8, header_block, "\r\n");
    while (header_it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Disposition:")) {
            // 先取 filename（包含 `name=` 子串），再取 name——避免 name= 误匹配
            // filename= 里的 name= 子串。extractParam 按分隔 token 匹配 key。
            file_name = extractParam(line, "filename");
            field_name = extractParam(line, "name");
        } else if (std.ascii.startsWithIgnoreCase(line, "Content-Type:")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            content_type = std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    const name = field_name orelse return;

    if (file_name != null) {
        // 文件字段
        try form.files.put(allocator, name, .{
            .name = name,
            .file_name = file_name,
            .content_type = content_type,
            .data = body_data,
        });
    } else {
        // 普通字段
        try form.fields.put(allocator, name, body_data);
    }
}

/// 从 Content-Disposition 行里提取 `key="value"` 的 value。
/// 按分隔 token 匹配（前面是行首、`;` 或空白），避免 `name` 误匹配 `filename`。
/// 零分配（不再用 page_allocator 拼 search 串）。
fn extractParam(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        // 定位下一个 key
        const found = std.mem.indexOfPos(u8, line, i, key) orelse return null;
        // key 前一字符必须是分隔符（行首 / `;` / 空白），否则是子串误匹配。
        const boundary_ok = found == 0 or line[found - 1] == ';' or line[found - 1] == ' ' or line[found - 1] == '\t';
        const after = found + key.len;
        if (boundary_ok and after < line.len and line[after] == '=') {
            var v = line[after + 1 ..];
            if (v.len > 0 and v[0] == '"') {
                v = v[1..];
                const end = std.mem.indexOfScalar(u8, v, '"') orelse return null;
                return v[0..end];
            }
            // 无引号：到 `;` 或行尾
            const end = std.mem.indexOfScalar(u8, v, ';') orelse v.len;
            return std.mem.trim(u8, v[0..end], " \t");
        }
        i = found + key.len;
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "extractBoundary parses plain boundary" {
    const ct = "multipart/form-data; boundary=----WebKitFormBoundaryABC";
    const b = extractBoundary(ct).?;
    try std.testing.expectEqualStrings("----WebKitFormBoundaryABC", b);
}

test "extractBoundary parses quoted boundary" {
    const ct = "multipart/form-data; boundary=\"----my boundary\"";
    const b = extractBoundary(ct).?;
    try std.testing.expectEqualStrings("----my boundary", b);
}

test "extractBoundary returns null when not multipart" {
    try std.testing.expect(extractBoundary("application/json") == null);
}

test "parseBody extracts text field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    try std.testing.expectEqualStrings("alice", form.getText("username").?);
}

test "parseBody extracts file field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const png_header = "\x89PNG\r\n\x1a\n";
    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"photo.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        png_header ++
        "\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    const file = form.getFile("avatar").?;
    try std.testing.expectEqualStrings("photo.png", file.file_name.?);
    try std.testing.expectEqualStrings("image/png", file.content_type.?);
    try std.testing.expectEqual(@as(usize, 8), file.data.len);
}

test "parseBody handles multiple fields" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"name\"\r\n" ++
        "\r\n" ++
        "bob\r\n" ++
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"age\"\r\n" ++
        "\r\n" ++
        "25\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    try std.testing.expectEqualStrings("bob", form.getText("name").?);
    try std.testing.expectEqualStrings("25", form.getText("age").?);
}

test {
    std.testing.refAllDecls(@This());
}
