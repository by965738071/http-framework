const std = @import("std");
const http = std.http;
const mem = std.mem;

allocator: std.mem.Allocator,

// 基本信息
method: http.Method,
path: []const u8,
query: []const u8,
version: http.Version,

// 解析后的数据
query_params: std.StringHashMap([]const u8),
form_params: std.StringHashMap([]const u8),
headers: std.StringHashMap([]const u8),
cookies: std.StringHashMap([]const u8),

// 路径参数 /users/:id
path_params: std.StringHashMap([]const u8),

// 请求体相关
content_type: ?[]const u8,
content_length: ?u64,
transfer_encoding: http.TransferEncoding,

// 原始请求引用
request: *http.Server.Request,
body_read: bool,
body_data: ?[]const u8,

// 用户数据（用于中间件传递数据）
user_data: ?*anyopaque,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, request: *http.Server.Request) !Self {
    const head = request.head;

    // 解析 target
    const target = head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_start) |idx| target[0..idx] else target;
    const query = if (query_start) |idx| target[idx + 1 ..] else "";

    var ctx = Self{
        .allocator = allocator,
        .method = head.method,
        .path = path,
        .query = query,
        .version = head.version,
        .query_params = std.StringHashMap([]const u8).init(allocator),
        .form_params = std.StringHashMap([]const u8).init(allocator),
        .headers = std.StringHashMap([]const u8).init(allocator),
        .cookies = std.StringHashMap([]const u8).init(allocator),
        .path_params = std.StringHashMap([]const u8).init(allocator),
        .content_type = head.content_type,
        .content_length = head.content_length,
        .transfer_encoding = head.transfer_encoding,
        .request = request,
        .body_read = false,
        .body_data = null,
        .user_data = null,
    };

    try ctx.parseQueryParams();
    try ctx.parseHeaders();
    try ctx.parseCookies();

    return ctx;
}

pub fn deinit(self: *Self) void {
    // 释放 query_params
    var qit = self.query_params.iterator();
    while (qit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.query_params.deinit();

    // 释放 form_params
    var fit = self.form_params.iterator();
    while (fit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.form_params.deinit();

    // 释放 headers
    var hit = self.headers.iterator();
    while (hit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.headers.deinit();

    // 释放 cookies
    var cit = self.cookies.iterator();
    while (cit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.cookies.deinit();

    // 释放 path_params
    var pit = self.path_params.iterator();
    while (pit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.path_params.deinit();

    // 释放 body 数据
    if (self.body_data) |data| {
        self.allocator.free(data);
    }
}

/// 解析 Query 参数
fn parseQueryParams(self: *Self) !void {
    if (self.query.len == 0) return;

    var pairs = std.mem.splitScalar(u8, self.query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            const key = try self.allocator.dupe(u8, pair[0..idx]);
            const value = try urlDecode(self.allocator, pair[idx + 1 ..]);
            try self.query_params.put(key, value);
        } else {
            const key = try self.allocator.dupe(u8, pair);
            try self.query_params.put(key, try self.allocator.dupe(u8, ""));
        }
    }
}

/// 解析 Headers
fn parseHeaders(self: *Self) !void {
    var it = self.request.iterateHeaders();
    while (it.next()) |header| {
        const key = try self.allocator.dupe(u8, header.name);
        const value = try self.allocator.dupe(u8, header.value);
        try self.headers.put(key, value);
    }
}

/// 解析 Cookies
fn parseCookies(self: *Self) !void {
    const cookie_header = self.getHeader("Cookie") orelse return;

    var pairs = std.mem.splitScalar(u8, cookie_header, ';');
    while (pairs.next()) |pair| {
        const trimmed = mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=');
        if (eq_idx) |idx| {
            const key = try self.allocator.dupe(u8, trimmed[0..idx]);
            const value = try self.allocator.dupe(u8, trimmed[idx + 1 ..]);
            try self.cookies.put(key, value);
        }
    }
}

/// 获取 Query 参数
pub fn getQuery(self: *const Self, key: []const u8) ?[]const u8 {
    return self.query_params.get(key);
}

/// 获取 Header（大小写不敏感）
pub fn getHeader(self: *const Self, key: []const u8) ?[]const u8 {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

/// 获取 Cookie
pub fn getCookie(self: *const Self, key: []const u8) ?[]const u8 {
    return self.cookies.get(key);
}

/// 获取路径参数
pub fn getParam(self: *const Self, key: []const u8) ?[]const u8 {
    return self.path_params.get(key);
}

/// 读取请求体（支持 content-length 和 chunked）
pub fn readBody(self: *Self) ![]const u8 {
    if (self.body_read) {
        if (self.body_data) |data| return data;
        return error.BodyAlreadyRead;
    }

    var buffer: [8192]u8 = undefined;
    const body_reader = self.request.readerExpectNone(&buffer);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(self.allocator);

    var temp_buf: [4096]u8 = undefined;
    while (true) {
        const n = try body_reader.readSliceShort(&temp_buf);
        if (n == 0) break;
        try result.appendSlice(self.allocator, temp_buf[0..n]);
    }

    self.body_read = true;
    self.body_data = try result.toOwnedSlice(self.allocator);

    // 如果是 form 数据，解析 form 参数
    if (self.content_type) |ct| {
        if (std.mem.indexOf(u8, ct, "application/x-www-form-urlencoded") != null) {
            try self.parseFormParams(self.body_data.?);
        }
    }

    return self.body_data.?;
}

/// 解析 Form 参数
fn parseFormParams(self: *Self, data: []const u8) !void {
    var pairs = std.mem.splitScalar(u8, data, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, pair, '=');
        if (eq_idx) |idx| {
            const key = try urlDecode(self.allocator, pair[0..idx]);
            const value = try urlDecode(self.allocator, pair[idx + 1 ..]);
            try self.form_params.put(key, value);
        } else {
            const key = try urlDecode(self.allocator, pair);
            try self.form_params.put(key, try self.allocator.dupe(u8, ""));
        }
    }
}

/// 获取 Form 参数
pub fn getForm(self: *const Self, key: []const u8) ?[]const u8 {
    return self.form_params.get(key);
}

/// 解析 JSON body
pub fn json(self: *Self, comptime T: type) !T {
    const body = try self.readBody();

    const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{});
    defer parsed.deinit();

    return parsed.value;
}

/// 设置用户数据
pub fn setUserData(self: *Self, data: *anyopaque) void {
    self.user_data = data;
}

/// 获取用户数据
pub fn getUserData(self: *const Self, comptime T: type) ?*T {
    if (self.user_data) |data| {
        return @ptrCast(@alignCast(data));
    }
    return null;
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const val = std.fmt.parseInt(u8, hex, 16) catch {
                try result.append(allocator, input[i]);
                continue;
            };
            try result.append(allocator, val);
            i += 2;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
        } else {
            try result.append(allocator, input[i]);
        }
    }

    return result.toOwnedSlice(allocator);
}

// // ==================== 示例处理器 ====================

// /// 首页处理器
// fn homeHandler(ctx: *RequestContext, res: *Response) !void {
// _ = ctx;
// try res.html(
//     \\<!DOCTYPE html>
//     \\<html>
//     \\<head><title>Zig HTTP Server</title></head>
//     \\<body>
//     \\  <h1>Welcome to Zig 0.16 HTTP Server!</h1>
//     \\  <p>Server is running on Zig 0.16-dev</p>
//     \\</body>
//     \\</html>
// );
// }

// /// API 处理器
// fn apiHandler(ctx: *RequestContext, res: *Response) !void {
// try res.json(.{
//     .version = "0.16-dev",
//     .method = @tagName(ctx.method),
//     .path = ctx.path,
//     .query_params = ctx.query_params.count(),
// });
// }

// /// 用户处理器（带路径参数）
// fn userHandler(ctx: *RequestContext, res: *Response) !void {
// const user_id = ctx.getParam("id") orelse "unknown";

// try res.json(.{
//     .user_id = user_id,
//     .name = "John Doe",
//     .email = "john@example.com",
// });
// }

// /// POST 数据处理
// fn createUserHandler(ctx: *RequestContext, res: *Response) !void {
// const body = try ctx.readBody();

// try res.statusCode(.created).json(.{
//     .success = true,
//     .body_length = body.len,
//     .content_type = ctx.content_type,
// });
// }

// /// WebSocket 处理器
// fn wsHandler(ctx: *RequestContext, res: *Response) !void {
// _ = res;

// const ws = try WebSocketHandler.handle(ctx, ctx.request);

// // 简单的 echo 服务器
// var buffer: [1024]u8 = undefined;
// while (true) {
//     const msg = ws.readSmallMessage() catch |err| {
//         if (err == error.ConnectionClose) break;
//         return err;
//     };

//     // Echo 回消息
//     try ws.writeMessage(msg.data, msg.opcode);
// }
// }

// /// 完整服务器示例
// pub fn main() !void {
// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// defer _ = gpa.deinit();
// const allocator = gpa.allocator();

// // 创建路由
// var router = Router.init(allocator);
// defer router.deinit();

// // 注册路由
// try router.route(.GET, "/", homeHandler);
// try router.route(.GET, "/api", apiHandler);
// try router.route(.GET, "/users/:id", userHandler);
// try router.route(.POST, "/users", createUserHandler);
// try router.route(.GET, "/ws", wsHandler);

// // 静态文件服务
// const static_server = StaticFileServer.init(allocator, "./public", "/static");
// try router.route(.GET, "/static/*", struct {
//     fn handler(ctx: *RequestContext, res: *Response) !void {
//         try static_server.handle(ctx, res);
//     }
// }.handler);

// // 设置 404 处理器
// router.notFound(struct {
//     fn handler(ctx: *RequestContext, res: *Response) !void {
//         _ = ctx;
//         try res.statusCode(.not_found).html(
//             \\<!DOCTYPE html>
//             \\<html><body><h1>404 - Page Not Found</h1></body></html>
//         );
//     }
// }.handler);

// // 启动服务器
// const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
// var tcp_server = try address.listen(.{ .reuse_address = true });
// defer tcp_server.deinit();

// std.log.info("Server listening on http://127.0.0.1:8080", .{});

// while (true) {
//     const conn = try tcp_server.accept();

//     _ = std.Thread.spawn(.{}, struct {
//         fn handler(c: std.net.Server.Connection, a: std.mem.Allocator, r: *Router) !void {
//             defer c.stream.close();

//             var reader = std.Io.Reader.init(c.stream);
//             var writer = std.Io.Writer.init(c.stream);
//             var http_server = http.Server.init(&reader, &writer);

//             while (true) {
//                 handleRequest(&http_server, a, r) catch |err| {
//                     if (err == error.HttpConnectionClosing or
//                         err == error.HttpRequestTruncated) break;
//                     std.log.err("Request error: {}", .{err});
//                     break;
//                 };
//             }
//         }
//     }.handler, .{ conn, allocator, &router }) catch |err| {
//         std.log.err("Failed to spawn thread: {}", .{err});
//         conn.stream.close();
//     };
// }
// }
