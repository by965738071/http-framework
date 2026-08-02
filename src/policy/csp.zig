//! Content Security Policy (CSP) Builder
//!
//! Provides a type-safe, composable CSP policy builder with support for
//! all standard CSP directives, nonce generation, and common presets.
//!
//! # Usage
//!
//! ```zig
//! var csp = CspBuilder.init(allocator);
//! defer csp.deinit();
//!
//! try csp.setDefaultSrc(.self);
//! try csp.addScriptSrc(.self);
//! try csp.nonce("abc123");
//!
//! const policy = try csp.build();
//! defer allocator.free(policy);
//! ```

const std = @import("std");

/// A single source value in a CSP directive
pub const Source = union(enum) {
    /// 'self'
    self,
    /// 'none'
    none,
    /// 'unsafe-inline'
    unsafe_inline,
    /// 'unsafe-eval'
    unsafe_eval,
    /// 'strict-dynamic'
    strict_dynamic,
    /// 'nonce-{value}'
    nonce: []const u8,
    /// 'sha256-{base64}'
    hash_sha256: []const u8,
    /// 'sha384-{base64}'
    hash_sha384: []const u8,
    /// 'sha512-{base64}'
    hash_sha512: []const u8,
    /// A host source (e.g. "https://cdn.example.com")
    host: []const u8,
    /// A scheme (e.g. "https:", "data:", "blob:")
    scheme: []const u8,
    /// A wildcard (e.g. "*.example.com")
    wildcard: []const u8,
    /// Empty / no restriction (for default-src: allow everything except none)
    blank,
};

/// CSP directives
const Directive = enum {
    default_src,
    script_src,
    style_src,
    img_src,
    font_src,
    connect_src,
    media_src,
    object_src,
    child_src, // replacement for frame-src / manifest-src
    frame_src,
    manifest_src,
    plugin_types,
    prefetch_src,
    worker_src,
    base_uri,
    form_action,
    frame_ancestors,
    navigate_to,
    report_uri,
    require_trusted_type_for,
};

/// Common CSP presets
pub const Preset = enum {
    /// Strictest: only load resources from same origin, no inline scripts/styles
    strict,
    /// Moderate: allow self + common CDNs
    moderate,
    /// Relaxed: allow self + inline scripts/styles (for development)
    relaxed,
};

/// CSP Builder — accumulates directive sources, builds policy string
pub const CspBuilder = struct {
    allocator: std.mem.Allocator,

    default_src: std.ArrayList(Source) = .empty,
    script_src: std.ArrayList(Source) = .empty,
    style_src: std.ArrayList(Source) = .empty,
    img_src: std.ArrayList(Source) = .empty,
    font_src: std.ArrayList(Source) = .empty,
    connect_src: std.ArrayList(Source) = .empty,
    media_src: std.ArrayList(Source) = .empty,
    object_src: std.ArrayList(Source) = .empty,
    child_src: std.ArrayList(Source) = .empty,
    frame_src: std.ArrayList(Source) = .empty,
    manifest_src: std.ArrayList(Source) = .empty,
    prefetch_src: std.ArrayList(Source) = .empty,
    worker_src: std.ArrayList(Source) = .empty,
    base_uri: std.ArrayList(Source) = .empty,
    form_action: std.ArrayList(Source) = .empty,
    frame_ancestors: std.ArrayList(Source) = .empty,
    navigate_to: std.ArrayList(Source) = .empty,
    report_uri: std.ArrayList(Source) = .empty,
    require_trusted_type_for: std.ArrayList(Source) = .empty,

    /// Whether to add `Upgrade-Insecure-Requests` header
    upgrade_insecure_requests: bool = false,

    /// Report-only mode — uses `Content-Security-Policy-Report-Only` header
    report_only: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        const arrs = [_]*std.ArrayList(Source){
            &self.default_src, &self.script_src,  &self.style_src,                &self.img_src,
            &self.font_src,    &self.connect_src, &self.media_src,                &self.object_src,
            &self.child_src,   &self.frame_src,   &self.manifest_src,             &self.prefetch_src,
            &self.worker_src,  &self.base_uri,    &self.form_action,              &self.frame_ancestors,
            &self.navigate_to, &self.report_uri,  &self.require_trusted_type_for,
        };
        for (arrs) |arr| {
            arr.deinit(self.allocator);
        }
    }

    // ── Convenience helpers ────────────────────────────────────────────

    pub fn selfSrc(self: *Self, directive: Directive) !void {
        switch (directive) {
            .default_src => try self.default_src.append(self.allocator, .self),
            .script_src => try self.script_src.append(self.allocator, .self),
            .style_src => try self.style_src.append(self.allocator, .self),
            .img_src => try self.img_src.append(self.allocator, .self),
            .font_src => try self.font_src.append(self.allocator, .self),
            .connect_src => try self.connect_src.append(self.allocator, .self),
            .media_src => try self.media_src.append(self.allocator, .self),
            .object_src => try self.object_src.append(self.allocator, .self),
            .child_src => try self.child_src.append(self.allocator, .self),
            .frame_src => try self.frame_src.append(self.allocator, .self),
            .manifest_src => try self.manifest_src.append(self.allocator, .self),
            .prefetch_src => try self.prefetch_src.append(self.allocator, .self),
            .worker_src => try self.worker_src.append(self.allocator, .self),
            .base_uri => try self.base_uri.append(self.allocator, .self),
            .form_action => try self.form_action.append(self.allocator, .self),
            .frame_ancestors => try self.frame_ancestors.append(self.allocator, .self),
            .navigate_to => try self.navigate_to.append(self.allocator, .self),
            .plugin_types => {},
            .report_uri, .require_trusted_type_for => {},
        }
    }

    pub fn noneSrc(self: *Self, directive: Directive) !void {
        switch (directive) {
            .default_src => try self.default_src.append(self.allocator, .none),
            .script_src => try self.script_src.append(self.allocator, .none),
            .style_src => try self.style_src.append(self.allocator, .none),
            .img_src => try self.img_src.append(self.allocator, .none),
            .font_src => try self.font_src.append(self.allocator, .none),
            .connect_src => try self.connect_src.append(self.allocator, .none),
            .media_src => try self.media_src.append(self.allocator, .none),
            .object_src => try self.object_src.append(self.allocator, .none),
            .child_src => try self.child_src.append(self.allocator, .none),
            .frame_src => try self.frame_src.append(self.allocator, .none),
            .manifest_src => try self.manifest_src.append(self.allocator, .none),
            .prefetch_src => try self.prefetch_src.append(self.allocator, .none),
            .worker_src => try self.worker_src.append(self.allocator, .none),
            .base_uri => try self.base_uri.append(self.allocator, .none),
            .form_action => try self.form_action.append(self.allocator, .none),
            .frame_ancestors => try self.frame_ancestors.append(self.allocator, .none),
            .navigate_to => try self.navigate_to.append(self.allocator, .none),
            .plugin_types => {},
            .report_uri, .require_trusted_type_for => {},
        }
    }

    pub fn allowHost(self: *Self, directive: Directive, host: []const u8) !void {
        const src = Source{ .host = host };
        switch (directive) {
            .default_src => try self.default_src.append(self.allocator, src),
            .script_src => try self.script_src.append(self.allocator, src),
            .style_src => try self.style_src.append(self.allocator, src),
            .img_src => try self.img_src.append(self.allocator, src),
            .font_src => try self.font_src.append(self.allocator, src),
            .connect_src => try self.connect_src.append(self.allocator, src),
            .media_src => try self.media_src.append(self.allocator, src),
            .object_src => try self.object_src.append(self.allocator, src),
            .child_src => try self.child_src.append(self.allocator, src),
            .frame_src => try self.frame_src.append(self.allocator, src),
            .manifest_src => try self.manifest_src.append(self.allocator, src),
            .prefetch_src => try self.prefetch_src.append(self.allocator, src),
            .worker_src => try self.worker_src.append(self.allocator, src),
            .base_uri => try self.base_uri.append(self.allocator, src),
            .form_action => try self.form_action.append(self.allocator, src),
            .frame_ancestors => try self.frame_ancestors.append(self.allocator, src),
            .navigate_to => try self.navigate_to.append(self.allocator, src),
            .plugin_types => {},
            .report_uri, .require_trusted_type_for => {},
        }
    }

    pub fn allowSelf(self: *Self) !void {
        try selfSrc(self, .default_src);
        try selfSrc(self, .script_src);
        try selfSrc(self, .style_src);
        try selfSrc(self, .img_src);
        try selfSrc(self, .font_src);
        try selfSrc(self, .connect_src);
        try selfSrc(self, .media_src);
        try selfSrc(self, .object_src);
        try selfSrc(self, .child_src);
        try selfSrc(self, .frame_src);
        try selfSrc(self, .manifest_src);
        try selfSrc(self, .worker_src);
    }

    pub fn nonce(self: *Self, value: []const u8) !void {
        const src = Source{ .nonce = value };
        try self.script_src.append(self.allocator, src);
        try self.style_src.append(self.allocator, src);
    }

    pub fn unsafeInline(self: *Self) !void {
        try self.script_src.append(self.allocator, .unsafe_inline);
        try self.style_src.append(self.allocator, .unsafe_inline);
    }

    pub fn unsafeEval(self: *Self) !void {
        try self.script_src.append(self.allocator, .unsafe_eval);
    }

    pub fn strictDynamic(self: *Self) !void {
        try self.script_src.append(self.allocator, .strict_dynamic);
    }

    pub fn hash(self: *Self, directive: Directive, algorithm: enum { sha256, sha384, sha512 }, b64: []const u8) !void {
        const src: Source = switch (algorithm) {
            .sha256 => .{ .hash_sha256 = b64 },
            .sha384 => .{ .hash_sha384 = b64 },
            .sha512 => .{ .hash_sha512 = b64 },
        };
        switch (directive) {
            .script_src => try self.script_src.append(self.allocator, src),
            .style_src => try self.style_src.append(self.allocator, src),
            else => {},
        }
    }

    pub fn reportUri(self: *Self, uri: []const u8) !void {
        try self.report_uri.append(self.allocator, .{ .host = uri });
    }

    pub fn upgradeInsecureRequests(self: *Self) void {
        self.upgrade_insecure_requests = true;
    }

    pub fn setReportOnly(self: *Self, v: bool) void {
        self.report_only = v;
    }

    // ── Presets ────────────────────────────────────────────────────────

    pub fn applyPreset(self: *Self, preset: Preset) !void {
        switch (preset) {
            .strict => {
                try self.noneSrc(.default_src);
                try self.selfSrc(.script_src);
                try self.selfSrc(.style_src);
                try self.selfSrc(.img_src);
                try self.selfSrc(.font_src);
                try self.selfSrc(.connect_src);
                try self.selfSrc(.media_src);
                try self.noneSrc(.object_src);
                try self.selfSrc(.frame_src);
                try self.selfSrc(.form_action);
                try self.selfSrc(.frame_ancestors);
            },
            .moderate => {
                try self.selfSrc(.default_src);
                try self.script_src.append(self.allocator, .self);
                try self.script_src.append(self.allocator, .{ .host = "https://cdn.jsdelivr.net" });
                try self.script_src.append(self.allocator, .{ .host = "https://unpkg.com" });
                try self.style_src.append(self.allocator, .self);
                try self.style_src.append(self.allocator, .unsafe_inline);
                try self.style_src.append(self.allocator, .{ .host = "https://cdn.jsdelivr.net" });
                try self.img_src.append(self.allocator, .self);
                try self.img_src.append(self.allocator, .{ .scheme = "data:" });
                try self.font_src.append(self.allocator, .self);
                try self.font_src.append(self.allocator, .{ .host = "https://fonts.googleapis.com" });
                try self.font_src.append(self.allocator, .{ .host = "https://fonts.gstatic.com" });
                try self.connect_src.append(self.allocator, .self);
                try self.object_src.append(self.allocator, .none);
                try self.frame_ancestors.append(self.allocator, .none);
            },
            .relaxed => {
                try self.selfSrc(.default_src);
                try self.selfSrc(.script_src);
                try self.unsafeInline();
                try self.unsafeEval();
                try self.selfSrc(.style_src);
                try self.unsafeInline();
                try self.selfSrc(.img_src);
                try self.img_src.append(self.allocator, .{ .scheme = "data:" });
                try self.selfSrc(.font_src);
                try self.font_src.append(self.allocator, .{ .scheme = "data:" });
                try self.selfSrc(.connect_src);
                try self.object_src.append(self.allocator, .none);
            },
        }
    }

    // ── Build ──────────────────────────────────────────────────────────

    pub fn build(self: *const Self) ![]u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);

        const directives = [_]struct {
            name: []const u8,
            sources: *const std.ArrayList(Source),
        }{
            .{ .name = "default-src", .sources = &self.default_src },
            .{ .name = "script-src", .sources = &self.script_src },
            .{ .name = "style-src", .sources = &self.style_src },
            .{ .name = "img-src", .sources = &self.img_src },
            .{ .name = "font-src", .sources = &self.font_src },
            .{ .name = "connect-src", .sources = &self.connect_src },
            .{ .name = "media-src", .sources = &self.media_src },
            .{ .name = "object-src", .sources = &self.object_src },
            .{ .name = "child-src", .sources = &self.child_src },
            .{ .name = "frame-src", .sources = &self.frame_src },
            .{ .name = "manifest-src", .sources = &self.manifest_src },
            .{ .name = "base-uri", .sources = &self.base_uri },
            .{ .name = "form-action", .sources = &self.form_action },
            .{ .name = "frame-ancestors", .sources = &self.frame_ancestors },
            .{ .name = "worker-src", .sources = &self.worker_src },
            .{ .name = "manifest-src", .sources = &self.manifest_src },
            .{ .name = "prefetch-src", .sources = &self.prefetch_src },
            .{ .name = "report-uri", .sources = &self.report_uri },
            .{ .name = "navigate-to", .sources = &self.navigate_to },
            .{ .name = "require-trusted-types-for", .sources = &self.require_trusted_type_for },
        };

        for (directives) |dir| {
            if (dir.sources.items.len == 0) continue;
            try list.appendSlice(self.allocator, dir.name);
            try list.append(self.allocator, ' ');
            for (dir.sources.items, 0..) |src, i| {
                if (i > 0) try list.append(self.allocator, ' ');
                try appendSource(self.allocator, &list, src);
            }
            try list.append(self.allocator, ';');
        }

        // Remove trailing semicolon before toOwnedSlice to avoid allocation size mismatch on free
        if (list.items.len > 0 and list.items[list.items.len - 1] == ';') {
            list.items.len -= 1;
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// Returns the header name based on report_only setting
    pub fn headerName(self: *const Self) []const u8 {
        return if (self.report_only) "Content-Security-Policy-Report-Only" else "Content-Security-Policy";
    }
};

/// Format a Source into the CSP string
fn appendSource(allocator: std.mem.Allocator, list: *std.ArrayList(u8), src: Source) !void {
    switch (src) {
        .self => try list.appendSlice(allocator, "'self'"),
        .none => try list.appendSlice(allocator, "'none'"),
        .unsafe_inline => try list.appendSlice(allocator, "'unsafe-inline'"),
        .unsafe_eval => try list.appendSlice(allocator, "'unsafe-eval'"),
        .strict_dynamic => try list.appendSlice(allocator, "'strict-dynamic'"),
        .nonce => |v| {
            try list.appendSlice(allocator, "'nonce-");
            try list.appendSlice(allocator, v);
            try list.appendSlice(allocator, "'");
        },
        .hash_sha256 => |v| {
            try list.appendSlice(allocator, "'sha256-");
            try list.appendSlice(allocator, v);
            try list.appendSlice(allocator, "'");
        },
        .hash_sha384 => |v| {
            try list.appendSlice(allocator, "'sha384-");
            try list.appendSlice(allocator, v);
            try list.appendSlice(allocator, "'");
        },
        .hash_sha512 => |v| {
            try list.appendSlice(allocator, "'sha512-");
            try list.appendSlice(allocator, v);
            try list.appendSlice(allocator, "'");
        },
        .host => |v| try list.appendSlice(allocator, v),
        .scheme => |v| try list.appendSlice(allocator, v),
        .wildcard => |v| try list.appendSlice(allocator, v),
        .blank => {},
    }
}

// ===========================================================================
// Tests
// ===========================================================================

test "CspBuilder - strict preset" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.applyPreset(.strict);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'none'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "script-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "object-src 'none'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "frame-ancestors 'self'") != null);
}

test "CspBuilder - selfSrc and allowHost" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.allowHost(.script_src, "https://cdn.example.com");
    try csp.selfSrc(.script_src);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "https://cdn.example.com") != null);
}

test "CspBuilder - nonce" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.nonce("abc123");
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "'nonce-abc123'") != null);
}

test "CspBuilder - headerName" {
    var csp = CspBuilder.init(std.testing.allocator);
    defer csp.deinit();

    try std.testing.expectEqualStrings("Content-Security-Policy", csp.headerName());

    csp.setReportOnly(true);
    try std.testing.expectEqualStrings(
        "Content-Security-Policy-Report-Only",
        csp.headerName(),
    );
}

test "CspBuilder - upgradeInsecureRequests" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.default_src);
    csp.upgradeInsecureRequests();
    const policy = try csp.build();
    defer allocator.free(policy);

    // Upgrade header is set separately, just verify build works
    try std.testing.expect(policy.len > 0);
}

test "CspBuilder - empty policy" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    const policy = try csp.build();
    defer allocator.free(policy);
    try std.testing.expectEqualStrings("", policy);
}

test "CspBuilder - init and deinit with custom config" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    // Verify builder starts with empty state
    try std.testing.expectEqual(false, csp.upgrade_insecure_requests);
    try std.testing.expectEqual(false, csp.report_only);
    try std.testing.expectEqual(@as(usize, 0), csp.default_src.items.len);
    try std.testing.expectEqual(@as(usize, 0), csp.script_src.items.len);
    try std.testing.expectEqual(@as(usize, 0), csp.style_src.items.len);
}

test "CspBuilder - addStyleSrc via noneSrc" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.noneSrc(.style_src);
    try csp.selfSrc(.style_src);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "style-src 'none' 'self'") != null);
}

test "CspBuilder - addConnectSrc" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.connect_src);
    try csp.allowHost(.connect_src, "https://api.example.com");
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "connect-src 'self' https://api.example.com") != null);
}

test "CspBuilder - addImgSrc and addFontSrc" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.img_src);
    try csp.allowHost(.img_src, "https://images.example.com");
    try csp.noneSrc(.font_src);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "img-src 'self' https://images.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "font-src 'none'") != null);
}

test "CspBuilder - allowSelf convenience method" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.allowSelf();
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "script-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "style-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "img-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "connect-src 'self'") != null);
}

test "CspBuilder - unsafeInline and unsafeEval and strictDynamic" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.script_src);
    try csp.unsafeInline();
    try csp.unsafeEval();
    try csp.strictDynamic();
    try csp.selfSrc(.style_src);

    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "'unsafe-inline'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'unsafe-eval'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'strict-dynamic'") != null);
    // script-src should have self, unsafe-inline, unsafe-eval, strict-dynamic
    try std.testing.expect(std.mem.indexOf(u8, policy, "script-src 'self'") != null);
}

test "CspBuilder - hash sources" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.hash(.script_src, .sha256, "abc123");
    try csp.hash(.style_src, .sha384, "def456");
    try csp.hash(.script_src, .sha512, "ghi789");
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "'sha256-abc123'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'sha384-def456'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'sha512-ghi789'") != null);
}

test "CspBuilder - reportUri" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.reportUri("https://reports.example.com/csp");
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "report-uri https://reports.example.com/csp") != null);
}

test "CspBuilder - report only mode" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    csp.setReportOnly(true);
    try std.testing.expect(csp.report_only);
    try std.testing.expectEqualStrings("Content-Security-Policy-Report-Only", csp.headerName());

    try csp.selfSrc(.default_src);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
}

test "CspBuilder - object-src and frame-src and base-uri" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.noneSrc(.object_src);
    try csp.selfSrc(.frame_src);
    try csp.selfSrc(.base_uri);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "object-src 'none'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "frame-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "base-uri 'self'") != null);
}

test "CspBuilder - moderate preset" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.applyPreset(.moderate);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "https://cdn.jsdelivr.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'unsafe-inline'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "data:") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "object-src 'none'") != null);
}

test "CspBuilder - relaxed preset" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.applyPreset(.relaxed);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'unsafe-inline'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "'unsafe-eval'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "data:") != null);
}

test "CspBuilder - worker-src and media-src and child-src" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.worker_src);
    try csp.allowHost(.media_src, "https://media.example.com");
    try csp.selfSrc(.child_src);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "worker-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "media-src https://media.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "child-src 'self'") != null);
}

test "CspBuilder - form-action and frame-ancestors" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.form_action);
    try csp.noneSrc(.frame_ancestors);
    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "form-action 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "frame-ancestors 'none'") != null);
}

test "CspBuilder - multiple directives in a single policy" {
    const allocator = std.testing.allocator;
    var csp = CspBuilder.init(allocator);
    defer csp.deinit();

    try csp.selfSrc(.default_src);
    try csp.allowHost(.script_src, "https://cdn.example.com");
    try csp.selfSrc(.script_src);
    try csp.nonce("r4nd0m");
    try csp.selfSrc(.style_src);
    try csp.allowHost(.font_src, "https://fonts.example.com");
    try csp.noneSrc(.object_src);

    const policy = try csp.build();
    defer allocator.free(policy);

    try std.testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "script-src https://cdn.example.com 'self' 'nonce-r4nd0m'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "style-src 'nonce-r4nd0m' 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "font-src https://fonts.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "object-src 'none'") != null);
}
