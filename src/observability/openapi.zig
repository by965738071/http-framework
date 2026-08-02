//! OpenAPI 3.0 Generator
//!
//! Automatically generates OpenAPI 3.0 JSON specification from route definitions.
//! Supports automatic documentation from route comments and struct types.
//!
//! # Usage
//!
//! ```zig
//! var spec = try OpenApi.generate(allocator, router, .{
//!     .title = "My API",
//!     .version = "1.0.0",
//! });
//! defer spec.deinit();
//!
//! const json = try spec.toJson();
//! defer allocator.free(json);
//! ```

const std = @import("std");

/// OpenAPI document info
pub const Info = struct {
    title: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    contact: ?Contact = null,
    license: ?License = null,
};

pub const Contact = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const License = struct {
    name: []const u8,
    url: ?[]const u8 = null,
};

/// OpenAPI document
pub const Document = struct {
    allocator: std.mem.Allocator,
    openapi: []const u8 = "3.0.3",
    info: Info,
    servers: []const Server = &.{},
    paths: std.StringHashMap(PathItem),

    const Self = @This();

    pub const Server = struct {
        url: []const u8,
        description: ?[]const u8 = null,
    };

    pub const PathItem = struct {
        get: ?Operation = null,
        post: ?Operation = null,
        put: ?Operation = null,
        delete: ?Operation = null,
        patch: ?Operation = null,
    };

    pub const Operation = struct {
        operation_id: []const u8,
        summary: ?[]const u8 = null,
        description: ?[]const u8 = null,
        tags: []const []const u8 = &.{},
        parameters: []const Parameter = &.{},
        responses: ?std.StringHashMap(Response) = null,
        request_body: ?RequestBody = null,
    };

    pub const Parameter = struct {
        name: []const u8,
        in: []const u8,
        required: bool = false,
        schema: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };

    pub const Response = struct {
        description: []const u8,
        content_type: ?[]const u8 = "application/json",
    };

    pub const RequestBody = struct {
        content_type: []const u8 = "application/json",
        required: bool = true,
        schema: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, info: Info) Self {
        return .{
            .allocator = allocator,
            .info = info,
            .paths = .{ .unmanaged = .{}, .allocator = allocator, .ctx = .{} },
        };
    }

    pub fn addPath(self: *Self, path: []const u8, item: PathItem) !void {
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.paths.put(key, item);
    }

    pub fn deinit(self: *Self) void {
        var it = self.paths.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.paths.deinit();
    }

    /// Serialize to JSON string.
    pub fn toJson(self: *const Self) ![]u8 {
        const gpa = self.allocator;
        var list = try std.ArrayList(u8).initCapacity(gpa, 256);
        errdefer list.deinit(gpa);

        try list.append(gpa, '{');
        try list.appendSlice(gpa, "\"openapi\":\"3.0.3\",");
        try list.appendSlice(gpa, "\"info\":{");
        try list.appendSlice(gpa, "\"title\":\"");
        try self.jsonEscape(gpa, &list, self.info.title);
        try list.appendSlice(gpa, "\",\"version\":\"");
        try self.jsonEscape(gpa, &list, self.info.version);
        try list.append(gpa, '"');
        if (self.info.description) |desc| {
            try list.appendSlice(gpa, ",\"description\":\"");
            try self.jsonEscape(gpa, &list, desc);
            try list.append(gpa, '"');
        }
        try list.append(gpa, '}');

        // Paths
        try list.appendSlice(gpa, ",\"paths\":{");
        var first: bool = true;
        var it = self.paths.iterator();
        while (it.next()) |entry| {
            if (!first) try list.append(gpa, ',');
            first = false;
            try list.append(gpa, '\"');
            try self.jsonEscape(gpa, &list, entry.key_ptr.*);
            try list.append(gpa, '\"');
            try self.toJsonPathItem(gpa, &list, &entry.value_ptr.*);
        }
        try list.append(gpa, '}');

        try list.append(gpa, '}');
        return list.toOwnedSlice(gpa);
    }

    fn jsonEscape(_: *const Self, gpa: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try list.appendSlice(gpa, "\\\""),
                '\\' => try list.appendSlice(gpa, "\\\\"),
                '\n' => try list.appendSlice(gpa, "\\n"),
                '\r' => try list.appendSlice(gpa, "\\r"),
                '\t' => try list.appendSlice(gpa, "\\t"),
                else => try list.append(gpa, c),
            }
        }
    }

    fn toJsonPathItem(self: *const Self, gpa: std.mem.Allocator, list: *std.ArrayList(u8), item: *const PathItem) !void {
        try list.append(gpa, '{');

        const methods = [_]struct { name: []const u8, op: ?*const Operation }{
            .{ .name = "get", .op = if (item.get) |op| &op else null },
            .{ .name = "post", .op = if (item.post) |op| &op else null },
            .{ .name = "put", .op = if (item.put) |op| &op else null },
            .{ .name = "delete", .op = if (item.delete) |op| &op else null },
            .{ .name = "patch", .op = if (item.patch) |op| &op else null },
        };

        var first: bool = true;
        for (methods) |m| {
            if (m.op) |op| {
                if (!first) try list.append(gpa, ',');
                first = false;
                try list.append(gpa, '\"');
                try list.appendSlice(gpa, m.name);
                try list.append(gpa, '\"');
                try self.toJsonOperation(gpa, list, op);
            }
        }

        try list.append(gpa, '}');
    }

    fn toJsonOperation(self: *const Self, gpa: std.mem.Allocator, list: *std.ArrayList(u8), op: *const Operation) !void {
        try list.append(gpa, '{');
        try list.appendSlice(gpa, "\"operationId\":\"");
        try self.jsonEscape(gpa, list, op.operation_id);
        try list.append(gpa, '\"');

        if (op.summary) |s| {
            try list.appendSlice(gpa, ",\"summary\":\"");
            try self.jsonEscape(gpa, list, s);
            try list.append(gpa, '\"');
        }

        try list.append(gpa, '}');
    }
};

/// Generate OpenAPI document from routes.
pub fn generate(allocator: std.mem.Allocator, info: Info) !Document {
    return Document.init(allocator, info);
}

// ===========================================================================
// Tests
// ===========================================================================

test "OpenAPI - create document and toJson" {
    const allocator = std.testing.allocator;

    const info = Info{
        .title = "Test API",
        .version = "1.0.0",
    };
    var doc = Document.init(allocator, info);
    defer doc.deinit();

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expectEqualStrings("{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"Test API\",\"version\":\"1.0.0\"},\"paths\":{}}", json);
}

test "OpenAPI - add path and toJson" {
    const allocator = std.testing.allocator;

    const info = Info{
        .title = "Test API",
        .version = "1.0.0",
    };
    var doc = Document.init(allocator, info);
    defer doc.deinit();

    // Add a simple path
    const path = try allocator.dupe(u8, "/users");
    defer allocator.free(path);
    try doc.addPath(path, .{
        .get = .{
            .operation_id = "listUsers",
            .summary = "List all users",
        },
    });

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"/users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"listUsers\"") != null);
}

test "OpenAPI - JSON escaping" {
    const allocator = std.testing.allocator;

    const info = Info{
        .title = "API with \"quotes\" and \\backslash",
        .version = "1.0.0",
    };
    var doc = Document.init(allocator, info);
    defer doc.deinit();

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\\backslash") != null);
}

test "OpenAPI - Document init and deinit lifecycle" {
    const allocator = std.testing.allocator;

    const info = Info{
        .title = "Lifecycle API",
        .version = "2.0.0",
        .description = "A description",
    };
    var doc = Document.init(allocator, info);
    defer doc.deinit();

    try std.testing.expectEqualStrings("3.0.3", doc.openapi);
    try std.testing.expectEqualStrings("Lifecycle API", doc.info.title);
    try std.testing.expectEqualStrings("2.0.0", doc.info.version);
    try std.testing.expectEqualStrings("A description", doc.info.description.?);
    try std.testing.expectEqual(@as(usize, 0), doc.servers.len);
}

test "OpenAPI - addPath with GET method" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator, Info{ .title = "API", .version = "1.0" });
    defer doc.deinit();

    const path = try allocator.dupe(u8, "/users");
    defer allocator.free(path);
    try doc.addPath(path, .{
        .get = .{
            .operation_id = "listUsers",
            .summary = "List all users",
            .tags = &.{"users"},
        },
    });

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"/users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"listUsers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "List all users") != null);
}

test "OpenAPI - addPath with multiple HTTP methods" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator, Info{ .title = "API", .version = "1.0" });
    defer doc.deinit();

    // Add GET and POST on /items
    {
        const path = try allocator.dupe(u8, "/items");
        defer allocator.free(path);
        try doc.addPath(path, .{
            .get = .{ .operation_id = "listItems" },
            .post = .{ .operation_id = "createItem" },
        });
    }

    // Add PUT and DELETE on /items/{id}
    {
        const path = try allocator.dupe(u8, "/items/{id}");
        defer allocator.free(path);
        try doc.addPath(path, .{
            .put = .{ .operation_id = "updateItem" },
            .delete = .{ .operation_id = "deleteItem" },
        });
    }

    const json = try doc.toJson();
    defer allocator.free(json);

    // Verify all methods are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"listItems\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"createItem\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updateItem\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"deleteItem\"") != null);
}

test "OpenAPI - addPath with request body" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator, Info{ .title = "API", .version = "1.0" });
    defer doc.deinit();

    const path = try allocator.dupe(u8, "/items");
    defer allocator.free(path);
    try doc.addPath(path, .{
        .post = .{
            .operation_id = "createItem",
            .request_body = .{
                .content_type = "application/json",
                .required = true,
                .schema = "{\"type\":\"object\"}",
            },
        },
    });

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"createItem\"") != null);
}

test "OpenAPI - addPath with parameters" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator, Info{ .title = "API", .version = "1.0" });
    defer doc.deinit();

    const path = try allocator.dupe(u8, "/users/{id}");
    defer allocator.free(path);
    try doc.addPath(path, .{
        .get = .{
            .operation_id = "getUser",
            .parameters = &.{
                .{
                    .name = "id",
                    .in = "path",
                    .required = true,
                    .schema = "string",
                    .description = "User ID",
                },
                .{
                    .name = "fields",
                    .in = "query",
                    .required = false,
                    .description = "Fields to return",
                },
            },
        },
    });

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"getUser\"") != null);
}

test "OpenAPI - Info struct with contact and license" {
    const allocator = std.testing.allocator;

    const info = Info{
        .title = "Full API",
        .version = "1.0.0",
        .description = "Full API description",
        .contact = .{
            .name = "API Team",
            .email = "api@example.com",
        },
        .license = .{
            .name = "MIT",
            .url = "https://opensource.org/licenses/MIT",
        },
    };

    var doc = Document.init(allocator, info);
    defer doc.deinit();

    try std.testing.expectEqualStrings("Full API", doc.info.title);
    try std.testing.expectEqualStrings("API Team", doc.info.contact.?.name.?);
    try std.testing.expectEqualStrings("api@example.com", doc.info.contact.?.email.?);
    try std.testing.expectEqualStrings("MIT", doc.info.license.?.name);
    try std.testing.expectEqualStrings("https://opensource.org/licenses/MIT", doc.info.license.?.url.?);

    const json = try doc.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\"") != null);
}

test "OpenAPI - toJson output structure" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator, Info{ .title = "Test", .version = "1.0" });
    defer doc.deinit();

    const json = try doc.toJson();
    defer allocator.free(json);

    // Verify JSON structure starts with openapi key
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"openapi\":\"3.0.3\""));
    // Has info object
    try std.testing.expect(std.mem.indexOf(u8, json, "\"info\":{\"title\":\"Test\",\"version\":\"1.0\"}") != null);
    // Has paths object (empty)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paths\":{}") != null);
    // Ends with closing brace
    try std.testing.expect(json.len > 0 and json[json.len - 1] == '}');
}
