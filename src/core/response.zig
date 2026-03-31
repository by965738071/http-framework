/// 响应构建器
const std = @import("std");
const http = std.http;

allocator: std.mem.Allocator,
request: *http.Server.Request,
status: http.Status,
headers: std.ArrayList(http.Header),
cookies: std.ArrayList(Cookie),

const Self = @This();

const Cookie = struct {
    name: []const u8,
    value: []const u8,
    max_age: ?i64 = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, request: *http.Server.Request) Self {
    return .{
        .allocator = allocator,
        .request = request,
        .status = .ok,
        .headers = std.ArrayList(http.Header).empty,
        .cookies = std.ArrayList(Cookie).empty,
    };
}

pub fn deinit(self: *Self) void {
    self.headers.deinit(self.allocator);
    self.cookies.deinit(self.allocator);
}

/// 设置状态码
pub fn statusCode(self: *Self, code: http.Status) *Self {
    self.status = code;
    return self;
}

/// 添加 Header
pub fn header(self: *Self, name: []const u8, value: []const u8) !*Self {
    try self.headers.append(self.allocator, .{ .name = name, .value = value });
    return self;
}

/// 设置 Cookie
pub fn setCookie(self: *Self, name: []const u8, value: []const u8) !*Self {
    try self.cookies.append(self.allocator, .{
        .name = name,
        .value = value,
    });
    return self;
}

/// 构建 Set-Cookie header
fn buildCookieHeader(self: *Self, cookie: Cookie) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(self.allocator);

    try buf.print(self.allocator, "{s}={s}", .{ cookie.name, cookie.value });

    if (cookie.max_age) |age| {
        try buf.print(self.allocator, "; Max-Age={d}", .{age});
    }
    if (cookie.path) |p| {
        try buf.print(self.allocator, "; Path={s}", .{p});
    }
    if (cookie.domain) |d| {
        try buf.print(self.allocator, "; Domain={s}", .{d});
    }
    if (cookie.secure) {
        try buf.print(self.allocator, "; Secure", .{});
    }
    if (cookie.http_only) {
        try buf.print(self.allocator,"; HttpOnly",.{});
    }
    if (cookie.same_site) |ss| {
        try buf.print(self.allocator, "; SameSite={s}", .{ss});
    }

    return buf.toOwnedSlice(self.allocator);
}

/// 发送文本
pub fn text(self: *Self, content: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator,.{
        .name = "Content-Type",
        .value = "text/plain; charset=utf-8",
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 发送 HTML
pub fn html(self: *Self, content: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator,.{
        .name = "Content-Type",
        .value = "text/html; charset=utf-8",
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 发送 JSON
pub fn json(self: *Self, value: anytype) !void {
    const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    defer self.allocator.free(json_str);

    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator,.{
        .name = "Content-Type",
        .value = "application/json",
    });

    try self.request.respond(json_str, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 发送文件
pub fn file(self: *Self, content: []const u8, content_type: []const u8) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator,.{
        .name = "Content-Type",
        .value = content_type,
    });

    try self.request.respond(content, .{
        .status = self.status,
        .extra_headers = self.headers.items,
    });
}

/// 重定向
pub fn redirect(self: *Self, location: []const u8, permanent: bool) !void {
    try self.addCookiesToHeaders();
    try self.headers.append(self.allocator,.{
        .name = "Location",
        .value = location,
    });

    const status = if (permanent) http.Status.moved_permanently else http.Status.found;

    try self.request.respond("", .{
        .status = status,
        .extra_headers = self.headers.items,
    });
}

/// 添加 cookies 到 headers
fn addCookiesToHeaders(self: *Self) !void {
    for (self.cookies.items) |cookie| {
        const cookie_str = try self.buildCookieHeader(cookie);
        defer self.allocator.free(cookie_str);
        try self.headers.append(self.allocator,.{
            .name = "Set-Cookie",
            .value = cookie_str,
        });
    }
}
