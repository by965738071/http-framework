//! HTTP 协议层 — 不可变的请求解析结果
//!
//! 设计原则（回应 bug.md §8 + fix.md §四.7）：
//! - Request 不持有 `*http.Server.Request` 作为字段，只在 `Body.streaming`
//!   变体里引用它。这样 Response 和 handler 可以脱离 std.http 单独测试。
//! - 解析结果不可变：Request 的所有方法都是 `*const Request`。
//!   body 缓存由 http_app 层的 Context.readBody → RequestState.body_buffer 承载，
//!   不再修改 Request.body。
//!
//! # head_copy 的必要性
//!
//! `request.head_buffer` 是连接读缓冲的一段切片，std 明确写了"读 body 会
//! 覆盖它"。所以带 body 的请求在 init 时把 head 复制到 arena。不带 body
//! 的请求（绝大多数 GET/HEAD）保持零拷贝。

const std = @import("std");
const http = std.http;
const mem = std.mem;

pub const Request = struct {
    method: http.Method,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: http.Version,

    /// 原始 head 字节（head_buffer 或其 arena 副本）。
    /// 用于 HeaderIterator 按需解析 header，避免预分配 header 数组。
    head_bytes: []const u8,
    head_copy: ?[]const u8,

    content_type: ?[]const u8,
    content_length: ?u64,
    transfer_encoding: http.TransferEncoding,

    body: Body,
    trust_proxy: bool = false,

    pub const Body = union(enum) {
        none,
        buffered: []const u8,
        streaming: *http.Server.Request,
    };

    /// 从 std.http.Server.Request 构建不可变 Request。
    ///
    /// `allocator` 通常是请求级 arena。head_copy 用它分配，请求结束随
    /// arena 一起回收——不需要手动 free。
    pub fn init(allocator: mem.Allocator, request: *http.Server.Request) !Request {
        const head = request.head;
        const target = head.target;
        const query_start = mem.indexOfScalar(u8, target, '?');
        var path = if (query_start) |idx| target[0..idx] else target;
        var query = if (query_start) |idx| target[idx + 1 ..] else "";
        var content_type = head.content_type;

        const has_body = head.content_length != null or head.transfer_encoding != .none;
        const original_head = request.head_buffer;
        var head_copy: ?[]const u8 = null;
        // 带 body 的请求：读 body 会覆盖 head_buffer，所以先复制到 arena。
        // 不带 body 的请求：直接引用 head_buffer（零拷贝）。
        const head_bytes: []const u8 = if (has_body) blk: {
            const copy = try allocator.dupe(u8, original_head);
            head_copy = copy;
            path = rebase(path, original_head, copy);
            query = rebase(query, original_head, copy);
            if (content_type) |ct| content_type = rebase(ct, original_head, copy);
            break :blk copy;
        } else original_head;

        const body: Body = if (!has_body)
            .none
        else if (head.content_length != null)
            .{ .streaming = request }
        else
            .{ .streaming = request };

        return .{
            .method = head.method,
            .target = target,
            .path = path,
            .query = query,
            .version = head.version,
            .head_bytes = head_bytes,
            .head_copy = head_copy,
            .content_type = content_type,
            .content_length = head.content_length,
            .transfer_encoding = head.transfer_encoding,
            .body = body,
        };
    }

    /// 获取请求头值（大小写不敏感），零分配。
    /// 用 HeaderIterator 按需解析原始 head 字节，不预分配 header 数组。
    pub fn getHeader(self: *const Request, key: []const u8) ?[]const u8 {
        var it = http.HeaderIterator.init(self.head_bytes);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, key)) return h.value;
        }
        return null;
    }

    /// 获取单个 query 参数值（零分配线性扫描，不缓存）。
    /// 需要缓存的批量查询由 http_app 层的 codec 负责。
    pub fn getQuery(self: *const Request, key: []const u8) ?[]const u8 {
        if (self.query.len == 0) return null;
        var it = mem.splitScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_idx = mem.indexOfScalar(u8, pair, '=') orelse {
                if (std.mem.eql(u8, pair, key)) return "";
                continue;
            };
            const k = pair[0..eq_idx];
            if (std.mem.eql(u8, k, key)) return pair[eq_idx + 1 ..];
        }
        return null;
    }

    /// 获取 Cookie 值（零分配线性扫描 Cookie 头）。
    /// Cookie 头格式：`name1=value1; name2=value2`
    pub fn getCookie(self: *const Request, key: []const u8) ?[]const u8 {
        const cookie_header = self.getHeader("cookie") orelse return null;
        var it = mem.splitScalar(u8, cookie_header, ';');
        while (it.next()) |pair_raw| {
            const pair = mem.trim(u8, pair_raw, " \t");
            if (pair.len == 0) continue;
            const eq_idx = mem.indexOfScalar(u8, pair, '=') orelse continue;
            const k = mem.trim(u8, pair[0..eq_idx], " \t");
            if (std.mem.eql(u8, k, key)) return pair[eq_idx + 1 ..];
        }
        return null;
    }

    /// 从已读取的表单体中提取字段值（application/x-www-form-urlencoded）。
    /// body 必须已通过 readBody 读入。零分配线性扫描。
    pub fn getForm(self: *const Request, key: []const u8) ?[]const u8 {
        const body = switch (self.body) {
            .buffered => |data| data,
            else => return null,
        };
        if (body.len == 0) return null;
        var it = mem.splitScalar(u8, body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_idx = mem.indexOfScalar(u8, pair, '=') orelse {
                if (std.mem.eql(u8, pair, key)) return "";
                continue;
            };
            const k = pair[0..eq_idx];
            if (std.mem.eql(u8, k, key)) return pair[eq_idx + 1 ..];
        }
        return null;
    }

    /// 从 streaming body 读取到新分配的 buffer。不修改 self（fix.md §四.7）。
    /// 调用方负责缓存（Context.readBody 会存入 RequestState.body_buffer）。
    pub fn readBodyInto(self: *const Request, allocator: mem.Allocator, limit: u64) ![]const u8 {
        return switch (self.body) {
            .none => "",
            .buffered => |data| data,
            .streaming => |req| {
                const len = self.content_length orelse return error.BodyLengthUnknown;
                if (limit > 0 and len > limit) return error.BodyTooLarge;
                const buf = try allocator.alloc(u8, @intCast(len));
                errdefer allocator.free(buf);
                var work_buf: [4096]u8 = undefined;
                var reader = req.readerExpectNone(&work_buf);
                var read: usize = 0;
                while (read < buf.len) {
                    const chunk = reader.readSliceShort(buf[read..]) catch break;
                    if (chunk == 0) break;
                    read += chunk;
                }
                return buf[0..read];
            },
        };
    }

    /// 流式 body 的 Reader 接口（不整体缓冲）。
    pub fn bodyReader(self: *const Request) ?BodyReader {
        return switch (self.body) {
            .none => null,
            .buffered => |data| .{ .internal = .{ .buffered = .{ .data = data, .pos = 0 } } },
            .streaming => |req| .{ .internal = .{ .streaming = .{ .req = req } } },
        };
    }

    pub const BodyReader = struct {
        internal: union(enum) {
            buffered: struct { data: []const u8, pos: usize },
            streaming: struct { req: *http.Server.Request },
        },

        pub fn read(self: *BodyReader, buf: []u8) !usize {
            return switch (self.internal) {
                .buffered => |*b| {
                    const remaining = b.data.len - b.pos;
                    const n = @min(buf.len, remaining);
                    if (n == 0) return 0;
                    @memcpy(buf[0..n], b.data[b.pos .. b.pos + n]);
                    b.pos += n;
                    return n;
                },
                .streaming => |*s| {
                    const reader = s.req.reader();
                    return reader.read(buf);
                },
            };
        }
    };
};

/// 把 `old` 里的一段切片平移到 `new`（两者内容相同、长度相同）。
fn rebase(slice: []const u8, old: []const u8, new: []const u8) []const u8 {
    const s = @intFromPtr(slice.ptr);
    const base = @intFromPtr(old.ptr);
    if (s < base or s + slice.len > base + old.len) return slice;
    return new[s - base ..][0..slice.len];
}

// ===========================================================================
// Tests
// ===========================================================================

test "Request.getHeader returns value case-insensitively" {
    // 用模拟 header 数组测试，不需要真实 http.Server
    // 构造原始 head 字节，HeaderIterator 会解析出 name/value
    const head_bytes = "GET /test HTTP/1.1\r\nContent-Type: text/plain\r\nX-Custom: hello\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/test",
        .path = "/test",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = "text/plain",
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    try std.testing.expectEqualStrings("text/plain", req.getHeader("content-type").?);
    try std.testing.expectEqualStrings("hello", req.getHeader("X-CUSTOM").?);
    try std.testing.expect(req.getHeader("missing") == null);
}

test "Request.getQuery parses key=value pairs" {
    const head_bytes = "GET /search HTTP/1.1\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/search",
        .path = "/search",
        .query = "q=hello&page=2",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    try std.testing.expectEqualStrings("hello", req.getQuery("q").?);
    try std.testing.expectEqualStrings("2", req.getQuery("page").?);
    try std.testing.expect(req.getQuery("missing") == null);
}

test "Request.getQuery handles empty values" {
    const head_bytes = "GET / HTTP/1.1\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "flag&key=val",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    try std.testing.expectEqualStrings("", req.getQuery("flag").?);
    try std.testing.expectEqualStrings("val", req.getQuery("key").?);
}

test "Request.getCookie parses Cookie header" {
    const head_bytes = "GET / HTTP/1.1\r\nCookie: session=abc; csrf_token=xyz123\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    try std.testing.expectEqualStrings("abc", req.getCookie("session").?);
    try std.testing.expectEqualStrings("xyz123", req.getCookie("csrf_token").?);
    try std.testing.expect(req.getCookie("missing") == null);
}

test "Request.getForm extracts from buffered body" {
    const head_bytes = "POST /submit HTTP/1.1\r\n\r\n";
    const req = Request{
        .method = .POST,
        .target = "/submit",
        .path = "/submit",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .head_copy = null,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .{ .buffered = "name=hello&token=abc&flag" },
    };
    try std.testing.expectEqualStrings("hello", req.getForm("name").?);
    try std.testing.expectEqualStrings("abc", req.getForm("token").?);
    try std.testing.expectEqualStrings("", req.getForm("flag").?);
    try std.testing.expect(req.getForm("missing") == null);
}

test "rebase shifts slice from old buffer to new" {
    const old = "hello world";
    var new: [11]u8 = undefined;
    @memcpy(&new, old);
    const rebased = rebase(old[6..11], old, &new);
    try std.testing.expectEqualStrings("world", rebased);
}
