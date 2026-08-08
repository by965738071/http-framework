//! Multipart Form-Data 解析器
//! 支持文件上传和表单字段解析。
//! 符合 RFC 7578 规范。

const std = @import("std");
const mem = std.mem;

const Allocator = std.mem.Allocator;

/// Multipart 表单字段
pub const FormField = union(enum) {
    text: TextField,
    file: FileUpload,
};

/// 文本表单字段
pub const TextField = struct {
    name: []const u8,
    value: []const u8,
};

/// 文件上传信息
pub const FileUpload = struct {
    field_name: []const u8,
    file_name: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

/// Multipart 解析器
pub const Parser = struct {
    allocator: Allocator,
    boundary: []const u8,
    fields: std.ArrayList(FormField),

    const Self = @This();

    /// 初始化解析器
    pub fn init(allocator: Allocator, content_type: []const u8) !Self {
        // 从 Content-Type 中提取 boundary
        const boundary = extractBoundary(content_type) orelse return error.InvalidContentType;

        return Self{
            .allocator = allocator,
            .boundary = boundary,
            .fields = std.ArrayList(FormField).empty,
        };
    }

    /// 释放资源
    pub fn deinit(self: *Self) void {
        for (self.fields.items) |field| {
            switch (field) {
                .text => |t| {
                    self.allocator.free(t.name);
                    self.allocator.free(t.value);
                },
                .file => |file| {
                    self.allocator.free(file.field_name);
                    if (file.file_name) |name| self.allocator.free(name);
                    if (file.content_type) |ct| self.allocator.free(ct);
                    self.allocator.free(file.data);
                },
            }
        }
        self.fields.deinit(self.allocator);
    }

    /// 解析请求体
    pub fn parse(self: *Self, body: []const u8) !void {
        const boundary_line = try std.fmt.allocPrint(self.allocator, "--{s}", .{self.boundary});
        defer self.allocator.free(boundary_line);

        var rest = body;

        // 跳过开头的 boundary
        if (mem.startsWith(u8, rest, boundary_line)) {
            rest = rest[boundary_line.len..];
            // 跳过 \r\n
            if (mem.startsWith(u8, rest, "\r\n")) {
                rest = rest[2..];
            } else if (mem.startsWith(u8, rest, "\n")) {
                rest = rest[1..];
            }
        }

        while (rest.len > 0) {
            // 解析头部
            var header_len: usize = 0;

            // 读取头部直到空行
            if (mem.indexOf(u8, rest, "\r\n\r\n")) |idx| {
                header_len = idx + 4; // 包含 \r\n\r\n
            } else if (mem.indexOf(u8, rest, "\n\n")) |idx| {
                header_len = idx + 2; // 包含 \n\n
            } else {
                return error.InvalidMultipartFormat;
            }

            const headers = rest[0..header_len];
            rest = rest[header_len..];

            // 解析 Content-Disposition
            var field_name: ?[]const u8 = null;
            var file_name: ?[]const u8 = null;

            if (mem.indexOf(u8, headers, "Content-Disposition:")) |idx| {
                const disp_header = headers[idx + "Content-Disposition:".len ..];
                if (mem.indexOf(u8, disp_header, "name=")) |name_idx| {
                    var start = name_idx + "name=".len;
                    if (disp_header[start] == '"') {
                        start += 1;
                        if (mem.indexOf(u8, disp_header[start..], "\"")) |end_idx| {
                            field_name = disp_header[start .. start + end_idx];
                        }
                    }
                }
                if (mem.indexOf(u8, disp_header, "filename=")) |fn_idx| {
                    var start = fn_idx + "filename=".len;
                    if (disp_header[start] == '"') {
                        start += 1;
                        if (mem.indexOf(u8, disp_header[start..], "\"")) |end_idx| {
                            file_name = disp_header[start .. start + end_idx];
                        }
                    }
                }
            }

            // Parse Content-Type
            var content_type: ?[]const u8 = null;
            if (mem.indexOf(u8, headers, "Content-Type:")) |ct_idx| {
                var start = ct_idx + "Content-Type:".len;
                // Skip whitespace
                while (start < headers.len and (headers[start] == ' ' or headers[start] == '\t')) {
                    start += 1;
                }
                // Find end of line
                var end = start;
                while (end < headers.len and headers[end] != '\r' and headers[end] != '\n') {
                    end += 1;
                }
                if (end > start) {
                    content_type = headers[start..end];
                }
            }

            if (field_name == null) {
                return error.InvalidMultipartFormat;
            }

            // 读取数据直到下一个 boundary
            const end_boundary = try std.fmt.allocPrint(self.allocator, "\r\n--{s}", .{self.boundary});
            defer self.allocator.free(end_boundary);

            const data_end = mem.indexOf(u8, rest, end_boundary) orelse {
                // 检查是否是结束 boundary
                const final_boundary = try std.fmt.allocPrint(self.allocator, "\r\n--{s}--", .{self.boundary});
                defer self.allocator.free(final_boundary);
                if (mem.indexOf(u8, rest, final_boundary)) |idx| {
                    // 最后一个部分
                    const data = rest[0..idx];
                    try self.processField(field_name.?, file_name, content_type, data);
                    break;
                }
                return error.InvalidMultipartFormat;
            };

            const data = rest[0..data_end];
            rest = rest[data_end + end_boundary.len ..];

            // 处理字段
            try self.processField(field_name.?, file_name, content_type, data);

            // 检查是否结束
            if (mem.startsWith(u8, rest, "--")) {
                break;
            }
        }
    }

    /// 处理单个字段
    fn processField(self: *Self, field_name: []const u8, file_name: ?[]const u8, content_type: ?[]const u8, data: []const u8) !void {
        if (file_name != null) {
            // 文件上传
            const file_name_dup = try self.allocator.dupe(u8, file_name.?);
            const field_name_dup = try self.allocator.dupe(u8, field_name);
            const data_dup = try self.allocator.dupe(u8, data);
            const ct_dup = if (content_type) |ct| try self.allocator.dupe(u8, ct) else null;

            try self.fields.append(self.allocator, .{
                .file = .{
                    .field_name = field_name_dup,
                    .file_name = file_name_dup,
                    .content_type = ct_dup,
                    .data = data_dup,
                },
            });
        } else {
            // 普通文本字段
            const name_dup = try self.allocator.dupe(u8, field_name);
            const data_dup = try self.allocator.dupe(u8, data);

            try self.fields.append(self.allocator, .{
                .text = .{ .name = name_dup, .value = data_dup },
            });
        }
    }

    /// 获取文本字段
    pub fn getText(self: *const Self, name: []const u8) ?[]const u8 {
        for (self.fields.items) |field| {
            switch (field) {
                .text => |t| {
                    if (std.mem.eql(u8, t.name, name)) {
                        return t.value;
                    }
                },
                .file => continue,
            }
        }
        return null;
    }

    /// 获取文件上传
    pub fn getFile(self: *const Self, name: []const u8) ?FileUpload {
        for (self.fields.items) |field| {
            switch (field) {
                .text => continue,
                .file => |file| {
                    if (std.mem.eql(u8, file.field_name, name)) {
                        return file;
                    }
                },
            }
        }
        return null;
    }
};

/// 从 Content-Type 中提取 boundary
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const prefix = "boundary=";
    if (std.mem.indexOf(u8, content_type, prefix)) |idx| {
        const start = idx + prefix.len;
        var end = start;
        while (end < content_type.len and content_type[end] != ';' and content_type[end] != ' ') {
            end += 1;
        }
        return content_type[start..end];
    }
    return null;
}

// ===========================================================================
// RequestContext 便捷入口
// ===========================================================================
//
// 以前是 `ctx.getMultipart()`，由 RequestContext 持有解析器并在 deinit 时释放。
// 现在 core 不认识 multipart，解析器的生命周期归调用方：
//
// ```zig
// var form = try multipart.from(ctx);
// defer form.deinit();
// if (form.getFile("avatar")) |f| { ... }
// ```

const RequestContext = @import("core").RequestContext;

/// 读取请求体并解析为 multipart 表单。
///
/// 返回值由调用方持有，用完后必须 `deinit()`。
/// Content-Type 不是 `multipart/form-data` 时返回 `error.NotMultipart`。
pub fn from(ctx: *RequestContext) !Parser {
    const ct = ctx.content_type orelse return error.NotMultipart;
    if (std.ascii.findIgnoreCase(ct, "multipart/form-data") == null) {
        return error.NotMultipart;
    }

    var parser = try Parser.init(ctx.allocator, ct);
    errdefer parser.deinit();

    const body = try ctx.readBody();
    try parser.parse(body);
    return parser;
}

// ===========================================================================
// 测试
// ===========================================================================

test "extractBoundary - extracts boundary from Content-Type" {
    const ct = "multipart/form-data; boundary=----WebKitFormBoundaryabc123";
    const boundary = extractBoundary(ct);
    try std.testing.expectEqualStrings("----WebKitFormBoundaryabc123", boundary.?);
}

test "extractBoundary - returns null when no boundary" {
    const ct = "multipart/form-data";
    const boundary = extractBoundary(ct);
    try std.testing.expect(boundary == null);
}

test "extractBoundary - boundary with trailing semicolon" {
    const ct = "multipart/form-data; boundary=MyBoundary; charset=utf-8";
    const boundary = extractBoundary(ct);
    try std.testing.expectEqualStrings("MyBoundary", boundary.?);
}

test "Parser.init - wrong content type returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidContentType, Parser.init(allocator, "text/plain"));
}

test "Parser.init - valid content type" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    try std.testing.expectEqualStrings("BOUNDARY", parser.boundary);
    try std.testing.expectEqual(@as(usize, 0), parser.fields.items.len);
}

test "Parser.parse - one text field" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    const body =
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "--BOUNDARY--\r\n";

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 1), parser.fields.items.len);
    const value = parser.getText("username") orelse @panic("field should exist");
    try std.testing.expectEqualStrings("alice", value);
}

test "Parser.parse - multiple text fields" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    const body =
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"country\"\r\n" ++
        "\r\n" ++
        "Canada\r\n" ++
        "--BOUNDARY--\r\n";

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 2), parser.fields.items.len);
    try std.testing.expectEqualStrings("alice", parser.getText("username").?);
    try std.testing.expectEqualStrings("Canada", parser.getText("country").?);
}

test "Parser.parse - file upload" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    const file_content = "Hello, this is a test file.";
    const body =
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"photo.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        file_content ++
        "\r\n" ++
        "--BOUNDARY--\r\n";

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 1), parser.fields.items.len);
    const file = parser.getFile("avatar") orelse @panic("file should exist");
    try std.testing.expectEqualStrings("photo.png", file.file_name.?);
    try std.testing.expectEqualStrings("image/png", file.content_type.?);
    try std.testing.expectEqualStrings(file_content, file.data);
}

test "Parser.parse - mixed text and file fields" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    const body =
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"user\"\r\n" ++
        "\r\n" ++
        "bob\r\n" ++
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"resume\"; filename=\"cv.pdf\"\r\n" ++
        "Content-Type: application/pdf\r\n" ++
        "\r\n" ++
        "PDF content here\r\n" ++
        "--BOUNDARY--\r\n";

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 2), parser.fields.items.len);
    try std.testing.expectEqualStrings("bob", parser.getText("user").?);
    const file = parser.getFile("resume") orelse @panic("file should exist");
    try std.testing.expectEqualStrings("cv.pdf", file.file_name.?);
    try std.testing.expectEqualStrings("application/pdf", file.content_type.?);
}

test "Parser.parse - invalid body returns error" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    // Missing headers
    const invalid_body = "not a multipart body";
    try std.testing.expectError(error.InvalidMultipartFormat, parser.parse(invalid_body));
}

test "Parser.getText - non-existent field returns null" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    const body =
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"age\"\r\n" ++
        "\r\n" ++
        "25\r\n" ++
        "--BOUNDARY--\r\n";

    try parser.parse(body);
    try std.testing.expect(parser.getText("nonexistent") == null);
}

test "Parser.getFile - non-existent field returns null" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "multipart/form-data; boundary=BOUNDARY");
    defer parser.deinit();

    try std.testing.expect(parser.getFile("nonexistent") == null);
}
