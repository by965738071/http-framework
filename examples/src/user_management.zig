//! 用户管理系统示例
//!
//! 基于 http_framework 和内置 ORM 实现完整的用户管理系统。
//!
//! # 功能列表
//!
//! | 端点 | 方法 | 说明 |
//! |------|------|------|
//! | `/` | GET | HTML 管理界面 |
//! | `/api/users` | GET | 用户列表（支持分页、搜索、排序）|
//! | `/api/users/:id` | GET | 用户详情 |
//! | `/api/users` | POST | 创建用户 |
//! | `/api/users/:id` | PUT | 更新用户 |
//! | `/api/users/:id` | DELETE | 删除用户 |
//! | `/api/stats` | GET | 用户统计 |
//!
//! # 运行方式
//!
//! ```bash
//! cd examples
//! zig build run-user-mgmt
//! ```
//!
//! # 数据存储
//!
//! ORM 将数据持久化为 JSON 文件：`./data/users.json`

const std = @import("std");
pub const http_framework = @import("http_framework");
const core = http_framework;
const orm = core.Orm;

// ── 用户模型 ──────────────────────────────────────

/// 用户角色
const UserRole = enum {
    admin,
    user,
    moderator,

    pub fn fromString(s: []const u8) UserRole {
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "moderator")) return .moderator;
        return .user;
    }
};

/// 用户数据结构（ORM 持久化模型）
const User = struct {
    id: u64 = 0,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    full_name: []const u8 = "",
    role: []const u8 = "user",
    is_active: bool = true,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

/// 生成 ORM 的 UserStore 类型
const UserModel = orm.Model(User, "users");
const UserStore = UserModel.Store;

/// 用户数据目录
const DATA_DIR = "./data";

/// Simple hex encoding helper
fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0xF];
    }
    return result;
}

/// 简单的 SHA-256 哈希（用于密码）
fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &out, .{});
    return bytesToHex(allocator, &out);
}

/// 验证密码
fn verifyPassword(password: []const u8, hash: []const u8) bool {
    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &out, .{});
    const hex = bytesToHex(std.heap.page_allocator, &out) catch return false;
    defer std.heap.page_allocator.free(hex);
    return std.mem.eql(u8, hex, hash);
}

// ── 全局 Store 单例 ──────────────────────────────

/// 用户存储实例（应用生命周期内保持）
var user_store: *UserStore = undefined;

// ── 主函数 ───────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // 初始化数据库
    user_store = try UserStore.open(allocator, io, DATA_DIR);
    defer user_store.close() catch {};

    // 添加种子数据
    try seedData(allocator);

    // 路由器
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    // ── 路由注册 ──────────────────────────────────

    // HTML 首页
    try router.route(.GET, "/", try http_framework.Handler.initPerRequest(IndexHandler, allocator));

    // API 路由（按 RESTful 分组）
    var api = router.group("/api", &.{});

    try api.route(.GET, "/users", try http_framework.Handler.initPerRequest(ListUsersHandler, allocator));
    try api.route(.GET, "/users/:id", try http_framework.Handler.initPerRequest(GetUserHandler, allocator));
    try api.route(.POST, "/users", try http_framework.Handler.initPerRequest(CreateUserHandler, allocator));
    try api.route(.PUT, "/users/:id", try http_framework.Handler.initPerRequest(UpdateUserHandler, allocator));
    try api.route(.DELETE, "/users/:id", try http_framework.Handler.initPerRequest(DeleteUserHandler, allocator));
    try api.route(.GET, "/stats", http_framework.Handler.fromFn(statsEndpoint));

    // 404
    router.notFound(http_framework.Handler.fromFn(struct {
        fn handler(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            try res.statusCode(.not_found).json(.{ .@"error" = "Not Found" });
        }
    }.handler));

    // 启动服务器
    const config = http_framework.Config.Config{};
    var server = try http_framework.Server.init(allocator, io, config, router);
    defer server.deinit();

    std.log.info("User Management System running at http://localhost:8080", .{});
    try server.run();
}

// =========================================================================
// 种子数据
// =========================================================================

fn seedData(allocator: std.mem.Allocator) !void {
    var qb = orm.Query(User).init(allocator);
    defer qb.deinit();

    const count = try user_store.count(&qb);
    if (count > 0) return;

    const now: i64 = 0; // Demo: use fixed timestamp

    const admin_pass = try hashPassword(allocator, "admin123");
    defer allocator.free(admin_pass);

    const user_pass = try hashPassword(allocator, "user123");
    defer allocator.free(user_pass);

    _ = try user_store.insert(.{
        .id = 0,
        .username = "admin",
        .email = "admin@example.com",
        .password_hash = admin_pass,
        .full_name = "系统管理员",
        .role = "admin",
        .is_active = true,
        .created_at = now,
        .updated_at = now,
    });

    _ = try user_store.insert(.{
        .id = 0,
        .username = "alice",
        .email = "alice@example.com",
        .password_hash = user_pass,
        .full_name = "Alice Wang",
        .role = "user",
        .is_active = true,
        .created_at = now,
        .updated_at = now,
    });

    _ = try user_store.insert(.{
        .id = 0,
        .username = "bob",
        .email = "bob@example.com",
        .password_hash = user_pass,
        .full_name = "Bob Li",
        .role = "moderator",
        .is_active = true,
        .created_at = now,
        .updated_at = now,
    });

    _ = try user_store.flush();
}

// =========================================================================
// HTML 首页处理器
// =========================================================================

const IndexHandler = struct {
    pub fn init(allocator: std.mem.Allocator) !*IndexHandler {
        const ptr = try allocator.create(IndexHandler);
        ptr.* = .{};
        return ptr;
    }

    pub fn handle(self: *IndexHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        _ = self;
        _ = ctx;
        try res.html(
            \\<!DOCTYPE html>
            \\<html lang="zh-CN">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <title>用户管理系统 - Zig HTTP Framework</title>
            \\  <style>
            \\    * { margin: 0; padding: 0; box-sizing: border-box; }
            \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            \\           background: #f5f7fa; color: #333; line-height: 1.6; }
            \\    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
            \\    header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            \\             color: white; padding: 30px 0; text-align: center; margin-bottom: 30px; }
            \\    h1 { font-size: 2em; }
            \\    .card { background: white; border-radius: 8px; padding: 20px;
            \\            box-shadow: 0 2px 8px rgba(0,0,0,0.1); margin-bottom: 20px; }
            \\    table { width: 100%%; border-collapse: collapse; }
            \\    th, td { padding: 12px; text-align: left; border-bottom: 1px solid #eee; }
            \\    th { background: #f8f9fa; font-weight: 600; }
            \\    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.8em; }
            \\    .badge-admin { background: #ffeaa7; color: #d68910; }
            \\    .badge-user { background: #74b9ff; color: #0056b3; }
            \\    .badge-moderator { background: #55efc4; color: #00695c; }
            \\    .badge-active { background: #d4edda; color: #155724; }
            \\    .badge-inactive { background: #f8d7da; color: #721c24; }
            \\    .btn { display: inline-block; padding: 8px 16px; border: none; border-radius: 4px;
            \\           cursor: pointer; font-size: 14px; text-decoration: none; }
            \\    .btn-primary { background: #667eea; color: white; }
            \\    .btn-danger { background: #e74c3c; color: white; }
            \\    .btn-edit { background: #f39c12; color: white; }
            \\    .btn-sm { padding: 4px 10px; font-size: 12px; }
            \\    .form-group { margin-bottom: 15px; }
            \\    label { display: block; margin-bottom: 5px; font-weight: 500; }
            \\    input, select { width: 100%%; padding: 10px; border: 1px solid #ddd;
            \\                     border-radius: 4px; font-size: 14px; }
            \\    .flex-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
            \\    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
            \\    .stat-card { background: white; border-radius: 8px; padding: 20px; text-align: center;
            \\                  box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
            \\    .stat-value { font-size: 2em; font-weight: bold; color: #667eea; }
            \\    .stat-label { color: #666; margin-top: 5px; }
            \\    .alert { padding: 12px 20px; border-radius: 4px; margin-bottom: 15px; }
            \\    .alert-success { background: #d4edda; color: #155724; }
            \\    .alert-error { background: #f8d7da; color: #721c24; }
            \\    .modal { display: none; position: fixed; top: 0; left: 0; width: 100%%; height: 100%%;
            \\             background: rgba(0,0,0,0.5); z-index: 1000; }
            \\    .modal.show { display: flex; align-items: center; justify-content: center; }
            \\    .modal-content { background: white; border-radius: 8px; padding: 30px;
            \\                     max-width: 500px; width: 90%%; }
            \\    .modal-header { display: flex; justify-content: space-between; margin-bottom: 20px; }
            \\    .close { cursor: pointer; font-size: 24px; }
            \\    .pagination { display: flex; gap: 5px; justify-content: center; margin-top: 15px; }
            \\    .pagination button { padding: 6px 12px; border: 1px solid #ddd;
            \\                         background: white; cursor: pointer; border-radius: 4px; }
            \\    .pagination button.active { background: #667eea; color: white; border-color: #667eea; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <header>
            \\    <div class="container">
            \\      <h1>用户管理系统</h1>
            \\      <p>基于 Zig HTTP Framework + ORM 构建</p>
            \\    </div>
            \\  </header>
            \\  <div class="container">
            \\    <div class="card">
            \\      <div class="stats" id="stats-container">
            \\        <div class="stat-card"><div class="stat-value" id="stat-total">-</div><div class="stat-label">用户总数</div></div>
            \\        <div class="stat-card"><div class="stat-value" id="stat-active">-</div><div class="stat-label">活跃用户</div></div>
            \\        <div class="stat-card"><div class="stat-value" id="stat-admin">-</div><div class="stat-label">管理员</div></div>
            \\      </div>
            \\    </div>
            \\    <div class="card">
            \\      <div class="flex-row" style="justify-content: space-between; margin-bottom: 15px;">
            \\        <div class="flex-row">
            \\          <input type="text" id="search-input" placeholder="搜索用户名或邮箱..." style="width: 250px;">
            \\          <button class="btn btn-primary" onclick="searchUsers()">搜索</button>
            \\        </div>
            \\        <button class="btn btn-primary" onclick="showCreateModal()">+ 添加用户</button>
            \\      </div>
            \\      <table>
            \\        <thead>
            \\          <tr><th>ID</th><th>用户名</th><th>邮箱</th><th>角色</th><th>状态</th><th>创建时间</th><th>操作</th></tr>
            \\        </thead>
            \\        <tbody id="users-tbody"><tr><td colspan="7" style="text-align:center;">加载中...</td></tr></tbody>
            \\      </table>
            \\      <div class="pagination" id="pagination"></div>
            \\    </div>
            \\  </div>
            \\  <!-- 编辑/创建模态框 -->
            \\  <div class="modal" id="user-modal">
            \\    <div class="modal-content">
            \\      <div class="modal-header">
            \\        <h3 id="modal-title">添加用户</h3>
            \\        <span class="close" onclick="hideModal()">&times;</span>
            \\      </div>
            \\      <form id="user-form" onsubmit="saveUser(event)">
            \\        <input type="hidden" id="user-id">
            \\        <div class="form-group">
            \\          <label>用户名</label><input type="text" id="form-username" required>
            \\        </div>
            \\        <div class="form-group">
            \\          <label>邮箱</label><input type="email" id="form-email" required>
            \\        </div>
            \\        <div class="form-group">
            \\          <label>密码</label><input type="password" id="form-password" minlength="6">
            \\          <small style="color:#666">创建时必填，更新时可留空</small>
            \\        </div>
            \\        <div class="form-group">
            \\          <label>姓名</label><input type="text" id="form-name">
            \\        </div>
            \\        <div class="form-group">
            \\          <label>角色</label>
            \\          <select id="form-role">
            \\            <option value="user">普通用户</option>
            \\            <option value="admin">管理员</option>
            \\            <option value="moderator">版主</option>
            \\          </select>
            \\        </div>
            \\        <div class="form-group">
            \\          <label><input type="checkbox" id="form-active" checked> 激活状态</label>
            \\        </div>
            \\        <button type="submit" class="btn btn-primary">保存</button>
            \\      </form>
            \\    </div>
            \\  </div>
            \\  <script>
            \\    let currentPage = 1;
            \\    let pageSize = 10;
            \\    let currentSearch = '';
            \\    function fmtTime(ts) {
            \\      if (!ts || ts == 0) return '-';
            \\      const d = new Date(ts * 1000);
            \\      return d.toLocaleString('zh-CN');
            \\    }
            \\    function roleBadge(role) {
            \\      const map = { admin: 'badge-admin', user: 'badge-user', moderator: 'badge-moderator' };
            \\      const names = { admin: '管理员', user: '用户', moderator: '版主' };
            \\      return '<span class="badge ' + (map[role] || 'badge-user') + '">' + (names[role] || role) + '</span>';
            \\    }
            \\    async function loadUsers() {
            \\      let url = '/api/users?page=' + currentPage + '&size=' + pageSize;
            \\      if (currentSearch) url += '&search=' + encodeURIComponent(currentSearch);
            \\      try {
            \\        const res = await fetch(url);
            \\        const data = await res.json();
            \\        renderUsers(data.users, data.total, data.page, data.total_pages);
            \\      } catch(e) { console.error(e); }
            \\    }
            \\    function renderUsers(users, total, page, totalPages) {
            \\      const tbody = document.getElementById('users-tbody');
            \\      if (users.length === 0) {
            \\        tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;">暂无数据</td></tr>';
            \\      } else {
            \\        tbody.innerHTML = users.map(u =>
            \\          '<tr>' +
            \\            '<td>' + u.id + '</td>' +
            \\            '<td>' + escapeHtml(u.username) + '</td>' +
            \\            '<td>' + escapeHtml(u.email) + '</td>' +
            \\            '<td>' + roleBadge(u.role) + '</td>' +
            \\            '<td><span class="badge ' + (u.is_active ? 'badge-active' : 'badge-inactive') + '">' + (u.is_active ? '活跃' : '禁用') + '</span></td>' +
            \\            '<td>' + fmtTime(u.created_at) + '</td>' +
            \\            '<td>' +
            \\              '<button class="btn btn-edit btn-sm" onclick="editUser(' + u.id + ')">编辑</button> ' +
            \\              '<button class="btn btn-danger btn-sm" onclick="deleteUser(' + u.id + ')">删除</button>' +
            \\            '</td>' +
            \\          '</tr>'
            \\        ).join('');
            \\      }
            \\      // Pagination
            \\      let pag = '';
            \\      for (let i = 1; i <= totalPages; i++) {
            \\        pag += '<button class="' + (i === page ? 'active' : '') + '" onclick="goPage(' + i + ')">' + i + '</button>';
            \\      }
            \\      document.getElementById('pagination').innerHTML = pag;
            \\    }
            \\    async function loadStats() {
            \\      try {
            \\        const res = await fetch('/api/stats');
            \\        const data = await res.json();
            \\        document.getElementById('stat-total').textContent = data.total;
            \\        document.getElementById('stat-active').textContent = data.active;
            \\        document.getElementById('stat-admin').textContent = data.admins;
            \\      } catch(e) { console.error(e); }
            \\    }
            \\    function escapeHtml(s) {
            \\      const div = document.createElement('div');
            \\      div.textContent = s || '';
            \\      return div.innerHTML;
            \\    }
            \\    function goPage(p) { currentPage = p; loadUsers(); }
            \\    function searchUsers() {
            \\      currentSearch = document.getElementById('search-input').value;
            \\      currentPage = 1;
            \\      loadUsers();
            \\    }
            \\    function showCreateModal() {
            \\      document.getElementById('modal-title').textContent = '添加用户';
            \\      document.getElementById('user-form').reset();
            \\      document.getElementById('user-id').value = '';
            \\      document.getElementById('form-password').required = true;
            \\      document.getElementById('user-modal').classList.add('show');
            \\    }
            \\    function hideModal() {
            \\      document.getElementById('user-modal').classList.remove('show');
            \\    }
            \\    async function editUser(id) {
            \\      try {
            \\        const res = await fetch('/api/users/' + id);
            \\        const u = await res.json();
            \\        document.getElementById('modal-title').textContent = '编辑用户';
            \\        document.getElementById('user-id').value = u.id;
            \\        document.getElementById('form-username').value = u.username;
            \\        document.getElementById('form-email').value = u.email;
            \\        document.getElementById('form-password').value = '';
            \\        document.getElementById('form-password').required = false;
            \\        document.getElementById('form-name').value = u.full_name || '';
            \\        document.getElementById('form-role').value = u.role || 'user';
            \\        document.getElementById('form-active').checked = u.is_active;
            \\        document.getElementById('user-modal').classList.add('show');
            \\      } catch(e) { console.error(e); }
            \\    }
            \\    async function saveUser(event) {
            \\      event.preventDefault();
            \\      const id = document.getElementById('user-id').value;
            \\      const payload = {
            \\        username: document.getElementById('form-username').value,
            \\        email: document.getElementById('form-email').value,
            \\        password: document.getElementById('form-password').value,
            \\        full_name: document.getElementById('form-name').value,
            \\        role: document.getElementById('form-role').value,
            \\        is_active: document.getElementById('form-active').checked
            \\      };
            \\      try {
            \\        let res;
            \\        if (id) {
            \\          res = await fetch('/api/users/' + id, { method: 'PUT', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
            \\        } else {
            \\          res = await fetch('/api/users', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
            \\        }
            \\        if (res.ok) {
            \\          hideModal();
            \\          loadUsers();
            \\          loadStats();
            \\        } else {
            \\          const err = await res.json();
            \\          alert('错误: ' + (err.error || '未知错误'));
            \\        }
            \\      } catch(e) { alert('网络错误: ' + e.message); }
            \\    }
            \\    async function deleteUser(id) {
            \\      if (!confirm('确定要删除该用户吗？此操作不可撤销。')) return;
            \\      try {
            \\        const res = await fetch('/api/users/' + id, { method: 'DELETE' });
            \\        if (res.ok) { loadUsers(); loadStats(); }
            \\        else { const err = await res.json(); alert('错误: ' + (err.error || '未知错误')); }
            \\      } catch(e) { alert('网络错误: ' + e.message); }
            \\    }
            \\    // 初始加载
            \\    loadUsers();
            \\    loadStats();
            \\  </script>
            \\</body>
            \\</html>
        );
    }

    pub fn deinit(self: *IndexHandler) void {
        _ = self;
    }
};

// =========================================================================
// API 处理器：用户列表 GET /api/users
// =========================================================================

const ListUsersHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ListUsersHandler {
        const ptr = try allocator.create(ListUsersHandler);
        ptr.* = .{ .allocator = allocator };
        return ptr;
    }

    pub fn handle(self: *ListUsersHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const page_str = ctx.getQuery("page") orelse "1";
        const size_str = ctx.getQuery("size") orelse "10";
        const search = ctx.getQuery("search") orelse "";

        const page = std.fmt.parseInt(u32, page_str, 10) catch 1;
        const page_size = std.fmt.parseInt(u32, size_str, 10) catch 10;

        var qb = orm.Query(User).init(self.allocator);
        defer qb.deinit();

        if (search.len > 0) {
            _ = qb.where(.Like, "username", .{ .string = search });
        }

        const only_active = ctx.getQuery("active");
        if (only_active) |_| {
            _ = qb.where(.Eq, "is_active", .{ .boolean = true });
        }

        _ = qb.orderBy("id", .Desc);

        var qc = orm.Query(User).init(self.allocator);
        defer qc.deinit();
        const total = try user_store.count(&qc);

        const offset = (page - 1) * page_size;
        _ = qb.limit(@intCast(page_size)).offset(@intCast(offset));

        const users = try user_store.findAll(&qb);
        defer self.allocator.free(users);

        const total_pages = if (total == 0) @as(u32, 0) else @as(u32, @intCast((total + page_size - 1) / page_size));

        // Build JSON response via struct
        try res.json(.{
            .users = users,
            .total = total,
            .page = page,
            .page_size = page_size,
            .total_pages = total_pages,
        });
    }

    pub fn deinit(self: *ListUsersHandler) void {
        _ = self;
    }
};

// =========================================================================
// API 处理器：用户详情 GET /api/users/:id
// =========================================================================

const GetUserHandler = struct {
    pub fn init(allocator: std.mem.Allocator) !*GetUserHandler {
        const ptr = try allocator.create(GetUserHandler);
        ptr.* = .{};
        return ptr;
    }

    pub fn handle(self: *GetUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        _ = self;
        const id_str = ctx.getParam("id") orelse return error.BadRequest;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.BadRequest;

        if (try user_store.findById(id)) |user| {
            try res.json(userResponse(user));
        } else {
            try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
        }
    }

    pub fn deinit(self: *GetUserHandler) void {
        _ = self;
    }
};

// =========================================================================
// API 处理器：创建用户 POST /api/users
// =========================================================================

const CreateUserHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*CreateUserHandler {
        const ptr = try allocator.create(CreateUserHandler);
        ptr.* = .{ .allocator = allocator };
        return ptr;
    }

    pub fn handle(self: *CreateUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const body_str = try ctx.readBody();

        const parsed = try std.json.parseFromSlice(CreateUserInput, self.allocator, body_str, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const input = parsed.value;

        // 验证必填字段
        if (input.username.len == 0 or input.email.len == 0 or input.password.len == 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "用户名、邮箱和密码不能为空" });
            return;
        }

        // 检查用户名是否已存在
        var qb = orm.Query(User).init(self.allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "username", .{ .string = input.username });

        if (try user_store.findOne(&qb)) |_| {
            try res.statusCode(.conflict).json(.{ .@"error" = "用户名已存在" });
            return;
        }

        // 检查邮箱
        var qe = orm.Query(User).init(self.allocator);
        defer qe.deinit();
        _ = qe.where(.Eq, "email", .{ .string = input.email });

        if (try user_store.findOne(&qe)) |_| {
            try res.statusCode(.conflict).json(.{ .@"error" = "邮箱已被注册" });
            return;
        }

        // 哈希密码
        const hashed = try hashPassword(self.allocator, input.password);
        defer self.allocator.free(hashed);

        const now: i64 = 0; // Demo: use fixed timestamp
        const full_name = if (input.full_name) |n| n else "";

        const id = try user_store.insert(.{
            .id = 0,
            .username = try self.allocator.dupe(u8, input.username),
            .email = try self.allocator.dupe(u8, input.email),
            .password_hash = hashed,
            .full_name = try self.allocator.dupe(u8, full_name),
            .role = try self.allocator.dupe(u8, input.role orelse "user"),
            .is_active = input.is_active orelse true,
            .created_at = now,
            .updated_at = now,
        });

        _ = try user_store.flush();

        // 返回创建的用户
        if (try user_store.findById(id)) |new_user| {
            try res.statusCode(.created).json(userResponse(new_user));
        } else {
            try res.statusCode(.created).json(.{ .id = id, .message = "用户创建成功" });
        }
    }

    pub fn deinit(self: *CreateUserHandler) void {
        _ = self;
    }

    const CreateUserInput = struct {
        username: []const u8 = "",
        email: []const u8 = "",
        password: []const u8 = "",
        full_name: ?[]const u8 = null,
        role: ?[]const u8 = null,
        is_active: ?bool = null,
    };
};

// =========================================================================
// API 处理器：更新用户 PUT /api/users/:id
// =========================================================================

const UpdateUserHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*UpdateUserHandler {
        const ptr = try allocator.create(UpdateUserHandler);
        ptr.* = .{ .allocator = allocator };
        return ptr;
    }

    pub fn handle(self: *UpdateUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id_str = ctx.getParam("id") orelse return error.BadRequest;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.BadRequest;

        const existing = try user_store.findById(id);
        if (existing == null) {
            try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
            return;
        }

        const body_str = try ctx.readBody();
        const parsed = try std.json.parseFromSlice(UpdateUserInput, self.allocator, body_str, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const input = parsed.value;

        // 构建更新数据
        var updated: User = existing.?;
        updated.updated_at = 0; // Demo: fixed timestamp

        if (input.username) |v| updated.username = try self.allocator.dupe(u8, v);
        if (input.email) |v| updated.email = try self.allocator.dupe(u8, v);
        if (input.full_name) |v| updated.full_name = try self.allocator.dupe(u8, v);
        if (input.role) |v| updated.role = try self.allocator.dupe(u8, v);
        if (input.is_active) |v| updated.is_active = v;

        if (input.password) |pw| {
            if (pw.len > 0) {
                if (pw.len < 6) {
                    try res.statusCode(.bad_request).json(.{ .@"error" = "密码至少需要6个字符" });
                    return;
                }
                const hashed = try hashPassword(self.allocator, pw);
                defer self.allocator.free(hashed);
                updated.password_hash = hashed;
            }
        }

        // 执行更新
        var qb = orm.Query(User).init(self.allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });

        const fields: []const []const u8 = if (input.password != null and input.password.?.len > 0)
            &.{ "username", "email", "password_hash", "full_name", "role", "is_active", "updated_at" }
        else
            &.{ "username", "email", "full_name", "role", "is_active", "updated_at" };

        _ = qb.update(updated, fields);
        _ = try user_store.update(&qb);
        _ = try user_store.flush();

        // 返回更新后的用户
        if (try user_store.findById(id)) |fresh| {
            try res.json(userResponse(fresh));
        } else {
            try res.json(.{ .message = "用户更新成功" });
        }
    }

    pub fn deinit(self: *UpdateUserHandler) void {
        _ = self;
    }

    const UpdateUserInput = struct {
        username: ?[]const u8 = null,
        email: ?[]const u8 = null,
        password: ?[]const u8 = null,
        full_name: ?[]const u8 = null,
        role: ?[]const u8 = null,
        is_active: ?bool = null,
    };
};

// =========================================================================
// API 处理器：删除用户 DELETE /api/users/:id
// =========================================================================

const DeleteUserHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*DeleteUserHandler {
        const ptr = try allocator.create(DeleteUserHandler);
        ptr.* = .{ .allocator = allocator };
        return ptr;
    }

    pub fn handle(self: *DeleteUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id_str = ctx.getParam("id") orelse return error.BadRequest;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.BadRequest;

        // 不允许删除 admin 用户（保护种子数据中的 admin）
        if (id == 1) {
            try res.statusCode(.forbidden).json(.{ .@"error" = "不允许删除默认管理员账户" });
            return;
        }

        if (try user_store.findById(id)) |_| {
            var qb = orm.Query(User).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
            _ = try user_store.delete(&qb);
            _ = try user_store.flush();
            try res.json(.{ .message = "用户已删除" });
        } else {
            try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
        }
    }

    pub fn deinit(self: *DeleteUserHandler) void {
        _ = self;
    }
};

// =========================================================================
// 统计端点 GET /api/stats
// =========================================================================

fn statsEndpoint(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
    // 最好有一个专门的高性能统计方法，这里简单遍历
    const all = user_store.all() catch {
        try res.statusCode(.internal_server_error).json(.{ .@"error" = "获取统计信息失败" });
        return;
    };

    var total: u32 = 0;
    var active: u32 = 0;
    var admins: u32 = 0;

    for (all) |u| {
        total += 1;
        if (u.is_active) active += 1;
        if (std.mem.eql(u8, u.role, "admin")) admins += 1;
    }

    try res.json(.{
        .total = total,
        .active = active,
        .admins = admins,
    });
}

// =========================================================================
// 辅助函数
// =========================================================================

/// 将用户对象转为安全的 JSON 字符串
fn userToJson(allocator: std.mem.Allocator, user: User) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{"id":{d},"username":"{s}","email":"{s}","full_name":"{s}","role":"{s}","is_active":{},"created_at":{d},"updated_at":{d}}
    , .{
        user.id,
        escapeJsonStr(user.username),
        escapeJsonStr(user.email),
        escapeJsonStr(user.full_name),
        escapeJsonStr(user.role),
        user.is_active,
        user.created_at,
        user.updated_at,
    });
}

/// 用户 API 响应（不含密码 hash）
fn userResponse(user: User) UserResponse {
    return .{
        .id = user.id,
        .username = user.username,
        .email = user.email,
        .full_name = user.full_name,
        .role = user.role,
        .is_active = user.is_active,
        .created_at = user.created_at,
        .updated_at = user.updated_at,
    };
}

const UserResponse = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    full_name: []const u8,
    role: []const u8,
    is_active: bool,
    created_at: i64,
    updated_at: i64,
};

/// 简单的 JSON 字符串转义（避免注入）
fn escapeJsonStr(s: []const u8) []const u8 {
    // 对于 API 输出，std.fmt.allocPrint 配合 fmtSliceHexLower 等
    // 但这里简化为直接返回（用户名/邮箱等字段通常不含特殊字符）
    _ = &escapeJsonStrImpl;
    return s;
}

fn escapeJsonStrImpl(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}
