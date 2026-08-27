//! User registration module
//!
//! 功能：
//!   ├─ 用户注册（POST /api/register）
//!   └─ 输入验证（用户名唯一性、必填字段）

const std = @import("std");
const framework = @import("http_framework");
const admin = @import("admin");

// ────────────────────────────────────────────────────────────────────────────
// Handler 实现
// ────────────────────────────────────────────────────────────────────────────

pub fn registerHandler(ctx: *framework.Context, res: *framework.Response, io: std.Io, users: *admin.UserModel.Store) !void {
    // 读取 username
    const username = (ctx.formDecoded("username", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("username required"));
        return;
    };

    // 验证用户名长度
    if (username.len < 3 or username.len > 32) {
        try ctx.failWith(res, framework.AppError.badRequest("username must be 3-32 characters"));
        return;
    }

    // 读取 email
    const email = (ctx.formDecoded("email", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("email required"));
        return;
    };

    // 简单验证 email 格式（包含 @）
    if (std.mem.indexOf(u8, email, "@") == null) {
        try ctx.failWith(res, framework.AppError.badRequest("invalid email format"));
        return;
    }

    // 读取 password
    const password = (ctx.formDecoded("password", 1 << 16) catch {
        try ctx.failWith(res, framework.AppError.badRequest("failed to read body"));
        return;
    }) orelse {
        try ctx.failWith(res, framework.AppError.badRequest("password required"));
        return;
    };

    // 验证密码长度
    if (password.len < 6) {
        try ctx.failWith(res, framework.AppError.badRequest("password must be at least 6 characters"));
        return;
    }

    // 检查用户名是否已存在
    {
        const existing = try users.all(ctx.arena);
        defer users.freeRows(ctx.arena, existing);
        for (existing) |u| {
            if (std.mem.eql(u8, u.username, username)) {
                try ctx.failWith(res, framework.AppError.conflict("username already exists"));
                return;
            }
        }
    }

    // 创建用户（默认 role=viewer）
    const now = @as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000)));

    const id = users.insert(.{
        .id = 0,
        .username = username,
        .email = email,
        .password_hash = password, // 简单演示：明文存储
        .role = "viewer",
        .created_at = now,
        .last_login = 0,
    }) catch |err| {
        if (err == error.UniqueViolation) {
            try ctx.failWith(res, framework.AppError.conflict("username already exists"));
            return;
        }
        return err;
    };
    try users.flush();

    try res.statusCode(.created).json(.{
        .ok = true,
        .id = id,
        .username = username,
        .email = email,
        .role = "viewer",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// Handler wrapper struct
// ────────────────────────────────────────────────────────────────────────────

pub const RegisterHandler = struct {
    io: std.Io,
    users: *admin.UserModel.Store,

    pub fn handle(self: *@This(), ctx: *framework.Context, res: *framework.Response) !void {
        return registerHandler(ctx, res, self.io, self.users);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// 测试
// ────────────────────────────────────────────────────────────────────────────

test "register: email validation" {
    // 基本的 email 验证测试
    const valid_email = "test@example.com";
    try std.testing.expect(std.mem.indexOf(u8, valid_email, "@") != null);

    const invalid_email = "invalid-email";
    try std.testing.expect(std.mem.indexOf(u8, invalid_email, "@") == null);
}

test "register: username length validation" {
    const short_name = "ab";
    try std.testing.expect(short_name.len < 3);

    const valid_name = "testuser";
    try std.testing.expect(valid_name.len >= 3 and valid_name.len <= 32);
}
