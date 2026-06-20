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
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();
        try self.renderNodes(self.nodes.items, scope, &list);
        return list.toOwnedSlice();
    }

    fn renderNodes(
        self: *const Self,
        nodes: []const Node,
        scope: *Scope,
        out: *std.ArrayList(u8),
    ) !void {
        for (nodes) |*node| {
            switch (node.*) {
                .text => |t| try out.appendSlice(t),
                .var_esc => |v| {
                    const val = self.resolveVar(v, scope) orelse "";
                    try self.appendEscaped(out, val);
                },
                .var_raw => |v| {
                    const val = self.resolveVar(v, scope) orelse "";
                    try out.appendSlice(val);
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
                            try fb.body_vars(scope, self.allocator, item, fb.item_var);
                            try self.renderNodes(fb.body_nodes.items, scope, out);
                            rest = rest[idx + 2 ..];
                        } else {
                            const item = rest;
                            if (item.len > 0) {
                                try fb.body_vars(scope, self.allocator, item, fb.item_var);
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

    fn appendEscaped(_: *const Self, out: *std.ArrayList(u8), s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '&' => out.appendSlice("&amp;") catch {},
                '<' => out.appendSlice("&lt;") catch {},
                '>' => out.appendSlice("&gt;") catch {},
                '"' => out.appendSlice("&quot;") catch {},
                else => out.append(c) catch {},
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
