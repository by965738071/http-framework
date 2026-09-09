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

    /// 返回可安全用于文件系统的基名：
    /// - 剥掉任何路径成分（取最后一个 `/` 或 `\` 之后的部分）。
    /// - 拒绝空、`.`/`..`、NUL 及控制字符（0x00-0x1F、0x7F）。
    /// - 拒绝 `:` —— Windows 上是盘符相对路径（`C:evil.txt`）或 NTFS
    ///   备用数据流（`photo.jpg:$DATA`）。
    /// - 拒绝结尾 `.`/空格 —— Windows 会规范化剥离，`hosts.` 与 `hosts`
    ///   是同一文件，可用来绕过扩展名黑名单。
    /// - 拒绝 Windows 保留设备名（CON/PRN/AUX/NUL/COM0-9/LPT0-9，大小写
    ///   不敏感，带扩展名同样成立，如 `nul.txt`）。
    /// 无有效基名时返回 null——调用方应改用自己生成的名字。
    ///
    /// 注：file_name 是 extractParam 的**原文**（引号内 `\` 转义序列不还原），
    /// 故可能含字面 `\`；此处一律按路径分隔符处理并剥掉。
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
        for (base) |c| {
            // NUL（截断攻击）、控制字符、`:`（盘符/ADS）一律拒绝。
            if (c < 0x20 or c == 0x7F or c == ':') return null;
        }
        if (base[base.len - 1] == '.' or base[base.len - 1] == ' ') return null;
        if (isWindowsReservedName(base)) return null;
        return base;
    }
};

/// Windows 保留设备名判定（大小写不敏感）：首个 `.` 之前的部分命中列表即
/// 保留名——`nul`、`com1.log` 这类名字在 Windows 上根本创建不了普通文件。
fn isWindowsReservedName(base: []const u8) bool {
    const reserved = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",
        "COM0", "COM1", "COM2", "COM3",
        "COM4", "COM5", "COM6", "COM7",
        "COM8", "COM9", "LPT0", "LPT1",
        "LPT2", "LPT3", "LPT4", "LPT5",
        "LPT6", "LPT7", "LPT8", "LPT9",
    };
    const stem = std.mem.sliceTo(base, '.');
    for (reserved) |r| {
        if (std.ascii.eqlIgnoreCase(stem, r)) return true;
    }
    return false;
}

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
/// 按 `;` 切参数，精确匹配 `boundary=` token（修复 M17：`xboundary=` 不再误匹配），
/// 并拒绝空值 / 超 70 字符（RFC 2046 §5.1.1）。
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    var params = std.mem.splitSequence(u8, content_type, ";");
    _ = params.next(); // 跳过媒体类型 "multipart/form-data"
    while (params.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        if (!std.ascii.startsWithIgnoreCase(param, "boundary=")) continue;
        var boundary = param["boundary=".len..];
        // 引号包围：剥掉首尾引号
        if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
            boundary = boundary[1 .. boundary.len - 1];
        }
        // RFC 2046 §5.1.1：boundary 必须非空且 ≤70 字符，否则视为无有效 boundary。
        if (boundary.len == 0) return null;
        if (boundary.len > 70) return null;
        return boundary;
    }
    return null;
}

/// 从 Context 解析 multipart 表单。
/// `limit` 是 body 最大字节数。
///
/// 错误 → 建议状态码（调用方应逐项映射到 failWith/ErrorRenderer，
/// **不要一律 catch 成 400**——那会把 413/500 的语义吞掉）：
/// - `error.NotMultipart` / `error.MissingBoundary` → 400（Content-Type 不对）
/// - `error.TooManyParts` / `error.MalformedPart` / `error.DuplicateField` → 400
///   （构造畸形或不符合本解析器模型的表单）
/// - `error.BodyTooLarge` → 413（body 超过 `limit`）。若 body 是 chunked，
///   回 413 时调用方**必须** `res.keep_alive = false`：std 不会排空残留的
///   半截 chunk 流，复用连接会把残留字节当成下一个请求（CL 超限在建
///   reader 前拦截，无此问题，但统一关连接最稳）。
/// - `error.OutOfMemory` → 500（应继续向上传播，不要拦截为客户端错误）
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

/// 校验 delimiter 之后两字节是否合法后继：`\r\n`（下一个 part）或 `--`
/// （结束标记）。单字节判断会把 `\r\n--boundary\rZ`、`--boundary-Z` 这类
/// 内容里的边界前缀误判成分隔符（M18 校验的补全）。
fn delimSuffixOk(body: []const u8, after: usize) bool {
    if (after + 2 > body.len) return false;
    const pair = body[after..][0..2];
    return std.mem.eql(u8, pair, "\r\n") or std.mem.eql(u8, pair, "--");
}

/// 从 body 字节解析 multipart 表单。错误传播与状态码映射见 `from`。
pub fn parseBody(allocator: std.mem.Allocator, body: []const u8, delimiter: []const u8) !FormData {
    var form = FormData{ .allocator = allocator };
    // 中途出错时（如 TooManyParts / 分配失败）释放已 put 的哈希桶（修复 M 低危）。
    errdefer form.deinit();

    // 每个 part 以 \r\n--boundary\r\n 分隔
    // 第一个 part 前面有 --boundary\r\n
    // 最后一个 part 后面有 --boundary--\r\n
    // 找第一个 delimiter：必须位于行首（body 开头或前面是 \r\n）且后继合法。
    // preamble（RFC 2046 允许首边界前有任意文本）可能包含边界前缀子串，
    // 裸 indexOf 会假命中（补全 M18 同款校验）。
    var first_delim: ?usize = null;
    {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, body, search_from, delimiter)) |found| {
            const at_line_start = found == 0 or
                (found >= 2 and std.mem.eql(u8, body[found - 2 .. found], "\r\n"));
            if (at_line_start and delimSuffixOk(body, found + delimiter.len)) {
                first_delim = found;
                break;
            }
            search_from = found + 1;
        }
    }
    // 无有效首分隔符：视为空表单（保持旧语义，不报错）。
    const fd = first_delim orelse return form;
    var pos: usize = fd + delimiter.len;

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

        // 找下一个 delimiter（以 \r\n 开头）。命中后必须校验后继字节是
        // \r\n（下一个 part）或 --（结束标记）；否则是文件内容里的边界子串，
        // 继续向后找，避免假分割（修复 M18）。
        var search_from = pos;
        var part_end: ?usize = null;
        while (part_end == null) {
            const found = std.mem.indexOfPos(u8, body, search_from, next_delim_search) orelse break;
            // 后继两字节必须是 \r\n 或 --，否则是内容里的边界子串（旧单字节
            // 判断遇 `\rZ`/`-Z` 会假分割），继续向后找。
            if (delimSuffixOk(body, found + next_delim_search.len)) {
                part_end = found;
            } else {
                search_from = found + 1; // 假命中（boundary 是更长 token 的前缀），往后找
            }
        }
        const pe = part_end orelse break;
        const part_data = body[pos..pe];

        // 解析这个 part
        try parsePart(allocator, part_data, &form);

        // 移动到下一个 part
        pos = pe + 2 + delimiter.len;
    }

    return form;
}

fn parsePart(allocator: std.mem.Allocator, part: []const u8, form: *FormData) !void {
    // part 结构：
    // Content-Disposition: form-data; name="field"; filename="file.txt"\r\n
    // Content-Type: application/octet-stream\r\n
    // \r\n
    // <body>\r\n

    // 找 \r\n\r\n 分隔头和体。P2-27：找不到则这是个畸形 part，
    // 报错而不是静默丢弃（旧代码 return 会让畸形表单看起来“少了一个字段”）。
    const header_body_sep = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return error.MalformedPart;
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

    // 与 P2-27「畸形要响」同一精神：没有 name= 或 name 为空的 part 既不能
    // 静默丢弃（表单会「少字段」），也不能拿空串当 key。
    const name = field_name orelse return error.MalformedPart;
    if (name.len == 0) return error.MalformedPart;

    if (file_name != null) {
        // 文件字段。P2-26：重名 part（如 <input multiple> 多文件）此前被
        // put 静默覆盖只剩最后一个；现在显式报 DuplicateField——本解析器
        // 的 name→单值模型承载不了多值，调用方应拒绝该表单。
        if (form.files.contains(name)) return error.DuplicateField;
        try form.files.put(allocator, name, .{
            .name = name,
            .file_name = file_name,
            .content_type = content_type,
            .data = body_data,
        });
    } else {
        if (form.fields.contains(name)) return error.DuplicateField;
        try form.fields.put(allocator, name, body_data);
    }
}

/// 从 Content-Disposition 行里提取 `key="value"` 的 value。
/// 按分隔 token 匹配（前面是行首、`;` 或空白），避免 `name` 误匹配 `filename`。
/// 零分配（不再用 page_allocator 拼 search 串）。
fn extractParam(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        // 进入引号：跳过直到闭合引号（处理 \ 转义），引号内的 key 子串不参与匹配
        // （修复 M16：`filename="a; name=b"` 不能注入假的 `name` token）。
        if (c == '"') {
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\') {
                    i += 2; // 跳过转义字符与下一个字符
                } else {
                    const closed = line[i] == '"'; // 记录后再 i+=1
                    i += 1;
                    if (closed) break;
                }
            }
            continue;
        }
        // 非引号上下文：尝试匹配 key。
        if (i + key.len <= line.len and std.mem.eql(u8, line[i .. i + key.len], key)) {
            const boundary_ok = i == 0 or line[i - 1] == ';' or line[i - 1] == ' ' or line[i - 1] == '\t';
            const after = i + key.len;
            if (boundary_ok and after < line.len and line[after] == '=') {
                var v = line[after + 1 ..];
                if (v.len > 0 and v[0] == '"') {
                    v = v[1..];
                    // 找到闭合引号（跳过 `\"` 转义），返回引号内内容（保留转义序列原样）。
                    var j: usize = 0;
                    while (j < v.len) {
                        if (v[j] == '\\') {
                            j += 2;
                        } else if (v[j] == '"') {
                            return v[0..j];
                        } else {
                            j += 1;
                        }
                    }
                    return null; // 未闭合：视为缺引号
                }
                // 无引号：到 `;` 或行尾
                const end = std.mem.indexOfScalar(u8, v, ';') orelse v.len;
                return std.mem.trim(u8, v[0..end], " \t");
            }
        }
        i += 1;
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

test "extractParam ignores key inside quoted value (M16)" {
    // filename 的值里含 ` name=b` 子串，不得被当成真的 name token。
    const line = "form-data; filename=\"a; name=b\"; name=\"real\"";
    try std.testing.expectEqualStrings("real", extractParam(line, "name").?);
    try std.testing.expectEqualStrings("a; name=b", extractParam(line, "filename").?);
}

test "extractParam handles backslash escape inside quotes (M16)" {
    // filename 值里含 `\"` 转义引号：引号在 ` name=c` 之后才闭合，
    // 内部的 ` name=c` 不得被当成真的 name token。
    const line = "form-data; filename=\"a\\\"b; name=c\"; name=\"y\"";
    try std.testing.expectEqualStrings("y", extractParam(line, "name").?);
    try std.testing.expectEqualStrings("a\\\"b; name=c", extractParam(line, "filename").?);
}

test "extractParam still finds unquoted values" {
    const line = "form-data; name=plain; filename=img.txt";
    try std.testing.expectEqualStrings("plain", extractParam(line, "name").?);
    try std.testing.expectEqualStrings("img.txt", extractParam(line, "filename").?);
}

test "extractBoundary rejects empty boundary (M17)" {
    try std.testing.expect(extractBoundary("multipart/form-data; boundary=") == null);
}

test "extractBoundary does not match xboundary (M17)" {
    try std.testing.expect(extractBoundary("multipart/form-data; xboundary=----foo") == null);
}

test "extractBoundary enforces 70-char limit (M17)" {
    const long: [71]u8 = @splat('b');
    const ct = "multipart/form-data; boundary=" ++ long;
    try std.testing.expect(extractBoundary(ct) == null);
}

test "parseBody ignores boundary substring inside file content (M18)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 文件内容里含 `\r\n--boundaryXYZ` 子串，不得造成假分割。
    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"data\"; filename=\"f.bin\"\r\n" ++
        "\r\n" ++
        "abc\r\n--boundaryXYZ def\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    const file = form.getFile("data").?;
    // 文件内容必须完整包含边界子串，不能在中途被切断（不含终止 CRLF）。
    try std.testing.expectEqualStrings("abc\r\n--boundaryXYZ def", file.data);
}

// ── safeBaseName：Windows 清洗 + 路径穿越 ────────────────────────────

fn fileWithName(file_name: ?[]const u8) FileField {
    return .{ .name = "f", .file_name = file_name, .content_type = null, .data = "" };
}

test "safeBaseName strips path components" {
    try std.testing.expectEqualStrings("passwd", fileWithName("/etc/passwd").safeBaseName().?);
    try std.testing.expectEqualStrings("a.txt", fileWithName("C:\\Users\\me\\a.txt").safeBaseName().?);
    try std.testing.expectEqualStrings("evil.txt", fileWithName("..\\..\\evil.txt").safeBaseName().?);
    try std.testing.expectEqualStrings("ok.png", fileWithName("ok.png").safeBaseName().?);
    // 引号原文保留字面 `\`：仍按分隔符剥掉（见 safeBaseName 文档）。
    try std.testing.expectEqualStrings("b.txt", fileWithName("a\\b.txt").safeBaseName().?);
}

test "safeBaseName rejects traversal, empty and control chars" {
    try std.testing.expect(fileWithName(null).safeBaseName() == null);
    try std.testing.expect(fileWithName("").safeBaseName() == null);
    try std.testing.expect(fileWithName(".").safeBaseName() == null);
    try std.testing.expect(fileWithName("..").safeBaseName() == null);
    try std.testing.expect(fileWithName("a/").safeBaseName() == null);
    try std.testing.expect(fileWithName("a\\").safeBaseName() == null);
    // NUL 截断攻击
    try std.testing.expect(fileWithName("evil.txt\x00.png").safeBaseName() == null);
    // 其他控制字符
    try std.testing.expect(fileWithName("ev\x01il.txt").safeBaseName() == null);
    try std.testing.expect(fileWithName("ev\x7Fil.txt").safeBaseName() == null);
}

test "safeBaseName rejects Windows-specific hazards" {
    // 盘符相对路径与 NTFS 备用数据流
    try std.testing.expect(fileWithName("C:evil.txt").safeBaseName() == null);
    try std.testing.expect(fileWithName("photo.jpg::$DATA").safeBaseName() == null);
    // 保留设备名（大小写不敏感，带扩展名同样成立）
    try std.testing.expect(fileWithName("nul").safeBaseName() == null);
    try std.testing.expect(fileWithName("NUL.txt").safeBaseName() == null);
    try std.testing.expect(fileWithName("com1.log").safeBaseName() == null);
    try std.testing.expect(fileWithName("LPT9").safeBaseName() == null);
    // 结尾点/空格（Windows 规范化会剥掉）
    try std.testing.expect(fileWithName("hosts.").safeBaseName() == null);
    try std.testing.expect(fileWithName("hosts ").safeBaseName() == null);
    // 正常名字不误伤
    try std.testing.expectEqualStrings("read.me", fileWithName("read.me").safeBaseName().?);
    try std.testing.expectEqualStrings("mycom1.txt", fileWithName("mycom1.txt").safeBaseName().?);
}

// ── parseBody：分隔符后继校验回归（M18 补全） ─────────────────────

test "parseBody rejects false delimiter with single-char-like suffix" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 内容嵌了 `\r\n--boundary\rZ` 和 `\r\n--boundary-Z`：delimiter 后两字节
    // 既非 \r\n 也非 --，不得当成边界（旧单字节判 \r / - 会假分割）。
    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"data\"\r\n" ++
        "\r\n" ++
        "x\r\n--boundary\rZ\r\n--boundary-Z\r\n" ++
        "y\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    try std.testing.expectEqualStrings(
        "x\r\n--boundary\rZ\r\n--boundary-Z\r\ny",
        form.getText("data").?,
    );
    try std.testing.expectEqual(@as(usize, 1), form.fields.count());
}

test "parseBody skips preamble false delimiter (line-start + suffix check)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // preamble 里含 “--boundary” 子串但不在行首，不得被当作首分隔符。
    const body =
        "junk--boundaryjunk\r\n" ++
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "\r\n" ++
        "v\r\n" ++
        "--boundary--\r\n";

    var form = try parseBody(arena.allocator(), body, "--boundary");
    defer form.deinit();

    try std.testing.expectEqualStrings("v", form.getText("a").?);
    try std.testing.expectEqual(@as(usize, 1), form.fields.count());
}

// ── parsePart：畸形 / 重名必须响（P2-26 / P2-27） ───────────────────

test "parseBody rejects malformed parts (P2-27 同批)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 无 header/body 分隔（\r\n\r\n）
    const b1 = "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "--boundary--\r\n";
    try std.testing.expectError(error.MalformedPart, parseBody(arena.allocator(), b1, "--boundary"));

    // 没有 Content-Disposition（无 name=）
    const b2 = "--boundary\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "v\r\n" ++
        "--boundary--\r\n";
    try std.testing.expectError(error.MalformedPart, parseBody(arena.allocator(), b2, "--boundary"));

    // name="" 空 key
    const b3 = "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"\"\r\n\r\n" ++
        "v\r\n" ++
        "--boundary--\r\n";
    try std.testing.expectError(error.MalformedPart, parseBody(arena.allocator(), b3, "--boundary"));
}

test "parseBody rejects duplicate names (P2-26)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 两个同名文本字段
    const b1 = "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" ++
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n\r\n2\r\n" ++
        "--boundary--\r\n";
    try std.testing.expectError(error.DuplicateField, parseBody(arena.allocator(), b1, "--boundary"));

    // 两个同名文件字段（<input multiple> 场景：显式拒绝而非静默剩最后一个）
    const b2 = "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"docs\"; filename=\"1.txt\"\r\n\r\na\r\n" ++
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"docs\"; filename=\"2.txt\"\r\n\r\nb\r\n" ++
        "--boundary--\r\n";
    try std.testing.expectError(error.DuplicateField, parseBody(arena.allocator(), b2, "--boundary"));
}

test "parseBody rejects more than MAX_PARTS parts" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(a, "--boundary\r\n");
    var i: usize = 0;
    while (i <= MAX_PARTS) : (i += 1) { // MAX_PARTS+1 个 part，name 互不相同
        const part = try std.fmt.allocPrint(
            a,
            "Content-Disposition: form-data; name=\"f{d}\"\r\n\r\nv\r\n--boundary\r\n",
            .{i},
        );
        try buf.appendSlice(a, part);
    }
    try buf.appendSlice(a, "--boundary--\r\n");

    try std.testing.expectError(error.TooManyParts, parseBody(a, buf.items, "--boundary"));
}

// ── from()：Context 端到端 ───────────────────────────────────────

/// 测试脚手架：栈上组装 Request/Context 驱动 from()（同 http_codec 的 CodecEnv）。
const MpEnv = struct {
    arena: std.heap.ArenaAllocator = undefined,
    state: http_app.RequestState = undefined,
    cfg: http_app.RequestConfig = .{},
    req: Request = undefined,
    ctx: Context = undefined,

    const Opts = struct {
        content_type: ?[]const u8 = null,
        body: Request.Body = .none,
        content_length: ?u64 = null,
    };

    fn begin(self: *MpEnv, opts: Opts) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = self.arena.allocator();
        self.state = .{ .arena = a };
        self.req = .{
            .method = .POST,
            .target = "/",
            .path = "/",
            .query = "",
            .version = .@"HTTP/1.1",
            .head_bytes = "POST / HTTP/1.1\r\n\r\n",
            .content_type = opts.content_type,
            .content_length = opts.content_length,
            .transfer_encoding = .none,
            .body = opts.body,
        };
        self.ctx = .{
            .request = &self.req,
            .state = &self.state,
            .config = &self.cfg,
            .arena = a,
            .io = undefined,
        };
    }

    fn end(self: *MpEnv) void {
        self.state.deinit();
        self.arena.deinit();
    }
};

test "from: 端到端解析文本 + 文件 part" {
    var env: MpEnv = .{};
    env.begin(.{
        .content_type = "multipart/form-data; boundary=XX",
        .body = .{ .buffered = "--XX\r\n" ++
            "Content-Disposition: form-data; name=\"username\"\r\n\r\n" ++
            "alice\r\n" ++
            "--XX\r\n" ++
            "Content-Disposition: form-data; name=\"avatar\"; filename=\"C:\\\\tmp\\\\photo.png\"\r\n" ++
            "Content-Type: image/png\r\n\r\n" ++
            "PNG\r\n" ++
            "--XX--\r\n" },
    });
    defer env.end();

    var form = try from(&env.ctx, 1 << 20);
    defer form.deinit();

    try std.testing.expectEqualStrings("alice", form.getText("username").?);
    const file = form.getFile("avatar").?;
    try std.testing.expectEqualStrings("image/png", file.content_type.?);
    try std.testing.expectEqualStrings("PNG", file.data);
    // 原始 file_name 带路径，safeBaseName 剥到基名
    try std.testing.expectEqualStrings("photo.png", file.safeBaseName().?);
}

test "from: 非 multipart Content-Type → NotMultipart" {
    var env: MpEnv = .{};
    env.begin(.{ .content_type = "application/json", .body = .{ .buffered = "{}" } });
    defer env.end();

    try std.testing.expectError(error.NotMultipart, from(&env.ctx, 1 << 20));
}

test "from: 缺 boundary 参数 → MissingBoundary" {
    var env: MpEnv = .{};
    env.begin(.{ .content_type = "multipart/form-data", .body = .{ .buffered = "x" } });
    defer env.end();

    try std.testing.expectError(error.MissingBoundary, from(&env.ctx, 1 << 20));
}

test "from: body 超 limit → BodyTooLarge" {
    var env: MpEnv = .{};
    // .streaming 载荷在 BodyTooLarge 预检查前不会被解引用，可用 undefined。
    env.begin(.{
        .content_type = "multipart/form-data; boundary=XX",
        .body = .{ .streaming = undefined },
        .content_length = 1000,
    });
    defer env.end();

    try std.testing.expectError(error.BodyTooLarge, from(&env.ctx, 10));
}

test {
    std.testing.refAllDecls(@This());
}
