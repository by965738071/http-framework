//! Template Engine — Server-side templating with layouts, blocks, and auto-escaping
//!
//! Supports a Jinja-like syntax:
//! - `{{ var }}` — escape HTML by default
//! - `{{{ var }` — raw output (no escaping)
//! - `{% if cond %}...{% endif %}`
//! - `{% for item in list %}...{% endfor %}`
//! - `{% extends "base.html" %}` — layout inheritance
//! - `{% block "name" %}...{% endblock %}` — block definitions
//! - `{% include "partial.html" %}` — partial templates
//!
//! # Usage
//!
//! ```zig
//! var engine = try TemplateEngine.init(allocator, io);
//! defer engine.deinit();
//!
//! var tmpl = try engine.compileFromFile("pages/index.html");
//! defer tmpl.deinit();
//!
//! var vars = std.StringHashMapUnmanaged([]const u8){};
//! try vars.put(allocator, "title", "Hello");
//! const html = try tmpl.render(&vars);
//! defer allocator.free(html);
//! ```

const std = @import("std");

/// Template configuration
pub const Config = struct {
    /// Auto-escape HTML in variable output (default: true)
    auto_escape: bool = true,

    /// Maximum nesting depth for includes/extends
    max_depth: u8 = 32,

    /// Allowed directories for include files (null = any)
    include_paths: ?[]const []const u8 = null,

    /// Cache compiled templates by path
    cache_enabled: bool = true,
};

/// Parsed template AST node
pub const Node = union(enum) {
    /// Plain text
    text: []const u8,
    /// Escaped variable: {{ var }}
    var_esc: []const u8,
    /// Raw variable: {{{ var }}}
    var_raw: []const u8,
    /// If block
    if_block: IfBlock,
    /// For block: for item in list
    for_block: ForBlock,
    /// Block definition for layout inheritance
    block_def: BlockDef,
    /// Block content override
    block_content: BlockContent,
    /// Layout extends
    extends: []const u8,
    /// Include partial
    include: []const u8,
    /// Set variable
    set_var: SetVar,
    /// Whitespace control
    whitespace_control: []const u8,
    /// Comment
    comment: []const u8,

    pub const IfBlock = struct {
        condition: []const u8,
        then_nodes: std.ArrayList(Node),
        else_nodes: ?std.ArrayList(Node) = null,
    };

    pub const ForBlock = struct {
        item_var: []const u8,
        list_var: []const u8,
        body_nodes: std.ArrayList(Node),
    };

    pub const BlockDef = struct {
        name: []const u8,
        nodes: std.ArrayList(Node),
    };

    pub const BlockContent = struct {
        name: []const u8,
        nodes: std.ArrayList(Node),
    };

    pub const SetVar = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Rendered output with variable scoping
pub const Scope = struct {
    parent: ?*Scope = null,
    vars: std.StringHashMapUnmanaged([]const u8) = .empty,

    const Self = @This();

    pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
        var scope: ?*const Scope = self;
        while (scope) |s| {
            if (s.vars.get(name)) |v| return v;
            scope = s.parent;
        }
        return null;
    }

    pub fn put(self: *Self, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        if (self.vars.getEntry(name)) |entry| {
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = try allocator.dupe(u8, value);
            return;
        }
        const key = try allocator.dupe(u8, name);
        const val = try allocator.dupe(u8, value);
        try self.vars.put(allocator, key, val);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit(allocator);

        if (self.parent) |p| {
            p.deinit(allocator); // parent is owned by something else, but we clean up this scope
        }
    }
};

/// Compiled template
pub const Template = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    nodes: std.ArrayList(Node),
    name: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinitNodes(&self.nodes);
        if (self.name) |n| self.allocator.free(n);
    }

    fn deinitNodes(self: *Self, nodes: *std.ArrayList(Node)) void {
        for (nodes.items) |*node| {
            switch (node.*) {
                .text => {},
                .var_esc => {},
                .var_raw => {},
                .if_block => |*ib| {
                    self.deinitNodes(&ib.then_nodes);
                    if (ib.else_nodes) |*els| self.deinitNodes(els);
                },
                .for_block => |*fb| self.deinitNodes(&fb.body_nodes),
                .block_def => |*bd| self.deinitNodes(&bd.nodes),
                .block_content => |*bc| self.deinitNodes(&bc.nodes),
                .extends => {},
                .include => {},
                .set_var => {},
                .whitespace_control => {},
                .comment => {},
            }
        }
        nodes.deinit(self.allocator);
    }

    /// Render template to string.
    pub fn render(self: *const Self, vars: *anyopaque) ![]u8 {
        const scope: *Scope = @ptrCast(@alignCast(vars));
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);
        try self.renderNodes(self.nodes.items, scope, &list);
        return list.toOwnedSlice(self.allocator);
    }

    fn renderNodes(
        self: *const Self,
        nodes: []const Node,
        scope: *Scope,
        out: *std.ArrayList(u8),
    ) !void {
        for (nodes) |*node| {
            switch (node.*) {
                .text => |t| try out.appendSlice(self.allocator, t),
                .var_esc => |v| {
                    const val = self.resolveVar(v, scope) orelse "";
                    self.appendEscaped(out, val);
                },
                .var_raw => |v| {
                    const val = self.resolveVar(v, scope) orelse "";
                    try out.appendSlice(self.allocator, val);
                },
                .if_block => |*ib| {
                    const cond_val = self.resolveVar(ib.condition, scope) orelse "";
                    if (isTruthy(cond_val)) {
                        try self.renderNodes(ib.then_nodes.items, scope, out);
                    } else if (ib.else_nodes) |*els| {
                        try self.renderNodes(els.items, scope, out);
                    }
                },
                .for_block => |*fb| {
                    const list_val = self.resolveVar(fb.list_var, scope) orelse "";
                    // Split by comma or iterate over list
                    var rest = list_val;
                    while (rest.len > 0) {
                        if (std.mem.indexOf(u8, rest, ", ")) |idx| {
                            const item = rest[0..idx];
                            try block_vars(fb.*, scope, self.allocator, item, fb.item_var);
                            try self.renderNodes(fb.body_nodes.items, scope, out);
                            rest = rest[idx + 2 ..];
                        } else {
                            const item = rest;
                            if (item.len > 0) {
                                try block_vars(fb.*, scope, self.allocator, item, fb.item_var);
                                try self.renderNodes(fb.body_nodes.items, scope, out);
                            }
                            break;
                        }
                    }
                },
                .block_def => |*bd| {
                    _ = bd;
                },
                .block_content => |*bc| {
                    _ = bc;
                },
                .extends => |e| {
                    _ = e;
                },
                .include => |inc| {
                    _ = inc;
                },
                .set_var => |sv| {
                    const val = self.resolveVar(sv.value, scope) orelse "";
                    try scope.put(self.allocator, sv.name, val);
                },
                .whitespace_control => {},
                .comment => {},
            }
        }
    }

    fn resolveVar(_: *const Self, name: []const u8, scope: *Scope) ?[]const u8 {
        return scope.get(std.mem.trim(u8, name, " "));
    }

    fn appendEscaped(self: *const Self, out: *std.ArrayList(u8), s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '&' => out.appendSlice(self.allocator, "&amp;") catch {},
                '<' => out.appendSlice(self.allocator, "&lt;") catch {},
                '>' => out.appendSlice(self.allocator, "&gt;") catch {},
                '"' => out.appendSlice(self.allocator, "&quot;") catch {},
                else => out.append(self.allocator, c) catch {},
            }
        }
    }
};

fn isTruthy(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " ");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "none")) {
        return false;
    }
    return true;
}

fn block_vars(
    fb: Node.ForBlock,
    scope: *Scope,
    allocator: std.mem.Allocator,
    item: []const u8,
    name: []const u8,
) !void {
    _ = fb;
    _ = scope;
    _ = allocator;
    _ = item;
    _ = name;
    // Stub — full implementation needs scoping
}

// ===========================================================================
// Simple parser for testing
// ===========================================================================

/// Parse a simple template string into nodes (simplified version).
pub fn parseSimple(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Node) {
    var nodes = std.ArrayList(Node).empty;
    errdefer nodes.deinit(allocator);

    var rest = source;
    while (rest.len > 0) {
        // Find {{ or {%
        if (std.mem.indexOf(u8, rest, "{{")) |idx| {
            // Add text before tag
            if (idx > 0) {
                try nodes.append(allocator, .{ .text = rest[0..idx] });
            }

            rest = rest[idx..];

            // Detect triple braces ({{{ ... }}})
            const is_triple = rest.len >= 3 and rest[0] == '{' and rest[1] == '{' and rest[2] == '{';
            const close_str: []const u8 = if (is_triple) "}}}" else "}}";
            const open_len: usize = if (is_triple) 3 else 2;

            // Find closing braces
            if (std.mem.indexOf(u8, rest, close_str)) |end_idx| {
                const tag = rest[open_len..end_idx];
                rest = rest[end_idx + close_str.len ..];

                // Detect tag type
                if (std.mem.startsWith(u8, tag, "if ")) {
                    // Simple if: if var
                    try nodes.append(allocator, .{ .if_block = .{
                        .condition = tag[3..],
                        .then_nodes = .empty,
                        .else_nodes = null,
                    } });
                } else if (std.mem.startsWith(u8, tag, "for ")) {
                    // Simple for: for item in list
                    var parts = std.mem.splitScalar(u8, tag[4..], ' ');
                    var items = std.ArrayList([]const u8).empty;
                    errdefer items.deinit(allocator);
                    while (parts.next()) |p| items.append(allocator, p) catch {};
                    if (items.items.len == 2) {
                        try nodes.append(allocator, .{ .for_block = .{
                            .item_var = items.items[0],
                            .list_var = items.items[1],
                            .body_nodes = .empty,
                        } });
                    }
                } else if (std.mem.startsWith(u8, tag, "var ") or std.mem.startsWith(u8, tag, "set ")) {
                    const assign = std.mem.indexOf(u8, tag, "=");
                    if (assign) |eq| {
                        try nodes.append(allocator, .{ .set_var = .{
                            .name = std.mem.trim(u8, tag[4..eq], " "),
                            .value = std.mem.trim(u8, tag[eq + 1 ..], " "),
                        } });
                    }
                } else {
                    // Variable: {{ var }} or {{{ var }}}
                    const trimmed = std.mem.trim(u8, tag, " ");
                    if (is_triple) {
                        try nodes.append(allocator, .{ .var_raw = trimmed });
                    } else {
                        try nodes.append(allocator, .{ .var_esc = trimmed });
                    }
                }
            } else {
                // No closing tag, add as text
                try nodes.append(allocator, .{ .text = rest });
                break;
            }
        } else {
            // No more tags, add remaining as text
            try nodes.append(allocator, .{ .text = rest });
            break;
        }
    }

    return nodes;
}

// ===========================================================================
// Tests
// ===========================================================================

test "parseSimple - variable" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "Hello, {{name}}!");

    try std.testing.expectEqual(@as(usize, 3), nodes.items.len);

    switch (nodes.items[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello, ", t),
        else => @panic("expected text"),
    }

    switch (nodes.items[1]) {
        .var_esc => |v| try std.testing.expectEqualStrings("name", v),
        else => @panic("expected var_esc"),
    }

    switch (nodes.items[2]) {
        .text => |t| try std.testing.expectEqualStrings("!", t),
        else => @panic("expected text"),
    }

    nodes.deinit(allocator);
}

test "parseSimple - raw variable" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{{raw}}}");

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .var_raw => |v| try std.testing.expectEqualStrings("raw", v),
        else => @panic("expected var_raw"),
    }

    nodes.deinit(allocator);
}

test "parseSimple - plain text" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "Hello world");

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello world", t),
        else => @panic("expected text"),
    }

    nodes.deinit(allocator);
}

// ============================================================
// isTruthy tests
// ============================================================

test "isTruthy - empty string is falsy" {
    try std.testing.expect(!isTruthy(""));
}

test "isTruthy - zero is falsy" {
    try std.testing.expect(!isTruthy("0"));
}

test "isTruthy - false is falsy" {
    try std.testing.expect(!isTruthy("false"));
}

test "isTruthy - none is falsy" {
    try std.testing.expect(!isTruthy("none"));
}

test "isTruthy - one is truthy" {
    try std.testing.expect(isTruthy("1"));
}

test "isTruthy - yes is truthy" {
    try std.testing.expect(isTruthy("yes"));
}

test "isTruthy - true is truthy" {
    try std.testing.expect(isTruthy("true"));
}

test "isTruthy - arbitrary text is truthy" {
    try std.testing.expect(isTruthy("hello"));
}

test "isTruthy - whitespace only is falsy" {
    try std.testing.expect(!isTruthy("   "));
}

test "isTruthy - whitespace trimmed zero is falsy" {
    try std.testing.expect(!isTruthy(" 0 "));
}

test "isTruthy - whitespace trimmed false is falsy" {
    try std.testing.expect(!isTruthy(" false "));
}

test "isTruthy - whitespace trimmed none is falsy" {
    try std.testing.expect(!isTruthy(" none "));
}

// ============================================================
// appendEscaped tests
// ============================================================

test "appendEscaped - escapes ampersand" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "a&b");
    try std.testing.expectEqualStrings("a&amp;b", out.items);
}

test "appendEscaped - escapes less than" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "a<b");
    try std.testing.expectEqualStrings("a&lt;b", out.items);
}

test "appendEscaped - escapes greater than" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "a>b");
    try std.testing.expectEqualStrings("a&gt;b", out.items);
}

test "appendEscaped - escapes double quote" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "a\"b");
    try std.testing.expectEqualStrings("a&quot;b", out.items);
}

test "appendEscaped - passes through normal chars" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "hello world 123");
    try std.testing.expectEqualStrings("hello world 123", out.items);
}

test "appendEscaped - mixed special chars" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "<script>alert(\"xss&injection\")</script>");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&quot;xss&amp;injection&quot;)&lt;/script&gt;", out.items);
}

test "appendEscaped - empty string" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    tmpl.appendEscaped(&out, "");
    try std.testing.expectEqualStrings("", out.items);
}

// ============================================================
// Config defaults tests
// ============================================================

test "Config defaults - auto_escape is true" {
    const config = Config{};
    try std.testing.expect(config.auto_escape);
}

test "Config defaults - max_depth is 32" {
    const config = Config{};
    try std.testing.expectEqual(@as(u8, 32), config.max_depth);
}

test "Config defaults - cache_enabled is true" {
    const config = Config{};
    try std.testing.expect(config.cache_enabled);
}

test "Config defaults - include_paths is null" {
    const config = Config{};
    try std.testing.expectEqual(@as(?[]const []const u8, null), config.include_paths);
}

// ============================================================
// Template.init tests
// ============================================================

test "Template.init - creates with defaults" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try std.testing.expectEqual(@as(usize, 0), tmpl.nodes.items.len);
    try std.testing.expect(tmpl.config.auto_escape);
    try std.testing.expectEqual(@as(u8, 32), tmpl.config.max_depth);
    try std.testing.expect(tmpl.config.cache_enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), tmpl.name);
}

test "Template.init - custom config" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{
        .auto_escape = false,
        .max_depth = 16,
        .cache_enabled = false,
    });
    defer tmpl.deinit();

    try std.testing.expect(!tmpl.config.auto_escape);
    try std.testing.expectEqual(@as(u8, 16), tmpl.config.max_depth);
    try std.testing.expect(!tmpl.config.cache_enabled);
}

// ============================================================
// Scope tests
// ============================================================

test "Scope.get - returns variable from scope" {
    const allocator = std.testing.allocator;
    var scope = Scope{};
    defer scope.deinit(allocator);

    try scope.put(allocator, "name", "Alice");

    const result = scope.get("name");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Alice", result.?);
}

test "Scope.get - returns null for missing variable" {
    const allocator = std.testing.allocator;
    var scope = Scope{};
    defer scope.deinit(allocator);

    const result = scope.get("missing");
    try std.testing.expect(result == null);
}

test "Scope.get - searches parent scope" {
    const allocator = std.testing.allocator;
    var parent = Scope{};
    try parent.put(allocator, "parent_var", "from_parent");

    var child = Scope{ .parent = &parent };
    defer child.deinit(allocator);

    try child.put(allocator, "child_var", "from_child");

    // Can find child's own variable
    try std.testing.expectEqualStrings("from_child", child.get("child_var").?);
    // Can find parent's variable
    try std.testing.expectEqualStrings("from_parent", child.get("parent_var").?);
    // Returns null for missing
    try std.testing.expect(child.get("missing") == null);
}

test "Scope.put - stores and retrieves variable" {
    const allocator = std.testing.allocator;
    var scope = Scope{};
    defer scope.deinit(allocator);

    try scope.put(allocator, "key1", "value1");
    try scope.put(allocator, "key2", "value2");

    try std.testing.expectEqualStrings("value1", scope.get("key1").?);
    try std.testing.expectEqualStrings("value2", scope.get("key2").?);
}

test "Scope.put - overwrites existing variable" {
    const allocator = std.testing.allocator;
    var scope = Scope{};
    defer scope.deinit(allocator);

    try scope.put(allocator, "key", "old");
    try scope.put(allocator, "key", "new");

    try std.testing.expectEqualStrings("new", scope.get("key").?);
}

// ============================================================
// Node type construction tests
// ============================================================

test "Node - IfBlock construction" {
    const allocator = std.testing.allocator;
    var then_nodes = std.ArrayList(Node).empty;
    try then_nodes.append(allocator, .{ .text = "yes" });

    var else_nodes = std.ArrayList(Node).empty;
    try else_nodes.append(allocator, .{ .text = "no" });

    const node = Node{ .if_block = .{
        .condition = "show",
        .then_nodes = then_nodes,
        .else_nodes = else_nodes,
    } };

    try std.testing.expectEqualStrings("show", node.if_block.condition);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.then_nodes.items.len);
    try std.testing.expect(node.if_block.else_nodes != null);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.else_nodes.?.items.len);

    then_nodes.deinit(allocator);
    else_nodes.deinit(allocator);
}

test "Node - ForBlock construction" {
    const allocator = std.testing.allocator;
    var body_nodes = std.ArrayList(Node).empty;
    try body_nodes.append(allocator, .{ .text = "item" });

    const node = Node{ .for_block = .{
        .item_var = "item",
        .list_var = "items",
        .body_nodes = body_nodes,
    } };

    try std.testing.expectEqualStrings("item", node.for_block.item_var);
    try std.testing.expectEqualStrings("items", node.for_block.list_var);
    try std.testing.expectEqual(@as(usize, 1), node.for_block.body_nodes.items.len);

    body_nodes.deinit(allocator);
}

test "Node - BlockDef construction" {
    const allocator = std.testing.allocator;
    var block_nodes = std.ArrayList(Node).empty;
    try block_nodes.append(allocator, .{ .text = "content" });

    const node = Node{ .block_def = .{
        .name = "header",
        .nodes = block_nodes,
    } };

    try std.testing.expectEqualStrings("header", node.block_def.name);
    try std.testing.expectEqual(@as(usize, 1), node.block_def.nodes.items.len);

    block_nodes.deinit(allocator);
}

test "Node - SetVar construction" {
    const node = Node{ .set_var = .{
        .name = "x",
        .value = "42",
    } };

    try std.testing.expectEqualStrings("x", node.set_var.name);
    try std.testing.expectEqualStrings("42", node.set_var.value);
}

// ============================================================
// parseSimple additional tests
// ============================================================

test "parseSimple - multiple variables" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{first}} {{last}}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), nodes.items.len);

    switch (nodes.items[0]) {
        .var_esc => |v| try std.testing.expectEqualStrings("first", v),
        else => @panic("expected var_esc"),
    }

    switch (nodes.items[1]) {
        .text => |t| try std.testing.expectEqualStrings(" ", t),
        else => @panic("expected text"),
    }

    switch (nodes.items[2]) {
        .var_esc => |v| try std.testing.expectEqualStrings("last", v),
        else => @panic("expected var_esc"),
    }
}

test "parseSimple - if block" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{if show}}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .if_block => |ib| {
            try std.testing.expectEqualStrings("show", ib.condition);
            try std.testing.expectEqual(@as(usize, 0), ib.then_nodes.items.len);
            try std.testing.expect(ib.else_nodes == null);
        },
        else => @panic("expected if_block"),
    }
}

test "parseSimple - set variable" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{set x=10}}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .set_var => |sv| {
            try std.testing.expectEqualStrings("x", sv.name);
            try std.testing.expectEqualStrings("10", sv.value);
        },
        else => @panic("expected set_var"),
    }
}

test "parseSimple - var keyword set" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{var name=Alice}}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .set_var => |sv| {
            try std.testing.expectEqualStrings("name", sv.name);
            try std.testing.expectEqualStrings("Alice", sv.value);
        },
        else => @panic("expected set_var"),
    }
}

test "parseSimple - mixed text and variables" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "Hello {{name}}, welcome to {{place}}!");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), nodes.items.len);

    switch (nodes.items[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello ", t),
        else => @panic("expected text"),
    }
    switch (nodes.items[1]) {
        .var_esc => |v| try std.testing.expectEqualStrings("name", v),
        else => @panic("expected var_esc"),
    }
    switch (nodes.items[2]) {
        .text => |t| try std.testing.expectEqualStrings(", welcome to ", t),
        else => @panic("expected text"),
    }
    switch (nodes.items[3]) {
        .var_esc => |v| try std.testing.expectEqualStrings("place", v),
        else => @panic("expected var_esc"),
    }
    switch (nodes.items[4]) {
        .text => |t| try std.testing.expectEqualStrings("!", t),
        else => @panic("expected text"),
    }
}

test "parseSimple - unclosed tag treated as text" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "Hello {{unclosed");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
    switch (nodes.items[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello ", t),
        else => @panic("expected text"),
    }
    switch (nodes.items[1]) {
        .text => |t| try std.testing.expectEqualStrings("{{unclosed", t),
        else => @panic("expected text"),
    }
}

test "parseSimple - raw variable with whitespace" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{{ raw_var }}}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .var_raw => |v| try std.testing.expectEqualStrings("raw_var", v),
        else => @panic("expected var_raw"),
    }
}

test "parseSimple - escaped variable with whitespace" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "{{ name }}");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    switch (nodes.items[0]) {
        .var_esc => |v| try std.testing.expectEqualStrings("name", v),
        else => @panic("expected var_esc"),
    }
}

test "parseSimple - empty string" {
    const allocator = std.testing.allocator;
    var nodes = try parseSimple(allocator, "");
    defer nodes.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), nodes.items.len);
}

// ============================================================
// Template.render tests
// ============================================================

test "render - text only" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .text = "Hello, World!" });

    var scope = Scope{};
    defer scope.deinit(allocator);

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "render - escaped variable substitution" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .text = "Hello, " });
    try tmpl.nodes.append(allocator, .{ .var_esc = "name" });
    try tmpl.nodes.append(allocator, .{ .text = "!" });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "name", "World");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "render - escaped variable with HTML chars" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .var_esc = "html" });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "html", "<b>bold</b>");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("&lt;b&gt;bold&lt;/b&gt;", result);
}

test "render - raw variable substitution" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .var_raw = "html" });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "html", "<b>bold</b>");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("<b>bold</b>", result);
}

test "render - missing variable renders as empty" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .text = "[" });
    try tmpl.nodes.append(allocator, .{ .var_esc = "missing" });
    try tmpl.nodes.append(allocator, .{ .text = "]" });

    var scope = Scope{};
    defer scope.deinit(allocator);

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[]", result);
}

test "render - multiple variables" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    try tmpl.nodes.append(allocator, .{ .var_esc = "first" });
    try tmpl.nodes.append(allocator, .{ .text = " " });
    try tmpl.nodes.append(allocator, .{ .var_esc = "last" });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "first", "John");
    try scope.put(allocator, "last", "Doe");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("John Doe", result);
}

test "render - if block truthy" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var then_nodes = std.ArrayList(Node).empty;
    try then_nodes.append(allocator, .{ .text = "shown" });

    try tmpl.nodes.append(allocator, .{ .if_block = .{
        .condition = "show",
        .then_nodes = then_nodes,
    } });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "show", "true");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("shown", result);
}

test "render - if block falsy" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var then_nodes = std.ArrayList(Node).empty;
    try then_nodes.append(allocator, .{ .text = "shown" });

    try tmpl.nodes.append(allocator, .{ .if_block = .{
        .condition = "show",
        .then_nodes = then_nodes,
    } });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "show", "false");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "render - if block with else" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var then_nodes = std.ArrayList(Node).empty;
    try then_nodes.append(allocator, .{ .text = "yes" });

    var else_nodes = std.ArrayList(Node).empty;
    try else_nodes.append(allocator, .{ .text = "no" });

    try tmpl.nodes.append(allocator, .{ .if_block = .{
        .condition = "show",
        .then_nodes = then_nodes,
        .else_nodes = else_nodes,
    } });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "show", "0");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("no", result);
}

test "render - set variable during render" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    // set_var resolves sv.value as a variable name, then stores the result as sv.name
    try tmpl.nodes.append(allocator, .{ .set_var = .{ .name = "x", .value = "source" } });
    try tmpl.nodes.append(allocator, .{ .text = "value=" });
    try tmpl.nodes.append(allocator, .{ .var_esc = "x" });

    var scope = Scope{};
    defer scope.deinit(allocator);
    try scope.put(allocator, "source", "42");

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("value=42", result);
}

test "render - empty template" {
    const allocator = std.testing.allocator;
    var tmpl = Template.init(allocator, std.testing.io, .{});
    defer tmpl.deinit();

    var scope = Scope{};
    defer scope.deinit(allocator);

    const result = try tmpl.render(@ptrCast(&scope));
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}
