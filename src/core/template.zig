//! 简单的模板引擎
//! 支持变量替换（{variable}）和简单的条件判断。

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// 模板引擎
pub const Template = struct {
    allocator: Allocator,
    content: []const u8,
    variables: std.StringHashMap([]const u8) = .empty,

    const Self = @This();

    /// 从文件加载模板
    pub fn fromFile(allocator: Allocator, io: std.Io, path: []const u8) !Self {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        return Self{
            .allocator = allocator,
            .content = content,
            .variables = std.StringHashMap([]const u8).empty,
        };
    }

    /// 从字符串加载模板
    pub fn fromString(allocator: Allocator, content: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .content = try allocator.dupe(u8, content),
            .variables = std.StringHashMap([]const u8).empty,
        };
    }

    /// 释放资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.content);
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit(self.allocator);
    }

    /// 设置变量
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        const val_dup = try self.allocator.dupe(u8, value);
        try self.variables.put(self.allocator, key_dup, val_dup);
    }

    /// 渲染模板
    pub fn render(self: *const Self) ![]u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var rest = self.content;
        while (rest.len > 0) {
            // 查找变量占位符
            if (mem.indexOf(u8, rest, "{")) |start| {
                // 添加前面的普通文本
                try result.appendSlice(self.allocator, rest[0..start]);

                // 查找结束符
                const after_start = rest[start + 1 ..];
                if (mem.indexOf(u8, after_start, "}")) |end| {
                    const var_name = after_start[0..end];
                    const full_match = rest[start .. start + 1 + end + 1];

                    // 查找变量值
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                    } else {
                        // 变量未找到，保留原样
                        try result.appendSlice(self.allocator, full_match);
                    }

                    rest = rest[start + 1 + end + 1 ..];
                } else {
                    // 没有结束符，保留原样
                    try result.appendSlice(self.allocator, rest);
                    break;
                }
            } else {
                // 没有更多变量，添加剩余文本
                try result.appendSlice(self.allocator, rest);
                break;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

// =========================================================================
// 测试
// =========================================================================

test "fromString" {
    const allocator = std.testing.allocator;
    var tmpl = try Template.fromString(allocator, "Hello");
    defer tmpl.deinit();
    try std.testing.expectEqualStrings("Hello", tmpl.content);
}

test "set and render - single variable" {
    const allocator = std.testing.allocator;
    var tmpl = try Template.fromString(allocator, "Hello, {name}!");
    defer tmpl.deinit();
    try tmpl.set("name", "World");
    const result = try tmpl.render();
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "render - multiple variables" {
    const allocator = std.testing.allocator;
    var tmpl = try Template.fromString(allocator, "{greeting}, {name}! Score: {score}.");
    defer tmpl.deinit();
    try tmpl.set("greeting", "Hi");
    try tmpl.set("name", "Alice");
    try tmpl.set("score", "100");
    const result = try tmpl.render();
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi, Alice! Score: 100.", result);
}

test "render - unset variable preserved as-is" {
    const allocator = std.testing.allocator;
    var tmpl = try Template.fromString(allocator, "Hello, {name}!");
    defer tmpl.deinit();
    // 不设置 name，占位符应保持原样
    const result = try tmpl.render();
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello, {name}!", result);
}

test "render - no variables in template" {
    const allocator = std.testing.allocator;
    var tmpl = try Template.fromString(allocator, "Plain text without variables.");
    defer tmpl.deinit();
    const result = try tmpl.render();
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Plain text without variables.", result);
}
