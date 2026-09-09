//! HTTP 协议层 — 不可变的请求解析结果
//!
//! 设计原则（回应 bug.md §8 + fix.md §四.7）：
//! - Request 不持有 `*http.Server.Request` 作为字段，只在 `Body.streaming`
//!   变体里引用它。这样 Response 和 handler 可以脱离 std.http 单独测试。
//! - 解析结果不可变：Request 的所有方法都是 `*const Request`。
//!   body 缓存由 http_app 层的 Context.readBody → RequestState.body_buffer 承载，
//!   不再修改 Request.body。
//!
//! # 为什么 head 总是复制
//!
//! `request.head_buffer` 是连接读缓冲的一段切片，std 明确写了"读 body 会
//! 覆盖它"，后续 keep-alive 的 `receiveHead` 同样会覆盖。所以 init 无条件
//! 把 head 复制到请求 arena——`head_bytes`/`target`/`path`/`query`/
//! `content_type` 的生命周期全部绑定 arena，不存在零拷贝路径。

const std = @import("std");
const http = std.http;
const mem = std.mem;

/// limit==0（“无限”）时 body 读取的硬上限，防止伪造巨大 Content-Length 的
/// 放大型内存 DoS。256MB 对正常上传足够大，同时避免无上限分配。
const HARD_BODY_CAP: u64 = 256 * 1024 * 1024;

pub const Request = struct {
    method: http.Method,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: http.Version,

    /// 原始 head 字节（arena 副本，init 后恒为副本）。
    /// 用于 HeaderIterator 按需解析 header，避免预分配 header 数组。
    head_bytes: []const u8,

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
    /// `allocator` 通常是请求级 arena。head 副本用它分配，请求结束随
    /// arena 一起回收——不需要手动 free。
    ///
    /// 可能返回 `error.ProtocolError`（body framing 有歧义，见下方校验），
    /// 调用方应映射为 400 并关连接。
    pub fn init(allocator: mem.Allocator, request: *http.Server.Request) !Request {
        const head = request.head;
        const original_head = request.head_buffer;

        // ── body framing 校验（在任何分配之前）──────────────────────────
        // CL 与 Transfer-Encoding 并存：std 的 head 解析不拒绝这个组合
        // （只拒绝重复 CL / 重复 TE），其 bodyReader 按 chunked 成帧但
        // head.content_length 保持非 null。我们若按 CL「读满即停」，剩余
        // chunk 字节滞留连接缓冲，而 std 的 discardBody 对未读完的 chunk
        // 流不排空 → 残留字节被当成下一个请求解析（经典 CL.TE 走私面）。
        // RFC 9112 §6.3 也要求对这种组合按不可信处理。直接 400 + 关连接。
        if (head.content_length != null and head.transfer_encoding != .none) {
            return error.ProtocolError;
        }
        // 不允许 body 的方法（GET/HEAD/DELETE/…，std requestHasBody 的口径）
        // 携带真实 framing：std 对它们返回恒空的 .ending reader，从不消费那
        // 些字节，却仍视连接可复用 → body 残留污染下一个请求。CL:0 无字节
        // 可残留，保持合法。
        if (!head.method.requestHasBody()) {
            if (head.transfer_encoding != .none) return error.ProtocolError;
            if (head.content_length) |len| {
                if (len > 0) return error.ProtocolError;
            }
        }
        // 重复 Content-Type 头：std 的 head.content_type 是后值覆盖，而
        // HeaderIterator 取首个——两条取法会拿到不同的值，判定分裂
        // （框架用 content_type，用户用 getHeader）。拒绝以消除歧义。
        if (countHeader(original_head, "content-type") > 1) {
            return error.ProtocolError;
        }

        const target = head.target;
        const query_start = mem.indexOfScalar(u8, target, '?');
        var path = if (query_start) |idx| target[0..idx] else target;
        var query = if (query_start) |idx| target[idx + 1 ..] else "";
        var content_type = head.content_type;

        // 始终复制 head_bytes 到 arena，避免连接缓冲区被后续 receiveHead 覆盖导致悬空指针。
        // 即使不带 body 的请求也复制，保证 head_bytes 生命周期绑定请求 arena。
        const copy = try allocator.dupe(u8, original_head);
        path = rebase(path, original_head, copy);
        query = rebase(query, original_head, copy);
        if (content_type) |ct| content_type = rebase(ct, original_head, copy);
        const head_bytes: []const u8 = copy;
        // 修复 F1：target 也必须 rebase 到 arena 副本，否则读 body 或下一个
        // keep-alive 请求覆盖 head_buffer 后 ctx.request.target 悬空。
        const target_rebased = rebase(target, original_head, copy);

        // 有 body 的判定与 std 的 reader 语义同口径：方法不允许 body 时
        // std 根本不会按 CL/TE 消费字节（上面已拒绝非零 framing，只剩 CL:0，
        // 无内容可读）。
        const has_body = head.method.requestHasBody() and
            (head.content_length != null or head.transfer_encoding != .none);
        const body: Body = if (!has_body) .none else .{ .streaming = request };

        return .{
            .method = head.method,
            .target = target_rebased,
            .path = path,
            .query = query,
            .version = head.version,
            .head_bytes = head_bytes,
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

    /// 获取单个 query 参数值（原始，未解码）。零分配线性扫描。
    /// 需要百分号/加号解码时用 getQueryDecoded。
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

    /// 获取 query 参数并做 application/x-www-form-urlencoded 解码
    /// （`+`→空格、`%XX`→字节）。用调用方 allocator（通常 ctx.arena）分配结果。
    /// key 本身也按同规则解码后再比较。
    pub fn getQueryDecoded(self: *const Request, allocator: mem.Allocator, key: []const u8) !?[]const u8 {
        if (self.query.len == 0) return null;
        var it = mem.splitScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_idx = mem.indexOfScalar(u8, pair, '=');
            const raw_k = if (eq_idx) |i| pair[0..i] else pair;
            const dk = try urlDecode(allocator, raw_k);
            defer allocator.free(dk);
            if (!std.mem.eql(u8, dk, key)) continue;
            const raw_v = if (eq_idx) |i| pair[i + 1 ..] else "";
            return try urlDecode(allocator, raw_v);
        }
        return null;
    }

    /// 获取 Cookie 值（零分配线性扫描）。
    /// Cookie 头格式：`name1=value1; name2=value2`。
    ///
    /// Cookie 是允许多行的头（RFC 6265：UA 合并 cookie 时可能拆成多个
    /// Cookie 头发送），getHeader 只看第一个 → 必须扫全部 cookie 头，
    /// 否则第二个头里的 session cookie 直接不可见。
    pub fn getCookie(self: *const Request, key: []const u8) ?[]const u8 {
        var it = http.HeaderIterator.init(self.head_bytes);
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
            var pairs = mem.splitScalar(u8, h.value, ';');
            while (pairs.next()) |pair_raw| {
                const pair = mem.trim(u8, pair_raw, " \t");
                if (pair.len == 0) continue;
                const eq_idx = mem.indexOfScalar(u8, pair, '=') orelse continue;
                const k = mem.trim(u8, pair[0..eq_idx], " \t");
                if (std.mem.eql(u8, k, key)) return pair[eq_idx + 1 ..];
            }
        }
        return null;
    }

    /// 从已读取的表单体中提取字段值（原始，未解码）。
    /// 需要 `+`/`%XX` 解码时用 getFormDecoded。
    pub fn getForm(self: *const Request, key: []const u8) ?[]const u8 {
        const body = switch (self.body) {
            .buffered => |data| data,
            else => return null,
        };
        return getFormFrom(body, key);
    }

    /// 从给定的表单体字节里提取字段值（原始，未解码）。
    /// streaming body 经 Context.readBody 缓冲后，用它解析（body 存于
    /// RequestState.body_buffer，Request.body 仍是 .streaming）。
    pub fn getFormFrom(body: []const u8, key: []const u8) ?[]const u8 {
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

    /// 从已读取的表单体提取字段并解码（`+`→空格、`%XX`→字节，WHATWG urlencoded 规则）。
    /// body 必须已 buffered。用调用方 allocator 分配结果。
    pub fn getFormDecoded(self: *const Request, allocator: mem.Allocator, key: []const u8) !?[]const u8 {
        const body = switch (self.body) {
            .buffered => |data| data,
            else => return null,
        };
        return getFormDecodedFrom(allocator, body, key);
    }

    /// 从给定的表单体字节里提取字段并解码。streaming body 经 Context.readBody
    /// 缓冲后用它解析（Context.formDecoded 会传入缓冲结果）。
    pub fn getFormDecodedFrom(allocator: mem.Allocator, body: []const u8, key: []const u8) !?[]const u8 {
        if (body.len == 0) return null;
        var it = mem.splitScalar(u8, body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_idx = mem.indexOfScalar(u8, pair, '=');
            const raw_k = if (eq_idx) |i| pair[0..i] else pair;
            const dk = try urlDecode(allocator, raw_k);
            defer allocator.free(dk);
            if (!std.mem.eql(u8, dk, key)) continue;
            const raw_v = if (eq_idx) |i| pair[i + 1 ..] else "";
            return try urlDecode(allocator, raw_v);
        }
        return null;
    }

    /// 从 streaming body 读取到新分配的 buffer。不修改 self（fix.md §四.7）。
    /// 调用方负责缓存（Context.readBody 会存入 state.body_buffer）。
    /// 支持 Content-Length 与 chunked（Transfer-Encoding）两种。limit==0 表示无限
    /// （实际封顶 HARD_BODY_CAP）。
    ///
    /// **只能调一次**：std 构造 reader 时 assert 状态为 .received_head，第二次
    /// 调用（或再走 bodyReader）直接 panic 打死进程。务必经 Context.readBody 的
    /// 缓存读 body。
    ///
    /// **BodyTooLarge 后 CL 与 chunked 的处置不同**：
    /// - CL 超限在建 reader 前判出（状态仍 .received_head），std 的
    ///   discardBody 会把 body 排空 → 连接可安全复用；
    /// - chunked 无法预知长度，必然读了半截才发现 → std 的 discardBody 对
    ///   `.body_remaining_chunk_len` **不排空** → 调用方回 413 时必须
    ///   `res.keep_alive = false` 关连接（http_codec 的 JsonBody 是范例），
    ///   否则残留 chunk 字节会被当成下一个请求解析（走私面）。
    ///
    /// 可能返回 `error.HttpExpectationFailed`（客户端发了无法满足的 Expect 值），
    /// 调用方应映射为 417 Expectation Failed。
    /// 可能返回 `error.UnexpectedEof`（声明的 Content-Length 大于实收字节，
    /// 连接被提前切断），调用方应映射为 400 且关连接。
    pub fn readBodyInto(self: *const Request, allocator: mem.Allocator, limit: u64) ![]const u8 {
        return switch (self.body) {
            .none => "",
            .buffered => |data| data,
            .streaming => |req| {
                // ── limit 校验必须在建 reader 之前 ────────────────────────────
                // 一旦调用 readerExpectContinue，std 就把 reader 状态切到
                // body_remaining_content_length；此后 std 的 discardBody() 对该状态
                // 直接 return true（不排空，见 std/http/Server.zig:640）。
                // 如果我们在建了 reader 之后才返回 error.BodyTooLarge，而调用方
                // catch 掉它并正常回 413（http_codec.JsonBody 就是这么写的），
                // 连接会被复用，残留的 body 字节会被当成下一个请求行解析
                // → HTTP 请求走私。所以先判长度，再建 reader。
                const effective_limit: u64 = if (limit > 0) limit else HARD_BODY_CAP;
                if (self.content_length) |len| {
                    if (len > effective_limit) return error.BodyTooLarge;
                }

                // transfer buffer 必须由 allocator（请求 arena）分配，不能用栈数组：
                // bodyReader 会把它挂到 server.reader.interface.buffer，
                // 其生命周期长于本函数，栈数组返回后即悬空。
                const work_buf = try allocator.alloc(u8, 4096);

                // 必须用 readerExpectContinue 而非 readerExpectNone：
                // 后者第一行就是 assert(head.expect == null)，任何带
                // `Expect: 100-continue` 的请求都会直接 panic 打死整个进程
                // （curl 对 >1KB body 自动加这个头）。readerExpectContinue 会先写
                // "100 Continue" + flush，再把 head.expect 置 null；无法满足的
                // Expect 值返回 error.HttpExpectationFailed。
                const reader = try req.readerExpectContinue(work_buf);

                if (self.content_length) |len| {
                    // Content-Length 已知：预分配、读足。
                    const buf = try allocator.alloc(u8, std.math.cast(usize, len) orelse return error.BodyTooLarge);
                    errdefer allocator.free(buf);
                    var read: usize = 0;
                    while (read < buf.len) {
                        const chunk = try reader.readSliceShort(buf[read..]);
                        if (chunk == 0) break; // EOF
                        read += chunk;
                    }
                    // 读不足声明长度 → 连接被提前切断，报错而非静默返回短体。
                    if (read < buf.len) return error.UnexpectedEof;
                    return buf;
                }

                // chunked（无 Content-Length）：读到 EOF 到可增长缓冲，受 limit 限制。
                // 注意：read_buf 必须与 reader 内部缓冲（work_buf）分开，否则
                // readSliceShort 会把 work_buf 里的数据 memcpy 回 work_buf 自身
                // （源目标重叠 = UB），且 reader 随后继续写 work_buf 破坏刚读到的数据
                // → chunked body 静默损坏（回应审查发现 #3）。
                var read_buf: [4096]u8 = undefined;
                var list = std.ArrayList(u8).empty;
                errdefer list.deinit(allocator);
                while (true) {
                    const n = try reader.readSliceShort(&read_buf);
                    if (n == 0) break; // EOF
                    if (list.items.len + n > effective_limit) return error.BodyTooLarge;
                    try list.appendSlice(allocator, read_buf[0..n]);
                }
                return list.toOwnedSlice(allocator);
            },
        };
    }

    /// 流式 body 的 Reader 接口（不整体缓冲）。
    ///
    /// `transfer_buf` 由调用方提供，必须活到读完 body 为止（std 会把它挂到
    /// `server.reader.interface`）。streaming 变体只能构造一次（std 内部有 assert）。
    pub fn bodyReader(self: *const Request, transfer_buf: []u8) !?BodyReader {
        return switch (self.body) {
            .none => null,
            .buffered => |data| .{ .internal = .{ .buffered = .{ .data = data, .pos = 0 } } },
            .streaming => |req| .{
                .internal = .{
                    // 与 readBodyInto 同理：必须用 readerExpectContinue，
                    // readerExpectNone 会对带 Expect: 100-continue 的请求 assert 崩溃。
                    .streaming = .{ .reader = try req.readerExpectContinue(transfer_buf) },
                },
            },
        };
    }

    pub const BodyReader = struct {
        internal: union(enum) {
            buffered: struct { data: []const u8, pos: usize },
            streaming: struct { reader: *std.Io.Reader },
        },

        pub fn read(self: *BodyReader, buf: []u8) !usize {
            switch (self.internal) {
                .buffered => |*b| {
                    const remaining = b.data.len - b.pos;
                    const n = @min(buf.len, remaining);
                    if (n == 0) return 0;
                    @memcpy(buf[0..n], b.data[b.pos .. b.pos + n]);
                    b.pos += n;
                    return n;
                },
                // 旧实现写的是 `s.req.reader()` —— 这个方法在本 std 版本不存在
                // （只有 readerExpectNone / readerExpectContinue）。因为该函数
                // 从未被语义分析（refAllDecls 不递归到嵌套类型的方法），编译期
                // 没报错，但任何真实调用都会让构建失败。
                .streaming => |*s| return s.reader.readSliceShort(buf),
            }
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

/// 统计 head 字节里某 header 名出现的次数（大小写不敏感）。
/// 用于检测「必须单值」的头被重复发送（如 Content-Type）。
fn countHeader(head_bytes: []const u8, name: []const u8) usize {
    var n: usize = 0;
    var it = http.HeaderIterator.init(head_bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) n += 1;
    }
    return n;
}

/// 百分比解码核心：`%XX`→字节；`plus_as_space` 决定是否**额外**应用
/// form-urlencoded 的 `+`→空格 规则。非法 `%` 序列原样保留，不返回 error。
///
/// 为什么把规则差异做成 comptime 开关，而不是复制成两个函数：
/// query/表单（`+`=空格）与路径（`+`=字面量，RFC 3986 §2.2 把 `+` 列为
/// sub-delims，在 path segment 里就是普通字符）只差一个字符的处理，拆两份
/// 必然漂移——项目里已经有一份独立的 http_static.percentDecode，再加一份就
/// 三套行为了。comptime 保证两侧的 `%XX` 解析与「非法序列原样保留」行为是
/// 同一份代码，且分支在编译期消掉，热路径零开销。
fn urlDecodeImpl(allocator: mem.Allocator, s: []const u8, comptime plus_as_space: bool) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (plus_as_space and c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            try out.append(allocator, @as(u8, hi) * 16 + lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// application/x-www-form-urlencoded 解码：`+`→空格，`%XX`→字节。
/// 非法 `%` 序列原样保留。结果由 allocator 分配。
///
/// 对外可见是为了让上层的「解码版 getter」（Request.getQueryDecoded 与
/// Request.getFormDecodedFrom）共用同一套规则——各写一份必然漂移，最后变成
/// 「query 和表单对同一个 %zz 解出不同结果」这类难查的 bug。
///
/// 为什么不开 comptime 参数而用两个命名包装：x-www-form-urlencoded 语义是
/// query 与 body 的默认，`urlDecode(a, s, true)` 这种写法读不出 `true` 的
/// 含义，且 6 处既有调用点（query ×2、form ×2、测试）都要跟着改形参——漏一
/// 处就静默变成路径语义。命名包装把意图写在函数名上，同时保持现有签名不变。
pub fn urlDecode(allocator: mem.Allocator, s: []const u8) ![]const u8 {
    return urlDecodeImpl(allocator, s, true);
}

/// RFC 3986 路径解码：`%XX`→字节，`+` **保持字面量**。
/// 用于路径段（`Context.paramDecoded`）——`/files/a+b.txt` 必须解成
/// `a+b.txt` 而不是 `a b.txt`；把路径当 form 解码会让含 `+` 的文件名永远
/// 取不到。非法 `%` 序列的行为与 `urlDecode` 一致（原样保留）。
pub fn urlDecodePath(allocator: mem.Allocator, s: []const u8) ![]const u8 {
    return urlDecodeImpl(allocator, s, false);
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

test "getQueryDecoded decodes percent and plus" {
    const head_bytes = "GET / HTTP/1.1\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "q=hello+world&name=caf%C3%A9",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    const a = std.testing.allocator;
    const q = (try req.getQueryDecoded(a, "q")).?;
    defer a.free(q);
    try std.testing.expectEqualStrings("hello world", q);
    const name = (try req.getQueryDecoded(a, "name")).?;
    defer a.free(name);
    try std.testing.expectEqualStrings("caf\xc3\xa9", name);
}

test "getFormDecoded decodes urlencoded body" {
    const head_bytes = "POST / HTTP/1.1\r\n\r\n";
    const req = Request{
        .method = .POST,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .{ .buffered = "msg=a%20b%26c&x=1" },
    };
    const a = std.testing.allocator;
    const msg = (try req.getFormDecoded(a, "msg")).?;
    defer a.free(msg);
    try std.testing.expectEqualStrings("a b&c", msg);
}

// ── init 校验测试用假 Server.Request ────────────────────────────────────
// init 只读 head 与 head_buffer，不碰 server 指针（校验失败时连
// head_buffer 都不需要），故 server 字段置 undefined 安全。
fn fakeSrvReq(
    head_text: []const u8,
    method: http.Method,
    target: []const u8,
    content_type: ?[]const u8,
    content_length: ?u64,
    transfer_encoding: http.TransferEncoding,
) http.Server.Request {
    return .{
        .server = undefined,
        .head = .{
            .method = method,
            .target = target,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = content_type,
            .content_length = content_length,
            .transfer_encoding = transfer_encoding,
            .transfer_compression = .identity,
            .keep_alive = true,
        },
        .head_buffer = head_text,
    };
}

test "Request.init rejects Content-Length + Transfer-Encoding coexistence" {
    // CL.TE 走私面：std 不拒绝该组合且 chunked 优先成帧，而本框架按
    // CL 读满会留下未消费的 chunk 字节 → init 层面直接 400。
    const head_text = "POST /up HTTP/1.1\r\n\r\n";
    var srv = fakeSrvReq(head_text, .POST, head_text[5..8], null, 5, .chunked);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ProtocolError, Request.init(arena.allocator(), &srv));
}

test "Request.init rejects framing on methods that do not allow a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const head_text = "GET /up HTTP/1.1\r\n\r\n";
    // GET + 非零 CL：std 给的是恒空 .ending reader，body 字节永远无人消费
    var get_cl = fakeSrvReq(head_text, .GET, head_text[4..7], null, 5, .none);
    try std.testing.expectError(error.ProtocolError, Request.init(a, &get_cl));

    // GET + chunked：同理
    var get_te = fakeSrvReq(head_text, .GET, head_text[4..7], null, null, .chunked);
    try std.testing.expectError(error.ProtocolError, Request.init(a, &get_te));

    // HEAD + 非零 CL
    var head_cl = fakeSrvReq(head_text, .HEAD, head_text[4..7], null, 5, .none);
    try std.testing.expectError(error.ProtocolError, Request.init(a, &head_cl));

    // 但 GET + Content-Length: 0 无字节可残留，保持合法（body 为 .none）
    var get0 = fakeSrvReq(head_text, .GET, head_text[4..7], null, 0, .none);
    const req0 = try Request.init(a, &get0);
    try std.testing.expect(req0.body == .none);
    // std 的 requestHasBody 口径：POST/PUT/PATCH/QUERY 才允许 body
    var del = fakeSrvReq(head_text, .DELETE, head_text[4..7], null, 5, .none);
    try std.testing.expectError(error.ProtocolError, Request.init(a, &del));
}

test "Request.init rejects duplicate Content-Type" {
    // std 的 head.content_type 后值胜，HeaderIterator 首值胜——两条取法
    // 分裂，必须拒绝。
    const head_text = "GET / HTTP/1.1\r\nContent-Type: a\r\nContent-Type: b\r\n\r\n";
    var srv = fakeSrvReq(head_text, .GET, head_text[4..5], head_text[33..34], null, .none);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ProtocolError, Request.init(arena.allocator(), &srv));
}

test "Request.init copies head to arena and rebases all slices" {
    const head_text = "POST /up HTTP/1.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n";
    // head_text[33..43] = "text/plain"
    var srv = fakeSrvReq(head_text, .POST, head_text[5..8], head_text[33..43], 5, .none);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try Request.init(arena.allocator(), &srv);

    try std.testing.expect(req.body == .streaming);
    try std.testing.expectEqual(@as(u64, 5), req.content_length.?);
    // head_bytes 是 arena 副本，不再指向原缓冲
    try std.testing.expect(req.head_bytes.ptr != head_text.ptr);
    try std.testing.expectEqualStrings(head_text, req.head_bytes);
    // 所有切片平移到副本内（模拟连接缓冲被覆盖后仍安全）
    const base = @intFromPtr(req.head_bytes.ptr);
    try std.testing.expectEqualStrings("/up", req.target);
    try std.testing.expectEqual(base + 5, @intFromPtr(req.target.ptr));
    try std.testing.expectEqualStrings("/up", req.path);
    try std.testing.expectEqual(base + 5, @intFromPtr(req.path.ptr));
    try std.testing.expectEqualStrings("text/plain", req.content_type.?);
    try std.testing.expectEqual(base + 33, @intFromPtr(req.content_type.?.ptr));
}

test "getCookie scans all Cookie headers (RFC 6265 allows multiple)" {
    const head_bytes = "GET / HTTP/1.1\r\nCookie: a=1\r\nCookie: sid=xyz; b=2\r\n\r\n";
    const req = Request{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .content_type = null,
        .content_length = null,
        .transfer_encoding = .none,
        .body = .none,
    };
    // 第一个头里的 cookie
    try std.testing.expectEqualStrings("1", req.getCookie("a").?);
    // 只在第二个头里的 cookie：只看 getHeader("cookie") 的旧实现会漏
    try std.testing.expectEqualStrings("xyz", req.getCookie("sid").?);
    try std.testing.expectEqualStrings("2", req.getCookie("b").?);
    try std.testing.expect(req.getCookie("missing") == null);
}

test "countHeader counts case-insensitively, skips request line" {
    const head_bytes = "GET / HTTP/1.1\r\nX-H: 1\r\nx-h: 2\r\nY-H: 3\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 2), countHeader(head_bytes, "X-H"));
    try std.testing.expectEqual(@as(usize, 1), countHeader(head_bytes, "y-h"));
    try std.testing.expectEqual(@as(usize, 0), countHeader(head_bytes, "get"));
    try std.testing.expect(countHeader(head_bytes, "nope") < 2);
}

test "urlDecode edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("A", try urlDecode(a, "%41")); // 串尾完整序列
    try std.testing.expectEqualStrings("a", try urlDecode(a, "%61"));
    try std.testing.expectEqualStrings(" ", try urlDecode(a, "+"));
    try std.testing.expectEqualStrings("a%4", try urlDecode(a, "a%4")); // 截断序列原样保留
    try std.testing.expectEqualStrings("100%", try urlDecode(a, "100%")); // 裸 % 在串尾
    try std.testing.expectEqualStrings("%zz", try urlDecode(a, "%zz")); // 非十六进制
    try std.testing.expectEqualStrings("aA%zz", try urlDecode(a, "a%41%zz")); // 混合
    try std.testing.expectEqualStrings("", try urlDecode(a, ""));
}

test "urlDecodePath: '+' 保持字面量，%XX 与非法序列行为同 urlDecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 路径段：'+' 是普通字符（RFC 3986 sub-delims）
    try std.testing.expectEqualStrings("a+b.txt", try urlDecodePath(a, "a+b.txt"));
    try std.testing.expectEqualStrings("+", try urlDecodePath(a, "+"));
    // %XX 照常解码
    try std.testing.expectEqualStrings("a b.txt", try urlDecodePath(a, "a%20b.txt"));
    try std.testing.expectEqualStrings("中文", try urlDecodePath(a, "%E4%B8%AD%E6%96%87"));
    // 非法序列：与 urlDecode 同口径，原样保留而不是报错（契约不变）
    try std.testing.expectEqualStrings("%zz", try urlDecodePath(a, "%zz"));
    try std.testing.expectEqualStrings("abc%2", try urlDecodePath(a, "abc%2"));
    try std.testing.expectEqualStrings("100%", try urlDecodePath(a, "100%"));
    try std.testing.expectEqualStrings("", try urlDecodePath(a, ""));

    // 对照：form 语义下 '+' 仍然是空格，两个包装共用同一核心但行为不同
    try std.testing.expectEqualStrings("a b", try urlDecode(a, "a+b"));
}

test "readBodyInto: CL超限在建 reader 前判出（undefined 指针不解引用）" {
    // 同时验证 limit==0 封顶 HARD_BODY_CAP（伪造巨大 CL 的放大 DoS）。
    const head_bytes = "POST / HTTP/1.1\r\n\r\n";
    var req = Request{
        .method = .POST,
        .target = "/",
        .path = "/",
        .query = "",
        .version = .@"HTTP/1.1",
        .head_bytes = head_bytes,
        .content_type = null,
        .content_length = 1000,
        .transfer_encoding = .none,
        .body = .{ .streaming = undefined },
    };
    try std.testing.expectError(error.BodyTooLarge, req.readBodyInto(std.testing.allocator, 100));
    // “无限”（limit==0）实为 HARD_BODY_CAP 封顶
    req.content_length = HARD_BODY_CAP + 1;
    try std.testing.expectError(error.BodyTooLarge, req.readBodyInto(std.testing.allocator, 0));
    // .none 分支：空 body 合法
    var none_req = req;
    none_req.body = .none;
    try std.testing.expectEqualStrings("", try none_req.readBodyInto(std.testing.allocator, 10));
}

test {
    std.testing.refAllDecls(@This());
}
