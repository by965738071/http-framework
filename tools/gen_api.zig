//! gen_api.zig — generate a public-API signature inventory for this project (markdown).
//!
//! Usage: zig run tools/gen_api.zig -- <mode> [--root <project-root>]
//!   mode = generate  print the inventory markdown to stdout
//!   mode = check     run the same pass quietly; exit non-zero if any file failed to parse
//!
//! Detection strategy: each candidate file is parsed with `std.zig.Ast`; only root-level
//! (top-level) declarations are inspected. `pub` visibility is read from the AST
//! (`visib_token`), so nested `pub` declarations inside structs/tests are naturally skipped.
//! Signature text for functions is the raw source slice from the `fn` keyword up to the body
//! `{` (or the terminating `;` for header-only declarations), with comments stripped and
//! whitespace collapsed onto one line. Files that fail to parse are reported with
//! `<!-- WARN: parse failed: <path> -->` under their module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ast = std.zig.Ast;

const max_file_bytes = 16 * 1024 * 1024;

/// Project-relative module directories to scan. Module name = dir basename.
const module_dirs = [_][]const u8{
    "src/http_protocol",
    "src/http_app",
    "src/http_router",
    "src/http_server",
    "src/http_security",
    "src/http_session",
    "src/http_rate_limit",
    "src/http_compress",
    "src/http_static",
    "src/http_logging",
    "src/http_codec",
    "src/http_multipart",
    "src/http_testing",
    "src/http_orm",
    "src/http_websocket",
};

const Decl = struct {
    symbol: []const u8,
    rel_path: []const u8,
    line: usize, // 1-based line of the declaration
    signature: []const u8, // one-line, `pub ` prefix and trailing `;` stripped
};

const ModuleResult = struct {
    name: []const u8,
    decls: std.ArrayList(Decl) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
};

const usage = "usage: zig run tools/gen_api.zig -- <generate|check> [--root <project-root>]\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var mode: ?[]const u8 = null;
    var root: []const u8 = ".";
    var i: usize = if (argv.len > 0) 1 else 0; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len) usageExit(io);
            root = argv[i];
        } else if (mode == null and (std.mem.eql(u8, arg, "generate") or std.mem.eql(u8, arg, "check"))) {
            mode = arg;
        } else {
            usageExit(io);
        }
    }
    const mode_ = mode orelse usageExit(io);

    var root_dir = std.Io.Dir.cwd();
    var opened_root: ?std.Io.Dir = null;
    if (!std.mem.eql(u8, root, ".")) {
        opened_root = std.Io.Dir.cwd().openDir(io, root, .{}) catch {
            const msg = std.fmt.allocPrint(arena, "error: cannot open root '{s}'\n", .{root}) catch {
                eprint(io, "error: cannot open root\n");
                std.process.exit(1);
            };
            eprint(io, msg);
            std.process.exit(1);
        };
        root_dir = opened_root.?;
    }
    defer if (opened_root) |*d| d.close(io);

    var modules = std.ArrayList(ModuleResult).empty;
    for (module_dirs) |dir_rel| {
        var result = ModuleResult{ .name = std.fs.path.basename(dir_rel) };
        try scanModule(arena, io, root_dir, dir_rel, &result);
        try modules.append(arena, result);
    }

    if (std.mem.eql(u8, mode_, "generate")) {
        var md = std.ArrayList(u8).empty;
        try md.appendSlice(arena, "# Public API signature inventory\n");
        for (modules.items) |module| try writeModule(arena, &md, module);
        try std.Io.File.stdout().writeStreamingAll(io, md.items);
    } else {
        // check: stay silent unless something failed, and then say what.
        var failed = false;
        for (modules.items) |module| {
            for (module.warnings.items) |w| {
                failed = true;
                const line = std.fmt.allocPrint(arena, "{s}\n", .{w}) catch continue;
                eprint(io, line);
            }
        }
        if (failed) std.process.exit(1);
    }
}

/// Scan one module directory, appending declarations and warnings into `result`.
/// Only allocation errors propagate; I/O and parse problems become warning lines.
fn scanModule(
    arena: Allocator,
    io: Io,
    root_dir: std.Io.Dir,
    dir_rel: []const u8,
    result: *ModuleResult,
) Allocator.Error!void {
    var dir = root_dir.openDir(io, dir_rel, .{ .iterate = true }) catch {
        try result.warnings.append(
            arena,
            try std.fmt.allocPrint(arena, "<!-- WARN: cannot open module dir: {s} -->", .{dir_rel}),
        );
        return;
    };
    defer dir.close(io);

    // Entry names are invalidated by the next iteration, so copy the ones we keep.
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch break;
        const entry = maybe_entry orelse break;
        switch (entry.kind) {
            .file, .unknown => {},
            else => continue,
        }
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.indexOf(u8, entry.name, "test") != null) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.sort.pdq([]const u8, names.items, {}, strLessThan);

    for (names.items) |name| {
        const rel_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, name });
        const source = root_dir.readFileAllocOptions(
            io,
            rel_path,
            arena,
            .limited(max_file_bytes),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try result.warnings.append(
                    arena,
                    try std.fmt.allocPrint(arena, "<!-- WARN: parse failed: {s} -->", .{rel_path}),
                );
                continue;
            },
        };
        try extractDecls(arena, source, rel_path, result);
    }
}

/// Parse one file's source and append its top-level `pub` declarations to `result`.
fn extractDecls(
    arena: Allocator,
    source: [:0]const u8,
    rel_path: []const u8,
    result: *ModuleResult,
) Allocator.Error!void {
    var ast = try Ast.parse(arena, source, .{});
    defer ast.deinit(arena);

    if (ast.errors.len != 0) {
        try result.warnings.append(
            arena,
            try std.fmt.allocPrint(arena, "<!-- WARN: parse failed: {s} -->", .{rel_path}),
        );
        return;
    }

    for (ast.rootDecls()) |node| {
        switch (ast.nodeTag(node)) {
            .fn_decl => {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = ast.fullFnProto(
                    &buf,
                    ast.nodeData(node).node_and_node[0],
                ) orelse continue;
                const visib = proto.visib_token orelse continue; // skip non-pub
                const name_token = proto.name_token orelse continue;
                if (ast.tokenTag(name_token) != .identifier) continue;
                const name = identText(source, ast.tokenStart(name_token));
                const sig_start = ast.tokenStart(proto.ast.fn_token);
                const sig_end = findSigEnd(source, sig_start);
                const signature = try collapseRange(arena, source[sig_start..sig_end]);
                try result.decls.append(arena, .{
                    .symbol = name,
                    .rel_path = rel_path,
                    .line = lineAt(source, ast.tokenStart(visib)),
                    .signature = signature,
                });
            },
            .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = ast.fullVarDecl(node) orelse continue;
                const visib = var_decl.visib_token orelse continue; // skip non-pub
                const init_node = var_decl.ast.init_node.unwrap() orelse continue;
                const kind: []const u8 = switch (ast.tokenTag(ast.nodeMainToken(init_node))) {
                    .keyword_struct => "struct",
                    .keyword_enum => "enum",
                    .keyword_union => "union",
                    else => continue, // re-exports, aliases, error sets, etc.
                };
                // The declared name is the identifier token right after `const`.
                const name = identText(source, ast.tokenStart(var_decl.ast.mut_token + 1));
                try result.decls.append(arena, .{
                    .symbol = name,
                    .rel_path = rel_path,
                    .line = lineAt(source, ast.tokenStart(visib)),
                    .signature = try std.fmt.allocPrint(arena, "const {s} = {s}", .{ name, kind }),
                });
            },
            else => {},
        }
    }
}

/// From `start` (the `fn` keyword), find the offset of the body-opening `{` at
/// bracket depth 0, or the terminating `;` for header-only declarations.
/// Line comments, string and character literals are skipped.
fn findSigEnd(source: []const u8, start: usize) usize {
    var i = start;
    var depth: u32 = 0;
    while (i < source.len) {
        switch (source[i]) {
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                    continue;
                }
                i += 1;
            },
            '"', '\'' => {
                i = skipQuoted(source, i);
            },
            '(', '[' => {
                depth += 1;
                i += 1;
            },
            '{' => {
                if (depth == 0) return i;
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                depth -= @intFromBool(depth > 0);
                i += 1;
            },
            ';' => {
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return source.len;
}

/// `i` points at a `"` or `'`; returns the offset just past the closing quote.
/// Bails out (returns i + 1) on an unescaped newline so a stray quote cannot
/// swallow the rest of the file.
fn skipQuoted(source: []const u8, i: usize) usize {
    const quote = source[i];
    var j = i + 1;
    while (j < source.len) : (j += 1) {
        const c = source[j];
        if (c == '\\') {
            j += 1;
        } else if (c == quote) {
            return j + 1;
        } else if (c == '\n') {
            return i + 1;
        }
    }
    return source.len;
}

/// Strip line comments and collapse all whitespace runs to single spaces.
fn collapseRange(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena);
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space and out.items.len > 0) {
            // Avoid spaces just inside parentheses: "( a" -> "(a", "a )" -> "a)".
            const suppress = c == ')' or out.items[out.items.len - 1] == '(';
            if (!suppress) try out.append(arena, ' ');
        }
        pending_space = false;
        if (c == '"' or c == '\'') {
            // Copy quoted runs verbatim so comment-like content inside them survives.
            const end = skipQuoted(text, i);
            try out.appendSlice(arena, text[i..end]);
            i = end;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// 1-based line number containing `offset`.
fn lineAt(source: []const u8, offset: usize) usize {
    return 1 + std.mem.count(u8, source[0..offset], "\n");
}

/// The identifier text starting at `start`.
fn identText(source: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1) {}
    return source[start..end];
}

fn strLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn writeModule(arena: Allocator, md: *std.ArrayList(u8), module: ModuleResult) Allocator.Error!void {
    try md.appendSlice(arena, "\n## ");
    try md.appendSlice(arena, module.name);
    try md.appendSlice(arena, "\n\n");
    if (module.warnings.items.len > 0) {
        for (module.warnings.items) |w| {
            try md.appendSlice(arena, w);
            try md.append(arena, '\n');
        }
        try md.append(arena, '\n');
    }
    try md.appendSlice(arena, "| 符号 | 文件:行 | 签名 |\n| --- | --- | --- |\n");
    for (module.decls.items) |d| {
        const signature = try escapePipes(arena, d.signature);
        const row = try std.fmt.allocPrint(arena, "| `{s}` | {s}:{d} | `{s}` |\n", .{
            d.symbol,
            d.rel_path,
            d.line,
            signature,
        });
        try md.appendSlice(arena, row);
    }
}

fn escapePipes(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '|') == null) return text;
    var out = std.ArrayList(u8).empty;
    for (text) |c| {
        if (c == '|') {
            try out.appendSlice(arena, "\\|");
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}

fn eprint(io: Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn usageExit(io: Io) noreturn {
    eprint(io, usage);
    std.process.exit(1);
}
