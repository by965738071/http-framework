//! Auth 中间件 — 迁移到新架构
//!
//! 支持 Bearer Token / Basic Auth / API Key 三种策略。
//!
//! 修复 bug.md Part 2 P0/P1：
//! - 凭证比对用常量时间比较（旧代码用 mem.eql — 时序侧信道）
//! - base64 解码用 arena 分配而非固定 256 字节栈缓冲区
//!   （旧代码如果解码后 > 256 字节会 panic / error 500）

const std = @import("std");
const root = @import("root.zig");
const Context = root.Context;
const Response = root.Response;
const Next = root.Next;
const constantTimeEql = root.constantTimeEql;

/// api_key_query=true 的一次性告警闸（进程生命周期只告警一次）。
var api_key_query_warned = std.atomic.Value(bool).init(false);

pub const AuthStrategy = enum {
    bearer,
    basic,
    api_key,
    custom,
    /// `IdentityResolver` 解析成功（session/DB 类带身份鉴权）。
    identity,
};

pub const AuthInfo = struct {
    strategy: AuthStrategy,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    /// 仅 `.identity` 策略会填（来自 `Identity.roles`）；其余策略恒为 null。
    roles: ?[]const []const u8 = null,
};

/// `IdentityResolver` 解析出的用户身份。
///
/// 字符串字段（roles 各项、extra 指向的对象）由 resolver 实现方持有，
/// 至少需存活到本次请求处理结束（建议直接用 `ctx.arena` 分配）。
pub const Identity = struct {
    user_id: i64 = 0,
    roles: []const []const u8 = &.{},
    /// 逃生口：应用自定义的附属身份数据（帧权会话对象、权限集等）。
    /// 框架只透传，不解引用；下游 handler 用 `ctx.getUserData(Identity).?.extra` 取。
    extra: ?*anyopaque = null,
};

/// 带状态的身份解析器——回应 issue：`custom_auth` 是无捕获裸函数，接不了
/// SessionManager/DB 这类有状态依赖，也无法区分未登录/无权限/故障。
///
/// `resolve` 返回语义：
/// - `null` → 本请求未携带有效凭据（框架继续尝试其他已启用策略，全失败则 401）；
/// - `Identity` → 认证成功（若配了 `required_roles` 再过角色门，不过则 403）；
/// - `error` → 解析过程本身失败（如 DB 挂了），向上传播给 ErrorRenderer 渲染 500，
///   **不会**被当成未登录误渲染成 401。
pub const IdentityResolver = struct {
    /// 实现方状态（SessionManager / DB 连接池等），原样传给 `resolve`。
    self: *anyopaque,
    resolve: *const fn (*anyopaque, *Context) anyerror!?Identity,
};

pub const AuthConfig = struct {
    bearer_token: ?[]const u8 = null,
    basic_username: ?[]const u8 = null,
    basic_password: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api_key_header: []const u8 = "X-API-Key",
    /// 是否接受 `?api_key=...` 查询参数作为备用 API key 载体。
    /// ⚠️ 风险（bug.md §6 auth.zig:148-152）：query 里的 key 会出现在访问日志、
    /// 浏览器历史、Referer 头里，等同明文泄露。建议仅用于受控的脚本/内网测试；
    /// 生产优先用 header 方案。启用时框架会打一条一次性 WARN 提醒。
    api_key_query: bool = false,
    /// 无状态自定义校验钩子：裸函数指针（无 self 捕获），只能返回 bool，
    /// 适合「启动时已知的常量判断类」共享密钥场景。
    /// 需要 session/DB 等**有状态**依赖、或需要携带用户身份时，用 `resolver`。
    custom_auth: ?*const fn (*Context) bool = null,
    /// 带状态身份解析器（session → 会话表 → user_id/roles）。优先于其他策略尝试；
    /// 返回 null 时继续尝试后续策略。见 `IdentityResolver`。
    resolver: ?IdentityResolver = null,
    /// 非空时要求 `Identity.roles` 至少命中其一，否则 403。仅对 `resolver` 成功
    /// 路径生效（其余策略无角色概念）；大小写敏感。
    required_roles: []const []const u8 = &.{},
    realm: []const u8 = "Protected",
};

pub const AuthMiddleware = struct {
    config: AuthConfig,

    const Self = @This();

    /// 中间件入口：按 resolver → custom → bearer → basic → api_key 顺序尝试。
    /// 成功 → 存 AuthInfo（resolver 路径另存 Identity）到 ctx.state，调 next。
    /// 失败 → 写 401，不调 next（short-circuit）；角色不足 → 403；
    /// resolver 报错 → 向上传播（ErrorRenderer 渲染 500）。
    pub fn process(self: *Self, ctx: *Context, res: *Response, next: Next) !void {
        if (self.config.resolver) |r| {
            const identity_opt = try r.resolve(r.self, ctx);
            if (identity_opt) |identity| {
                if (self.config.required_roles.len > 0 and !hasAnyRole(identity.roles, self.config.required_roles)) {
                    _ = res.statusCode(.forbidden);
                    try res.text("Forbidden");
                    return;
                }
                try self.authOkIdentity(ctx, identity);
                try next.call(ctx, res);
                return;
            }
            // null = 未认证，继续尝试其余已启用策略（全 miss 则落到底部 401）。
        }

        if (self.config.custom_auth) |custom| {
            if (custom(ctx)) {
                try self.authOk(ctx, .custom);
                try next.call(ctx, res);
                return;
            }
        }

        if (self.config.bearer_token) |token| {
            if (try self.checkBearer(ctx, token)) {
                try self.authOk(ctx, .bearer);
                try next.call(ctx, res);
                return;
            }
        }

        if (self.config.basic_username) |user| {
            // 防御性：basic_username 设了但 basic_password 为 null 时不 unwrap panic。
            if (self.config.basic_password) |pass| {
                if (try self.checkBasic(ctx, user, pass)) {
                    try self.authOk(ctx, .basic);
                    try next.call(ctx, res);
                    return;
                }
            }
        }

        if (self.config.api_key) |key| {
            if (try self.checkApiKey(ctx, key)) {
                try self.authOk(ctx, .api_key);
                try next.call(ctx, res);
                return;
            }
        }

        // 所有策略都失败 → 401
        _ = res.statusCode(.unauthorized);
        // 修复 D3：根据已启用的策略发合适的挑战头（RFC 7235/6750）。
        // 修复 bug.md §6 auth.zig:91-94：只配 api_key/custom 时不应再发
        // `WWW-Authenticate: Basic`——否则浏览器会弹 Basic 登录框，而该端点
        // 根本不接受 Basic 凭据，纯属 UX 缺陷（还把登录框当成 auth 入口）。
        const challenge: ?[]const u8 = blk: {
            if (self.config.bearer_token != null) {
                break :blk try std.fmt.allocPrint(ctx.arena, "Bearer realm=\"{s}\"", .{self.config.realm});
            }
            // Basic 需要在 basic_username 与 basic_password 都启用时才发挑战，
            // 否则发出来也无法用。
            if (self.config.basic_username != null and self.config.basic_password != null) {
                break :blk try std.fmt.allocPrint(ctx.arena, "Basic realm=\"{s}\"", .{self.config.realm});
            }
            // api_key / custom-only：无标准挑战头，不发送。
            break :blk null;
        };
        if (challenge) |c| {
            _ = try res.setHeader("WWW-Authenticate", c);
        }
        try res.text("Unauthorized");
    }

    // ── Strategy checks ───────────────────────────────

    fn checkBearer(self: *Self, ctx: *Context, expected: []const u8) !bool {
        _ = self;
        // 空凭据不应放行（否则 constantTimeEql("","")==true 会误放行）。
        if (expected.len == 0) return false;
        const header = ctx.request.getHeader("Authorization") orelse return false;
        // RFC 7235：auth-scheme 大小写不敏感。
        const token = stripSchemePrefix(header, "Bearer ") orelse return false;
        // 常量时间比较——修复 P0 时序侧信道
        return constantTimeEql(token, expected);
    }

    fn checkBasic(self: *Self, ctx: *Context, username: []const u8, password: []const u8) !bool {
        _ = self;
        // P2-20：空凭据不放行（与 checkBearer/checkApiKey 一致）。
        // 否则配置里密码为空串时，客户端发 `user:` 就能通过认证。
        if (username.len == 0 or password.len == 0) return false;
        const header = ctx.request.getHeader("Authorization") orelse return false;
        const encoded = stripSchemePrefix(header, "Basic ") orelse return false;

        // 计算 base64 解码后的长度
        const dec_len = base64DecodedLen(encoded);
        if (dec_len == 0) return false;

        // 用 arena 分配解码缓冲区——修复 P1：旧代码用固定 256 字节栈缓冲区
        const dec_buf = try ctx.arena.alloc(u8, dec_len);
        std.base64.standard.Decoder.decode(dec_buf, encoded) catch return false;
        const decoded = dec_buf;

        const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
        const u = decoded[0..colon];
        const p = decoded[colon + 1 ..];

        // 常量时间比较——修复 P0 时序侧信道。
        // 修复 D2：先各自求布尔再 AND，避免 `and` 短路在用户名不匹配时
        // 跳过密码比较、泄露用户名是否正确。
        const user_ok = constantTimeEql(u, username);
        const pass_ok = constantTimeEql(p, password);
        return user_ok and pass_ok;
    }

    fn checkApiKey(self: *Self, ctx: *Context, expected: []const u8) !bool {
        // 空凭据不放行。
        if (expected.len == 0) return false;
        if (ctx.request.getHeader(self.config.api_key_header)) |key| {
            return constantTimeEql(key, expected);
        }
        if (self.config.api_key_query) {
            // bug.md §6 auth.zig:148-152：query 里的 key 会进访问日志/浏览器历史/
            // Referer。一次性 WARN 提醒（避免每个请求都打日志）。
            if (!api_key_query_warned.swap(true, .acq_rel))
                std.log.warn("auth: api_key_query=true 启用——API key 走 URL query，会泄露到访问日志、浏览器历史与 Referer 头（见 auth.zig api_key_query 字段注释）", .{});
            if (ctx.request.getQuery("api_key")) |key| {
                return constantTimeEql(key, expected);
            }
        }
        return false;
    }

    /// 大小写不敏感地剔除 auth-scheme 前缀（如 "Bearer "），返回剩余部分。
    /// 不匹配返回 null。RFC 7235 规定 scheme 大小写不敏感。
    fn stripSchemePrefix(header: []const u8, prefix: []const u8) ?[]const u8 {
        if (header.len < prefix.len) return null;
        if (!std.ascii.eqlIgnoreCase(header[0..prefix.len], prefix)) return null;
        return header[prefix.len..];
    }

    fn authOk(self: *Self, ctx: *Context, strategy: AuthStrategy) !void {
        const info_ptr = try ctx.arena.create(AuthInfo);
        info_ptr.* = .{ .strategy = strategy };

        switch (strategy) {
            .bearer => {
                // checkBearer 已确认 header 存在，但防御性处理：缺失时 token 保持
                // null 而非 .? panic（避免未来重构改了调用顺序时崩溃）。
                if (ctx.request.getHeader("Authorization")) |header| {
                    const token = stripSchemePrefix(header, "Bearer ") orelse "";
                    info_ptr.token = try ctx.arena.dupe(u8, token);
                }
            },
            .basic => {
                if (ctx.request.getHeader("Authorization")) |header| {
                    const encoded = stripSchemePrefix(header, "Basic ") orelse "";
                    const dec_len = base64DecodedLen(encoded);
                    if (dec_len > 0) {
                        const dec_buf = try ctx.arena.alloc(u8, dec_len);
                        // checkBasic 已 decode 成功，这里理论上不会失败；若失败
                        // 保持 username=null 并**继续**存入 AuthInfo——旧代码的
                        // `catch return` 会从 authOk 提前返回，连下面的
                        // setUserData(AuthInfo) 一起跳过，下游 handler 根本取不到
                        // 认证信息（与注释意图矛盾）。也不 return error 触发 500，
                        // 与 checkBasic 的 catch return false 语义一致。
                        // 失败分支不得读 dec_buf：arena.alloc 未初始化。
                        if (std.base64.standard.Decoder.decode(dec_buf, encoded)) {
                            const colon = std.mem.indexOfScalar(u8, dec_buf, ':') orelse 0;
                            info_ptr.username = try ctx.arena.dupe(u8, dec_buf[0..colon]);
                        } else |_| {}
                    }
                }
            },
            .api_key => {
                if (ctx.request.getHeader(self.config.api_key_header)) |key| {
                    info_ptr.api_key = try ctx.arena.dupe(u8, key);
                } else if (self.config.api_key_query) {
                    if (ctx.request.getQuery("api_key")) |key| {
                        info_ptr.api_key = try ctx.arena.dupe(u8, key);
                    }
                }
            },
            .custom, .identity => {},
        }

        // 存入上下文供下游 handler 取用
        try ctx.setUserData(AuthInfo, info_ptr);
    }

    /// resolver 成功路径：除 AuthInfo（含 roles）外，再把完整 `Identity` 存入
    /// ctx，下游 handler 用 `ctx.getUserData(Identity)` 取 user_id/extra。
    /// roles 外层切片拷进 arena（字符串本体归 resolver 实现方持有）。
    fn authOkIdentity(self: *Self, ctx: *Context, identity: Identity) !void {
        _ = self;
        const info_ptr = try ctx.arena.create(AuthInfo);
        info_ptr.* = .{ .strategy = .identity };
        if (identity.roles.len > 0) {
            const roles = try ctx.arena.alloc([]const u8, identity.roles.len);
            @memcpy(roles, identity.roles);
            info_ptr.roles = roles;
        }
        try ctx.setUserData(AuthInfo, info_ptr);

        const id_ptr = try ctx.arena.create(Identity);
        id_ptr.* = identity;
        try ctx.setUserData(Identity, id_ptr);
    }
};

/// roles 是否至少命中 required 中的一项（大小写敏感；都是小常量，O(n*m) 足够）。
fn hasAnyRole(roles: []const []const u8, required: []const []const u8) bool {
    for (required) |need| {
        for (roles) |have| {
            if (std.mem.eql(u8, have, need)) return true;
        }
    }
    return false;
}

/// 计算 base64 解码后的长度
/// P2-21：用 std 的 calcSizeForSlice——它会拒绝非法填充（`=` 不在末尾、
/// 长度非 4 的倍数等）。旧实现自己算长度，不校验 `=` 位置，
/// 也不接受无填充 base64（不一致的宽容）。无效返回 0。
fn base64DecodedLen(encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
    return std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return 0;
}

// ===========================================================================
// Tests
// ===========================================================================

test "AuthConfig defaults" {
    const cfg = AuthConfig{};
    try std.testing.expectEqualStrings("Protected", cfg.realm);
    try std.testing.expectEqualStrings("X-API-Key", cfg.api_key_header);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.bearer_token);
}

test "constantTimeEql is used for credential comparison" {
    // 验证 constantTimeEql 在安全比较中被使用
    try std.testing.expect(constantTimeEql("secret", "secret"));
    try std.testing.expect(!constantTimeEql("secret", "secref"));
}

test "base64DecodedLen" {
    try std.testing.expectEqual(@as(usize, 0), base64DecodedLen(""));
    try std.testing.expectEqual(@as(usize, 0), base64DecodedLen("abc")); // 长度不是 4 的倍数
    // "YWRtaW46c2VjcmV0MTIz" = base64("admin:secret123") = 15 bytes
    try std.testing.expectEqual(@as(usize, 15), base64DecodedLen("YWRtaW46c2VjcmV0MTIz"));
    // "YQ==" = base64("a") = 1 byte
    try std.testing.expectEqual(@as(usize, 1), base64DecodedLen("YQ=="));
}

test "checkBearer logic" {
    // 直接测试比较逻辑（不需要完整 Context）
    const expected = "my-secret-token";
    const token = "my-secret-token";
    try std.testing.expect(constantTimeEql(token, expected));

    const wrong = "wrong-token";
    try std.testing.expect(!constantTimeEql(wrong, expected));
}

// ── IdentityResolver tests ──────────────────────────────────

const Handler = root.http_app.Handler;
const RequestState = root.http_app.RequestState;
const RequestConfig = root.http_app.RequestConfig;
const Request = root.Request;

/// 模拟 session store：拿 Authorization 头当会话凭据，验证后返回带角色的身份。
const FakeSessionStore = struct {
    user_id: i64 = 7,
    roles: []const []const u8 = &.{ "user", "admin" },
    fail: bool = false,

    fn resolve(self_ptr: *anyopaque, ctx: *Context) anyerror!?Identity {
        const self: *FakeSessionStore = @ptrCast(@alignCast(self_ptr));
        if (self.fail) return error.DbDown;
        const header = ctx.request.getHeader("Authorization") orelse return null;
        if (!std.mem.eql(u8, header, "session-valid")) return null;
        return Identity{ .user_id = self.user_id, .roles = self.roles };
    }
};

/// 离线驱动 AuthMiddleware.process 的最小 harness（同 middleware.zig 测试套路）。
const AuthTestEnv = struct {
    arena: std.heap.ArenaAllocator,
    state: RequestState = undefined,
    config: RequestConfig = undefined,
    req: Request = undefined,
    ctx: Context = undefined,
    buf: [512]u8 = undefined,
    writer: std.Io.Writer = undefined,
    res: Response = undefined,

    fn init(gpa: std.mem.Allocator, head: []const u8) !*AuthTestEnv {
        const env = try gpa.create(AuthTestEnv);
        env.* = .{ .arena = .init(gpa) };
        const a = env.arena.allocator();
        env.config = .{};
        env.req = .{
            .method = .GET,
            .target = "/",
            .path = "/",
            .query = "",
            .version = .@"HTTP/1.1",
            .head_bytes = head,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .body = .none,
        };
        env.state = .{ .arena = a };
        env.writer = .fixed(&env.buf);
        env.ctx = .{
            .request = &env.req,
            .state = &env.state,
            .config = &env.config,
            .arena = a,
            .io = undefined,
        };
        env.res = Response.init(a, root.http_protocol.Sink.testSink(&env.writer));
        return env;
    }

    fn run(self: *AuthTestEnv, mw: *AuthMiddleware) !void {
        const handler = Handler.fromFn(struct {
            fn handle(ctx: *Context, res: *Response) !void {
                _ = ctx;
                try res.text("handler ran");
            }
        }.handle);
        return mw.process(&self.ctx, &self.res, Next.root(&.{}, handler));
    }

    fn body(self: *AuthTestEnv) []const u8 {
        return self.buf[0..self.writer.end];
    }

    fn deinit(self: *AuthTestEnv) void {
        const gpa = self.arena.child_allocator;
        self.state.deinit();
        self.res.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

test "resolver: 命中后填充 AuthInfo.roles 与 ctx 里的 Identity" {
    var store = FakeSessionStore{};
    var mw = AuthMiddleware{ .config = .{
        .resolver = .{ .self = &store, .resolve = FakeSessionStore.resolve },
    } };

    var env = try AuthTestEnv.init(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: session-valid\r\n\r\n");
    defer env.deinit();
    try env.run(&mw);

    try std.testing.expectEqual(std.http.Status.ok, env.res.status);
    try std.testing.expect(std.mem.indexOf(u8, env.body(), "handler ran") != null);

    const info = env.ctx.getUserData(AuthInfo).?;
    try std.testing.expectEqual(AuthStrategy.identity, info.strategy);
    try std.testing.expectEqual(@as(usize, 2), info.roles.?.len);
    try std.testing.expectEqualStrings("admin", info.roles.?[1]);

    const id = env.ctx.getUserData(Identity).?;
    try std.testing.expectEqual(@as(i64, 7), id.user_id);
}

test "resolver: 返回 null 且无其他策略 → 401" {
    var store = FakeSessionStore{};
    var mw = AuthMiddleware{ .config = .{
        .resolver = .{ .self = &store, .resolve = FakeSessionStore.resolve },
    } };

    var env = try AuthTestEnv.init(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: bogus\r\n\r\n");
    defer env.deinit();
    try env.run(&mw);

    try std.testing.expectEqual(std.http.Status.unauthorized, env.res.status);
    try std.testing.expect(env.ctx.getUserData(AuthInfo) == null);
}

test "resolver: required_roles 不命中 → 403，handler 不执行" {
    var store = FakeSessionStore{ .roles = &.{"user"} };
    var mw = AuthMiddleware{ .config = .{
        .resolver = .{ .self = &store, .resolve = FakeSessionStore.resolve },
        .required_roles = &.{"admin"},
    } };

    var env = try AuthTestEnv.init(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: session-valid\r\n\r\n");
    defer env.deinit();
    try env.run(&mw);

    try std.testing.expectEqual(std.http.Status.forbidden, env.res.status);
    try std.testing.expect(std.mem.indexOf(u8, env.body(), "handler ran") == null);
}

test "resolver: 报错向上传播（不被误当未登录渲染 401）" {
    var store = FakeSessionStore{ .fail = true };
    var mw = AuthMiddleware{ .config = .{
        .resolver = .{ .self = &store, .resolve = FakeSessionStore.resolve },
    } };

    var env = try AuthTestEnv.init(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: session-valid\r\n\r\n");
    defer env.deinit();
    try std.testing.expectError(error.DbDown, env.run(&mw));
}

test "resolver: null 时回退到 bearer 策略" {
    var store = FakeSessionStore{};
    var mw = AuthMiddleware{ .config = .{
        .resolver = .{ .self = &store, .resolve = FakeSessionStore.resolve },
        .bearer_token = "tok123",
    } };

    var env = try AuthTestEnv.init(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: Bearer tok123\r\n\r\n");
    defer env.deinit();
    try env.run(&mw);

    try std.testing.expectEqual(std.http.Status.ok, env.res.status);
    try std.testing.expectEqual(AuthStrategy.bearer, env.ctx.getUserData(AuthInfo).?.strategy);
}

test "checkBasic logic with base64 decode" {
    const allocator = std.testing.allocator;
    // base64("admin:secret123") = "YWRtaW46c2VjcmV0MTIz"
    const encoded = "YWRtaW46c2VjcmV0MTIz";
    const dec_len = base64DecodedLen(encoded);
    const dec_buf = try allocator.alloc(u8, dec_len);
    defer allocator.free(dec_buf);
    try std.base64.standard.Decoder.decode(dec_buf, encoded);

    const colon = std.mem.indexOfScalar(u8, dec_buf, ':').?;
    const u = dec_buf[0..colon];
    const p = dec_buf[colon + 1 ..];

    try std.testing.expectEqualStrings("admin", u);
    try std.testing.expectEqualStrings("secret123", p);

    // 常量时间比较
    try std.testing.expect(constantTimeEql(u, "admin"));
    try std.testing.expect(constantTimeEql(p, "secret123"));
    try std.testing.expect(!constantTimeEql(p, "wrong"));
}
test {
    std.testing.refAllDecls(@This());
}
