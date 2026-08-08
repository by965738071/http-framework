//! 后台管理系统示例（综合演示）
//!
//! 基于 http_framework + 内置 ORM 实现的单页后台管理系统，包含两大模块：
//!
//! | 模块 | 说明 |
//! |------|------|
//! | 用户管理 | 用户的增删改查（列表/搜索/分页、详情、创建、更新、删除）|
//! | 数据管理 | 商品（Product）的增删改查，演示第二类实体的 CRUD 模式 |
//!
//! 每个模块都通过统一的左侧导航切换，演示如何在一个进程内组合多个 CRUD 模块。
//!
//! # 端点一览
//!
//! 用户管理：
//! - `GET  /api/users`            列表（分页 / 搜索 / 排序）
//! - `GET  /api/users/:id`        详情
//! - `POST /api/users`            创建
//! - `PUT  /api/users/:id`        更新
//! - `DELETE /api/users/:id`      删除
//!
//! 数据管理（商品）：
//! - `GET  /api/products`          列表
//! - `GET  /api/products/:id`      详情
//! - `POST /api/products`          创建
//! - `PUT  /api/products/:id`      更新
//! - `DELETE /api/products/:id`    删除
//!
//! 汇总：
//! - `GET  /api/dashboard`         用户数 / 商品数等统计
//!
//! # 运行
//!
//! ```bash
//! cd examples
//! zig build run-admin
//! ```
//!
//! # 数据存储
//!
//! ORM 将数据持久化为 JSON 文件：`./data/users.json`、`./data/products.json`

const std = @import("std");
pub const http_framework = @import("http_framework");
const orm = @import("orm");

// =========================================================================
// 模型定义
// =========================================================================

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

/// 用户模型（ORM 持久化）
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

/// 商品模型（ORM 持久化）—— 演示第二类实体的 CRUD
const Product = struct {
    id: u64 = 0,
    name: []const u8,
    category: []const u8 = "未分类",
    price: f64 = 0,
    stock: u32 = 0,
    description: []const u8 = "",
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

/// 由模型生成 ORM Store 类型
const UserStore = orm.Model(User, "users").Store;
const ProductStore = orm.Model(Product, "products").Store;

const DATA_DIR = "./data";

// ── 密码哈希辅助 ──────────────────────────────────

fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0xF];
    }
    return result;
}

fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &out, .{});
    return bytesToHex(allocator, &out);
}

// ── 全局 Store 单例（应用生命周期内保持）───────────

var user_store: *UserStore = undefined;
var product_store: *ProductStore = undefined;

fn nowTs() i64 {
    // 本 Zig dev 版本未提供 wall-clock 秒级时间 API；与 user_management 示例保持一致，
    // 使用固定时间戳（前端对 0 展示为 "-"）。如需真实时间，可在此接入 std.Io.Timestamp 或系统时钟。
    return 0;
}

// =========================================================================
// 主函数
// =========================================================================

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();
    const io = init.io;

    // 初始化数据库（JSON 文件存储）
    user_store = try UserStore.open(allocator, io, DATA_DIR);
    
    defer user_store.close() catch {};
    product_store = try ProductStore.open(allocator, io, DATA_DIR);
    defer product_store.close() catch {};

    try seedData(allocator);

    // 路由器
    var router = http_framework.Router.init(allocator);
    defer router.deinit();

    // 首页（单页后台）
    try router.route(.GET, "/", http_framework.Handler.fromFn(indexHandler));

    // 用户管理 API
    var api = router.group("/api", &.{});
    try api.route(.GET, "/users", try http_framework.Handler.initPerRequest(ListUsersHandler, allocator));
    try api.route(.GET, "/users/:id", try http_framework.Handler.initPerRequest(GetUserHandler, allocator));
    try api.route(.POST, "/users", try http_framework.Handler.initPerRequest(CreateUserHandler, allocator));
    try api.route(.PUT, "/users/:id", try http_framework.Handler.initPerRequest(UpdateUserHandler, allocator));
    try api.route(.DELETE, "/users/:id", try http_framework.Handler.initPerRequest(DeleteUserHandler, allocator));

    // 数据管理 API（商品）
    try api.route(.GET, "/products", try http_framework.Handler.initPerRequest(ListProductsHandler, allocator));
    try api.route(.GET, "/products/:id", try http_framework.Handler.initPerRequest(GetProductHandler, allocator));
    try api.route(.POST, "/products", try http_framework.Handler.initPerRequest(CreateProductHandler, allocator));
    try api.route(.PUT, "/products/:id", try http_framework.Handler.initPerRequest(UpdateProductHandler, allocator));
    try api.route(.DELETE, "/products/:id", try http_framework.Handler.initPerRequest(DeleteProductHandler, allocator));

    // 汇总统计
    try api.route(.GET, "/dashboard", http_framework.Handler.fromFn(dashboardHandler));

    // 404
    router.notFound(http_framework.Handler.fromFn(struct {
        fn handler(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
            try res.statusCode(.not_found).json(.{ .@"error" = "Not Found" });
        }
    }.handler));

    const config = http_framework.Config{};
    var server = try http_framework.Server.init(allocator, io, config, &router);
    defer server.deinit();

    std.log.info("后台管理系统运行于 http://{s}:{d}", .{ config.address, config.port });
    try server.run();
}

// =========================================================================
// 种子数据
// =========================================================================

fn seedData(allocator: std.mem.Allocator) !void {
    // 用户种子
    {
        var qb = orm.Query(User).init(allocator);
        defer qb.deinit();
        if (try user_store.count(&qb) == 0) {
            const admin_pass = try hashPassword(allocator, "admin123");
            defer allocator.free(admin_pass);
            const user_pass = try hashPassword(allocator, "user123");
            defer allocator.free(user_pass);
            const ts = nowTs();

            _ = try user_store.insert(.{
                .id = 0,
                .username = "admin",
                .email = "admin@example.com",
                .password_hash = admin_pass,
                .full_name = "系统管理员",
                .role = "admin",
                .is_active = true,
                .created_at = ts,
                .updated_at = ts,
            });
            _ = try user_store.insert(.{
                .id = 0,
                .username = "alice",
                .email = "alice@example.com",
                .password_hash = user_pass,
                .full_name = "Alice Wang",
                .role = "user",
                .is_active = true,
                .created_at = ts,
                .updated_at = ts,
            });
            _ = try user_store.insert(.{
                .id = 0,
                .username = "bob",
                .email = "bob@example.com",
                .password_hash = user_pass,
                .full_name = "Bob Li",
                .role = "moderator",
                .is_active = true,
                .created_at = ts,
                .updated_at = ts,
            });
            _ = try user_store.flush();
        }
    }

    // 商品种子
    {
        var qb = orm.Query(Product).init(allocator);
        defer qb.deinit();
        if (try product_store.count(&qb) == 0) {
            const ts = nowTs();
            const samples = [_]Product{
                .{ .id = 0, .name = "机械键盘", .category = "外设", .price = 399.0, .stock = 120, .description = "RGB 背光青轴机械键盘", .created_at = ts, .updated_at = ts },
                .{ .id = 0, .name = "人体工学椅", .category = "家具", .price = 1299.0, .stock = 40, .description = "可调节腰托办公椅", .created_at = ts, .updated_at = ts },
                .{ .id = 0, .name = "4K 显示器", .category = "外设", .price = 1899.0, .stock = 65, .description = "27 英寸 IPS 显示器", .created_at = ts, .updated_at = ts },
                .{ .id = 0, .name = "无线鼠标", .category = "外设", .price = 199.0, .stock = 200, .description = "静音无线鼠标", .created_at = ts, .updated_at = ts },
            };
            for (samples) |p| _ = try product_store.insert(p);
            _ = try product_store.flush();
        }
    }
}

// =========================================================================
// 首页（单页后台 UI）
// =========================================================================

fn indexHandler(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
    try res.html(htmlShell());
}

/// 公共 CSS（两个模块共用）
const CSS =
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    \\       background: #f5f7fa; color: #333; line-height: 1.6; }
    \\.layout { display: flex; min-height: 100vh; }
    \\.sidebar { width: 220px; background: #2c3e50; color: #ecf0f1; padding: 20px 0; flex-shrink: 0; }
    \\.sidebar h2 { font-size: 1.1em; text-align: center; margin-bottom: 20px; padding: 0 15px; }
    \\.sidebar a { display: block; padding: 12px 24px; color: #bdc3c7; cursor: pointer; text-decoration: none; }
    \\.sidebar a:hover, .sidebar a.active { background: #34495e; color: #fff; }
    \\.main { flex: 1; padding: 24px; overflow-y: auto; }
    \\.card { background: white; border-radius: 8px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin-bottom: 20px; }
    \\.flex-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; justify-content: space-between; margin-bottom: 15px; }
    \\table { width: 100%; border-collapse: collapse; }
    \\th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #eee; }
    \\th { background: #f8f9fa; font-weight: 600; }
    \\.btn { display: inline-block; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-size: 14px; text-decoration: none; }
    \\.btn-primary { background: #667eea; color: white; }
    \\.btn-danger { background: #e74c3c; color: white; }
    \\.btn-edit { background: #f39c12; color: white; }
    \\.btn-sm { padding: 4px 10px; font-size: 12px; }
    \\.badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.8em; }
    \\.badge-active { background: #d4edda; color: #155724; }
    \\.badge-inactive { background: #f8d7da; color: #721c24; }
    \\input, select, textarea { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; font-family: inherit; }
    \\.form-group { margin-bottom: 15px; }
    \\label { display: block; margin-bottom: 5px; font-weight: 500; }
    \\.modal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.5); z-index: 1000; }
    \\.modal.show { display: flex; align-items: center; justify-content: center; }
    \\.modal-content { background: white; border-radius: 8px; padding: 30px; max-width: 520px; width: 90%; max-height: 90vh; overflow-y: auto; }
    \\.modal-header { display: flex; justify-content: space-between; margin-bottom: 20px; }
    \\.close { cursor: pointer; font-size: 24px; }
    \\.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 15px; }
    \\.stat-card { background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
    \\.stat-value { font-size: 2em; font-weight: bold; color: #667eea; }
    \\.stat-label { color: #666; margin-top: 5px; }
    \\.panel { display: none; }
    \\.panel.active { display: block; }
    \\.hidden { display: none; }
;

/// 首页 HTML + 两个模块的 JS
fn htmlShell() []const u8 {
    return
    \\<!DOCTYPE html>
    \\<html lang="zh-CN">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>后台管理系统 - Zig HTTP Framework</title>
    \\  <style>
    ++ CSS ++
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="layout">
        \\    <div class="sidebar">
        \\      <h2>后台管理系统</h2>
        \\      <a id="nav-users" class="active" onclick="switchPanel('users')">用户管理</a>
        \\      <a id="nav-products" onclick="switchPanel('products')">数据管理</a>
        \\      <a onclick="loadDashboard()">仪表盘</a>
        \\    </div>
        \\    <div class="main">
        \\      <!-- 仪表盘 -->
        \\      <div id="panel-dashboard" class="panel">
        \\        <div class="card"><div class="stats" id="dashboard-stats"></div></div>
        \\      </div>
        \\      <!-- 用户管理 -->
        \\      <div id="panel-users" class="panel active">
        \\        <div class="card">
        \\          <div class="flex-row">
        \\            <div class="flex-row">
        \\              <input type="text" id="user-search" placeholder="搜索用户名/邮箱..." style="width:240px;">
        \\              <button class="btn btn-primary" onclick="searchUsers()">搜索</button>
        \\            </div>
        \\            <button class="btn btn-primary" onclick="showUserModal()">+ 添加用户</button>
        \\          </div>
        \\          <table>
        \\            <thead><tr><th>ID</th><th>用户名</th><th>邮箱</th><th>角色</th><th>状态</th><th>操作</th></tr></thead>
        \\            <tbody id="users-tbody"><tr><td colspan="6" style="text-align:center;">加载中...</td></tr></tbody>
        \\          </table>
        \\          <div id="users-pagination" style="margin-top:12px;"></div>
        \\        </div>
        \\      </div>
        \\      <!-- 数据管理（商品） -->
        \\      <div id="panel-products" class="panel">
        \\        <div class="card">
        \\          <div class="flex-row">
        \\            <div class="flex-row">
        \\              <input type="text" id="product-search" placeholder="搜索商品名/分类..." style="width:240px;">
        \\              <button class="btn btn-primary" onclick="searchProducts()">搜索</button>
        \\            </div>
        \\            <button class="btn btn-primary" onclick="showProductModal()">+ 添加商品</button>
        \\          </div>
        \\          <table>
        \\            <thead><tr><th>ID</th><th>名称</th><th>分类</th><th>价格</th><th>库存</th><th>操作</th></tr></thead>
        \\            <tbody id="products-tbody"><tr><td colspan="6" style="text-align:center;">加载中...</td></tr></tbody>
        \\          </table>
        \\          <div id="products-pagination" style="margin-top:12px;"></div>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </div>
        \\
        \\  <!-- 用户模态框 -->
        \\  <div class="modal" id="user-modal"><div class="modal-content">
        \\    <div class="modal-header"><h3 id="user-modal-title">添加用户</h3><span class="close" onclick="hideUserModal()">&times;</span></div>
        \\    <form id="user-form" onsubmit="saveUser(event)">
        \\      <input type="hidden" id="user-id">
        \\      <div class="form-group"><label>用户名</label><input id="user-username" required></div>
        \\      <div class="form-group"><label>邮箱</label><input id="user-email" type="email" required></div>
        \\      <div class="form-group"><label>密码</label><input id="user-password" type="password" minlength="6"><small style="color:#666">创建时必填，更新可留空</small></div>
        \\      <div class="form-group"><label>姓名</label><input id="user-name"></div>
        \\      <div class="form-group"><label>角色</label><select id="user-role"><option value="user">普通用户</option><option value="admin">管理员</option><option value="moderator">版主</option></select></div>
        \\      <div class="form-group"><label><input type="checkbox" id="user-active" checked> 激活</label></div>
        \\      <button type="submit" class="btn btn-primary">保存</button>
        \\    </form>
        \\  </div></div>
        \\
        \\  <!-- 商品模态框 -->
        \\  <div class="modal" id="product-modal"><div class="modal-content">
        \\    <div class="modal-header"><h3 id="product-modal-title">添加商品</h3><span class="close" onclick="hideProductModal()">&times;</span></div>
        \\    <form id="product-form" onsubmit="saveProduct(event)">
        \\      <input type="hidden" id="product-id">
        \\      <div class="form-group"><label>名称</label><input id="product-name" required></div>
        \\      <div class="form-group"><label>分类</label><input id="product-category"></div>
        \\      <div class="form-group"><label>价格</label><input id="product-price" type="number" step="0.01" min="0" required></div>
        \\      <div class="form-group"><label>库存</label><input id="product-stock" type="number" min="0" required></div>
        \\      <div class="form-group"><label>描述</label><textarea id="product-description" rows="3"></textarea></div>
        \\      <button type="submit" class="btn btn-primary">保存</button>
        \\    </form>
        \\  </div></div>
        \\
        \\  <script>
        \\    // ---------- 导航 ----------
        \\    function switchPanel(name) {
        \\      document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        \\      document.getElementById('panel-' + name).classList.add('active');
        \\      document.querySelectorAll('.sidebar a').forEach(a => a.classList.remove('active'));
        \\      const nav = document.getElementById('nav-' + name);
        \\      if (nav) nav.classList.add('active');
        \\      if (name === 'users') loadUsers(); else if (name === 'products') loadProducts();
        \\    }
        \\    function escapeHtml(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
        \\    function fmtMoney(v){ return '¥' + Number(v).toFixed(2); }
        \\
        \\    // ---------- 仪表盘 ----------
        \\    async function loadDashboard() {
        \\      switchPanel('dashboard');
        \\      try {
        \\        const res = await fetch('/api/dashboard');
        \\        const d = await res.json();
        \\        document.getElementById('dashboard-stats').innerHTML =
        \\          statCard(d.users, '用户总数') + statCard(d.products, '商品总数') +
        \\          statCard(d.active_users, '活跃用户') + statCard(d.low_stock, '库存预警');
        \\      } catch(e){ console.error(e); }
        \\    }
        \\    function statCard(v, label){ return '<div class="stat-card"><div class="stat-value">'+v+'</div><div class="stat-label">'+label+'</div></div>'; }
        \\
        \\    // ---------- 用户管理 ----------
        \\    let userPage = 1; const pageSize = 10; let userSearch = '';
        \\    async function loadUsers() {
        \\      let url = '/api/users?page=' + userPage + '&size=' + pageSize;
        \\      if (userSearch) url += '&search=' + encodeURIComponent(userSearch);
        \\      try {
        \\        const res = await fetch(url); const d = await res.json();
        \\        const tb = document.getElementById('users-tbody');
        \\        if (d.users.length === 0) { tb.innerHTML = '<tr><td colspan="6" style="text-align:center;">暂无数据</td></tr>'; }
        \\        else tb.innerHTML = d.users.map(u =>
        \\          '<tr><td>'+u.id+'</td><td>'+escapeHtml(u.username)+'</td><td>'+escapeHtml(u.email)+'</td>'+
        \\          '<td>'+(u.role||'user')+'</td>'+
        \\          '<td><span class="badge '+(u.is_active?'badge-active':'badge-inactive')+'">'+(u.is_active?'活跃':'禁用')+'</span></td>'+
        \\          '<td><button class="btn btn-edit btn-sm" onclick="editUser('+u.id+')">编辑</button> '+
        \\          '<button class="btn btn-danger btn-sm" onclick="deleteUser('+u.id+')">删除</button></td></tr>'
        \\        ).join('');
        \\        renderPagination('users-pagination', d.total_pages, userPage, p => { userPage = p; loadUsers(); });
        \\      } catch(e){ console.error(e); }
        \\    }
        \\    function searchUsers(){ userSearch = document.getElementById('user-search').value; userPage = 1; loadUsers(); }
        \\    function showUserModal(){ document.getElementById('user-modal-title').textContent='添加用户';
        \\      document.getElementById('user-form').reset(); document.getElementById('user-id').value='';
        \\      document.getElementById('user-password').required=true; document.getElementById('user-modal').classList.add('show'); }
        \\    function hideUserModal(){ document.getElementById('user-modal').classList.remove('show'); }
        \\    async function editUser(id){ try { const u = await (await fetch('/api/users/'+id)).json();
        \\      document.getElementById('user-modal-title').textContent='编辑用户';
        \\      document.getElementById('user-id').value=u.id; document.getElementById('user-username').value=u.username;
        \\      document.getElementById('user-email').value=u.email; document.getElementById('user-password').value='';
        \\      document.getElementById('user-password').required=false; document.getElementById('user-name').value=u.full_name||'';
        \\      document.getElementById('user-role').value=u.role||'user'; document.getElementById('user-active').checked=u.is_active;
        \\      document.getElementById('user-modal').classList.add('show');
        \\    } catch(e){ alert('加载失败: '+e.message); } }
        \\    async function saveUser(e){ e.preventDefault();
        \\      const id = document.getElementById('user-id').value;
        \\      const payload = { username:val('user-username'), email:val('user-email'), password:val('user-password'),
        \\        full_name:val('user-name'), role:val('user-role'), is_active:document.getElementById('user-active').checked };
        \\      try { const res = id ? await api('PUT','/api/users/'+id,payload) : await api('POST','/api/users',payload);
        \\        if (res.ok){ hideUserModal(); loadUsers(); } else alert('错误: '+(await res.json()).error); }
        \\      catch(e){ alert('网络错误: '+e.message); } }
        \\    async function deleteUser(id){ if(!confirm('确定删除该用户？')) return;
        \\      try { const res = await api('DELETE','/api/users/'+id); if(res.ok) loadUsers(); else alert('错误: '+(await res.json()).error); }
        \\      catch(e){ alert('网络错误: '+e.message); } }
        \\
        \\    // ---------- 数据管理（商品） ----------
        \\    let productPage = 1; let productSearch = '';
        \\    async function loadProducts() {
        \\      let url = '/api/products?page=' + productPage + '&size=' + pageSize;
        \\      if (productSearch) url += '&search=' + encodeURIComponent(productSearch);
        \\      try {
        \\        const res = await fetch(url); const d = await res.json();
        \\        const tb = document.getElementById('products-tbody');
        \\        if (d.products.length === 0) { tb.innerHTML = '<tr><td colspan="6" style="text-align:center;">暂无数据</td></tr>'; }
        \\        else tb.innerHTML = d.products.map(p =>
        \\          '<tr><td>'+p.id+'</td><td>'+escapeHtml(p.name)+'</td><td>'+escapeHtml(p.category)+'</td>'+
        \\          '<td>'+fmtMoney(p.price)+'</td><td>'+p.stock+'</td>'+
        \\          '<td><button class="btn btn-edit btn-sm" onclick="editProduct('+p.id+')">编辑</button> '+
        \\          '<button class="btn btn-danger btn-sm" onclick="deleteProduct('+p.id+')">删除</button></td></tr>'
        \\        ).join('');
        \\        renderPagination('products-pagination', d.total_pages, productPage, p => { productPage = p; loadProducts(); });
        \\      } catch(e){ console.error(e); }
        \\    }
        \\    function searchProducts(){ productSearch = document.getElementById('product-search').value; productPage = 1; loadProducts(); }
        \\    function showProductModal(){ document.getElementById('product-modal-title').textContent='添加商品';
        \\      document.getElementById('product-form').reset(); document.getElementById('product-id').value='';
        \\      document.getElementById('product-modal').classList.add('show'); }
        \\    function hideProductModal(){ document.getElementById('product-modal').classList.remove('show'); }
        \\    async function editProduct(id){ try { const p = await (await fetch('/api/products/'+id)).json();
        \\      document.getElementById('product-modal-title').textContent='编辑商品';
        \\      document.getElementById('product-id').value=p.id; document.getElementById('product-name').value=p.name;
        \\      document.getElementById('product-category').value=p.category||''; document.getElementById('product-price').value=p.price;
        \\      document.getElementById('product-stock').value=p.stock; document.getElementById('product-description').value=p.description||'';
        \\      document.getElementById('product-modal').classList.add('show');
        \\    } catch(e){ alert('加载失败: '+e.message); } }
        \\    async function saveProduct(e){ e.preventDefault();
        \\      const id = document.getElementById('product-id').value;
        \\      const payload = { name:val('product-name'), category:val('product-category'),
        \\        price:parseFloat(val('product-price')), stock:parseInt(val('product-stock'),10), description:val('product-description') };
        \\      try { const res = id ? await api('PUT','/api/products/'+id,payload) : await api('POST','/api/products',payload);
        \\        if (res.ok){ hideProductModal(); loadProducts(); } else alert('错误: '+(await res.json()).error); }
        \\      catch(e){ alert('网络错误: '+e.message); } }
        \\    async function deleteProduct(id){ if(!confirm('确定删除该商品？')) return;
        \\      try { const res = await api('DELETE','/api/products/'+id); if(res.ok) loadProducts(); else alert('错误: '+(await res.json()).error); }
        \\      catch(e){ alert('网络错误: '+e.message); } }
        \\
        \\    // ---------- 通用工具 ----------
        \\    function val(id){ return document.getElementById(id).value; }
        \\    async function api(method, url, body){ return fetch(url, { method, headers:{'Content-Type':'application/json'},
        \\      body: body ? JSON.stringify(body) : undefined }); }
        \\    function renderPagination(elId, totalPages, cur, go){
        \\      let html=''; for(let i=1;i<=totalPages;i++) html+='<button onclick="('+'('+go.toString()+')'+')('+i+')" class="'+(i===cur?'btn-primary':'')+'" style="margin:0 2px;padding:5px 10px;border:1px solid #ddd;background:'+(i===cur?'#667eea':'white')+';color:'+(i===cur?'white':'#333')+';border-radius:4px;cursor:pointer;">'+i+'</button>';
        \\      document.getElementById(elId).innerHTML = html;
        \\    }
        \\    loadUsers();
        \\  </script>
        \\</body>
        \\</html>
    ;
}

// =========================================================================
// 用户管理：API 处理器
// =========================================================================

const ListUsersHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*ListUsersHandler {
        const p = try a.create(ListUsersHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *ListUsersHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const page = std.fmt.parseInt(u32, ctx.getQuery("page") orelse "1", 10) catch 1;
        const size = std.fmt.parseInt(u32, ctx.getQuery("size") orelse "10", 10) catch 10;
        const search = ctx.getQuery("search") orelse "";

        var qb = orm.Query(User).init(self.allocator);
        defer qb.deinit();
        if (search.len > 0) _ = qb.where(.Like, "username", .{ .string = search });
        _ = qb.orderBy("id", .Desc);

        var count_qb = orm.Query(User).init(self.allocator);
        defer count_qb.deinit();
        const total = try user_store.count(&count_qb);

        const offset = (page - 1) * size;
        _ = qb.limit(@intCast(size)).offset(@intCast(offset));

        const all = try user_store.findAll(&qb);
        defer self.allocator.free(all);

        const list = try self.allocator.alloc(UserResponse, all.len);
        for (all, 0..) |u, i| list[i] = userResponse(u);

        const total_pages = if (total == 0) @as(u32, 0) else @as(u32, @intCast((total + size - 1) / size));
        try res.json(.{ .users = list, .total = total, .page = page, .size = size, .total_pages = total_pages });
        self.allocator.free(list);
    }
    pub fn deinit(self: *ListUsersHandler) void {
        _ = self;
    }
};

const GetUserHandler = struct {
    pub fn init(a: std.mem.Allocator) !*GetUserHandler {
        const p = try a.create(GetUserHandler);
        p.* = .{};
        return p;
    }
    pub fn handle(_: *GetUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        if (try user_store.findById(id)) |u| {
            try res.json(userResponse(u));
        } else try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
    }
    pub fn deinit(_: *GetUserHandler) void {}
};

const CreateUserHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*CreateUserHandler {
        const p = try a.create(CreateUserHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *CreateUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const parsed = try std.json.parseFromSlice(CreateUserInput, self.allocator, try ctx.readBody(), .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const in = parsed.value;

        if (in.username.len == 0 or in.email.len == 0 or in.password.len == 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "用户名、邮箱、密码不能为空" });
            return;
        }
        if (in.password.len < 6) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "密码至少 6 个字符" });
            return;
        }

        // 唯一性检查
        var qn = orm.Query(User).init(self.allocator);
        defer qn.deinit();
        _ = qn.where(.Eq, "username", .{ .string = in.username });
        if (try user_store.findOne(&qn)) |_| {
            try res.statusCode(.conflict).json(.{ .@"error" = "用户名已存在" });
            return;
        }
        var qe = orm.Query(User).init(self.allocator);
        defer qe.deinit();
        _ = qe.where(.Eq, "email", .{ .string = in.email });
        if (try user_store.findOne(&qe)) |_| {
            try res.statusCode(.conflict).json(.{ .@"error" = "邮箱已注册" });
            return;
        }

        const hashed = try hashPassword(self.allocator, in.password);
        defer self.allocator.free(hashed);
        const ts = nowTs();
        const id = try user_store.insert(.{
            .id = 0,
            .username = try self.allocator.dupe(u8, in.username),
            .email = try self.allocator.dupe(u8, in.email),
            .password_hash = hashed,
            .full_name = try self.allocator.dupe(u8, in.full_name orelse ""),
            .role = try self.allocator.dupe(u8, in.role orelse "user"),
            .is_active = in.is_active orelse true,
            .created_at = ts,
            .updated_at = ts,
        });
        _ = try user_store.flush();
        if (try user_store.findById(id)) |u| {
            try res.statusCode(.created).json(userResponse(u));
        } else try res.statusCode(.created).json(.{ .id = id, .message = "用户创建成功" });
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

const UpdateUserHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*UpdateUserHandler {
        const p = try a.create(UpdateUserHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *UpdateUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        const existing = try user_store.findById(id);
        if (existing == null) {
            try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
            return;
        }

        const parsed = try std.json.parseFromSlice(UpdateUserInput, self.allocator, try ctx.readBody(), .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const in = parsed.value;

        var updated: User = existing.?;
        updated.updated_at = nowTs();
        if (in.username) |v| updated.username = try self.allocator.dupe(u8, v);
        if (in.email) |v| updated.email = try self.allocator.dupe(u8, v);
        if (in.full_name) |v| updated.full_name = try self.allocator.dupe(u8, v);
        if (in.role) |v| updated.role = try self.allocator.dupe(u8, v);
        if (in.is_active) |v| updated.is_active = v;

        // 收集需要更新的字段
        var fields_buf: [7][]const u8 = undefined;
        var field_count: usize = 0;
        fields_buf[field_count] = "username";
        field_count += 1;
        fields_buf[field_count] = "email";
        field_count += 1;
        fields_buf[field_count] = "full_name";
        field_count += 1;
        fields_buf[field_count] = "role";
        field_count += 1;
        fields_buf[field_count] = "is_active";
        field_count += 1;
        fields_buf[field_count] = "updated_at";
        field_count += 1;
        if (in.password) |pw| {
            if (pw.len > 0) {
                if (pw.len < 6) {
                    try res.statusCode(.bad_request).json(.{ .@"error" = "密码至少 6 个字符" });
                    return;
                }
                const hashed = try hashPassword(self.allocator, pw);
                defer self.allocator.free(hashed);
                updated.password_hash = hashed;
                fields_buf[field_count] = "password_hash";
                field_count += 1;
            }
        }
        const fields = fields_buf[0..field_count];

        var qb = orm.Query(User).init(self.allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
        _ = qb.update(updated, fields);
        _ = try user_store.update(&qb);
        _ = try user_store.flush();
        if (try user_store.findById(id)) |u| {
            try res.json(userResponse(u));
        } else try res.json(.{ .message = "更新成功" });
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

const DeleteUserHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*DeleteUserHandler {
        const p = try a.create(DeleteUserHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *DeleteUserHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        if (id == 1) {
            try res.statusCode(.forbidden).json(.{ .@"error" = "不允许删除默认管理员" });
            return;
        }
        if (try user_store.findById(id)) |_| {
            var qb = orm.Query(User).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
            _ = try user_store.delete(&qb);
            _ = try user_store.flush();
            try res.json(.{ .message = "用户已删除" });
        } else try res.statusCode(.not_found).json(.{ .@"error" = "用户不存在" });
    }
    pub fn deinit(self: *DeleteUserHandler) void {
        _ = self;
    }
};

// =========================================================================
// 数据管理（商品）：API 处理器
// =========================================================================

const ListProductsHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*ListProductsHandler {
        const p = try a.create(ListProductsHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *ListProductsHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const page = std.fmt.parseInt(u32, ctx.getQuery("page") orelse "1", 10) catch 1;
        const size = std.fmt.parseInt(u32, ctx.getQuery("size") orelse "10", 10) catch 10;
        const search = ctx.getQuery("search") orelse "";

        var qb = orm.Query(Product).init(self.allocator);
        defer qb.deinit();
        if (search.len > 0) _ = qb.where(.Like, "name", .{ .string = search });
        _ = qb.orderBy("id", .Desc);

        var cq = orm.Query(Product).init(self.allocator);
        defer cq.deinit();
        const total = try product_store.count(&cq);
        const offset = (page - 1) * size;
        _ = qb.limit(@intCast(size)).offset(@intCast(offset));

        const all = try product_store.findAll(&qb);
        defer self.allocator.free(all);
        const list = try self.allocator.alloc(ProductResponse, all.len);
        for (all, 0..) |p, i| list[i] = productResponse(p);
        const total_pages = if (total == 0) @as(u32, 0) else @as(u32, @intCast((total + size - 1) / size));
        try res.json(.{ .products = list, .total = total, .page = page, .size = size, .total_pages = total_pages });
        self.allocator.free(list);
    }
    pub fn deinit(self: *ListProductsHandler) void {
        _ = self;
    }
};

const GetProductHandler = struct {
    pub fn init(a: std.mem.Allocator) !*GetProductHandler {
        const p = try a.create(GetProductHandler);
        p.* = .{};
        return p;
    }
    pub fn handle(_: *GetProductHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        if (try product_store.findById(id)) |p| {
            try res.json(productResponse(p));
        } else try res.statusCode(.not_found).json(.{ .@"error" = "商品不存在" });
    }
    pub fn deinit(_: *GetProductHandler) void {}
};

const CreateProductHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*CreateProductHandler {
        const p = try a.create(CreateProductHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *CreateProductHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const parsed = try std.json.parseFromSlice(CreateProductInput, self.allocator, try ctx.readBody(), .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const in = parsed.value;

        if (in.name.len == 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "名称不能为空" });
            return;
        }
        if (in.price < 0) {
            try res.statusCode(.bad_request).json(.{ .@"error" = "价格不能为负" });
            return;
        }

        const ts = nowTs();
        const id = try product_store.insert(.{
            .id = 0,
            .name = try self.allocator.dupe(u8, in.name),
            .category = try self.allocator.dupe(u8, in.category orelse "未分类"),
            .price = in.price,
            .stock = in.stock orelse 0,
            .description = try self.allocator.dupe(u8, in.description orelse ""),
            .created_at = ts,
            .updated_at = ts,
        });
        _ = try product_store.flush();
        if (try product_store.findById(id)) |p| {
            try res.statusCode(.created).json(productResponse(p));
        } else try res.statusCode(.created).json(.{ .id = id, .message = "商品创建成功" });
    }
    pub fn deinit(self: *CreateProductHandler) void {
        _ = self;
    }

    const CreateProductInput = struct {
        name: []const u8 = "",
        category: ?[]const u8 = null,
        price: f64 = 0,
        stock: ?u32 = null,
        description: ?[]const u8 = null,
    };
};

const UpdateProductHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*UpdateProductHandler {
        const p = try a.create(UpdateProductHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *UpdateProductHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        const existing = try product_store.findById(id);
        if (existing == null) {
            try res.statusCode(.not_found).json(.{ .@"error" = "商品不存在" });
            return;
        }

        const parsed = try std.json.parseFromSlice(UpdateProductInput, self.allocator, try ctx.readBody(), .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const in = parsed.value;

        var updated: Product = existing.?;
        updated.updated_at = nowTs();
        if (in.name) |v| updated.name = try self.allocator.dupe(u8, v);
        if (in.category) |v| updated.category = try self.allocator.dupe(u8, v);
        if (in.description) |v| updated.description = try self.allocator.dupe(u8, v);
        if (in.price) |v| updated.price = v;
        if (in.stock) |v| updated.stock = v;

        var qb = orm.Query(Product).init(self.allocator);
        defer qb.deinit();
        _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
        _ = qb.update(updated, &.{ "name", "category", "price", "stock", "description", "updated_at" });
        _ = try product_store.update(&qb);
        _ = try product_store.flush();
        if (try product_store.findById(id)) |p| {
            try res.json(productResponse(p));
        } else try res.json(.{ .message = "更新成功" });
    }
    pub fn deinit(self: *UpdateProductHandler) void {
        _ = self;
    }

    const UpdateProductInput = struct {
        name: ?[]const u8 = null,
        category: ?[]const u8 = null,
        price: ?f64 = null,
        stock: ?u32 = null,
        description: ?[]const u8 = null,
    };
};

const DeleteProductHandler = struct {
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator) !*DeleteProductHandler {
        const p = try a.create(DeleteProductHandler);
        p.* = .{ .allocator = a };
        return p;
    }
    pub fn handle(self: *DeleteProductHandler, ctx: *http_framework.RequestContext, res: *http_framework.Response) !void {
        const id = std.fmt.parseInt(u64, ctx.getParam("id") orelse return error.BadRequest, 10) catch return error.BadRequest;
        if (try product_store.findById(id)) |_| {
            var qb = orm.Query(Product).init(self.allocator);
            defer qb.deinit();
            _ = qb.where(.Eq, "id", .{ .integer = @intCast(id) });
            _ = try product_store.delete(&qb);
            _ = try product_store.flush();
            try res.json(.{ .message = "商品已删除" });
        } else try res.statusCode(.not_found).json(.{ .@"error" = "商品不存在" });
    }
    pub fn deinit(self: *DeleteProductHandler) void {
        _ = self;
    }
};

// =========================================================================
// 仪表盘统计 GET /api/dashboard
// =========================================================================

fn dashboardHandler(_: *http_framework.RequestContext, res: *http_framework.Response) !void {
    var uq = orm.Query(User).init(std.heap.page_allocator);
    defer uq.deinit();
    const user_total = try user_store.count(&uq);
    const users = user_store.all() catch {
        try res.statusCode(.internal_server_error).json(.{ .@"error" = "统计失败" });
        return;
    };
    var active_users: u32 = 0;
    for (users) |u| {
        if (u.is_active) active_users += 1;
    }

    var pq = orm.Query(Product).init(std.heap.page_allocator);
    defer pq.deinit();
    const product_total = try product_store.count(&pq);
    const products = product_store.all() catch {
        try res.statusCode(.internal_server_error).json(.{ .@"error" = "统计失败" });
        return;
    };
    var low_stock: u32 = 0;
    for (products) |p| {
        if (p.stock <= 10) low_stock += 1;
    }

    try res.json(.{
        .users = user_total,
        .active_users = active_users,
        .products = product_total,
        .low_stock = low_stock,
    });
}

// =========================================================================
// 响应 DTO（剔除密码 hash）
// =========================================================================

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

const ProductResponse = struct {
    id: u64,
    name: []const u8,
    category: []const u8,
    price: f64,
    stock: u32,
    description: []const u8,
    created_at: i64,
    updated_at: i64,
};

fn userResponse(u: User) UserResponse {
    return .{ .id = u.id, .username = u.username, .email = u.email, .full_name = u.full_name, .role = u.role, .is_active = u.is_active, .created_at = u.created_at, .updated_at = u.updated_at };
}

fn productResponse(p: Product) ProductResponse {
    return .{ .id = p.id, .name = p.name, .category = p.category, .price = p.price, .stock = p.stock, .description = p.description, .created_at = p.created_at, .updated_at = p.updated_at };
}
