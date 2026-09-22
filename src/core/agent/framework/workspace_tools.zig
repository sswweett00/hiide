/// Workspace search tool: recursive, case-insensitive grep executed natively
/// in the engine. Exposes the shared search routine so the IPC server's
/// `workspace.search` method and the agent's `workspace.search` tool run the
/// exact same code path.
const std = @import("std");
const compat = @import("../../compat.zig");
const tool_mod = @import("tool.zig");

const MAX_SEARCH_RESULTS: usize = 1_000;
const MAX_TREE_ENTRIES: usize = 50_000;

pub const WorkspaceHit = struct {
    path: []const u8, // owned by caller
    line: usize,
    col: usize,
    text: []const u8, // owned by caller — matching line, trimmed
};

const IgnoredNames = [_][]const u8{
    ".git",           ".hg",           ".svn",
    "node_modules",   ".dart_tool",    ".zig-cache",
    ".zig-global-cache", "zig-out",    "dist",
    "target",         ".gradle",       "writable_flutter",
    "local_flutter",  ".flutter_cache", ".freebuff",
    "build",          ".idea",         ".vscode",
    ".kilo",          ".kilocode",     ".devin",
};

fn shouldIgnore(name: []const u8) bool {
    for (IgnoredNames) |ig| {
        if (std.mem.eql(u8, name, ig)) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    outer: for (0..haystack.len - needle.len + 1) |i| {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) continue :outer;
        }
        return i;
    }
    return null;
}

/// Recursive case-insensitive grep. `relative` relativizes hit paths against
/// the workspace root (used by the agent tool so the model can pass the path
/// straight back to file.read).
pub fn workspaceSearch(
    allocator: std.mem.Allocator,
    root: []const u8,
    query: []const u8,
    max_results: usize,
    relative: bool,
) ![]WorkspaceHit {
    if (query.len == 0) return allocator.alloc(WorkspaceHit, 0);

    const io = std.Io.Threaded.global_single_threaded.io();
    const abs_root = compat.realpathAlloc(allocator, root) catch return error.DirNotFound;
    defer allocator.free(abs_root);

    const lowered = try allocator.alloc(u8, query.len);
    defer allocator.free(lowered);
    for (query, 0..) |c, i| lowered[i] = std.ascii.toLower(c);

    var dir = try compat.cwd().openDir(io, abs_root, .{ .iterate = true });
    defer dir.close(io);

    var results = compat.ManagedArrayList(WorkspaceHit).init(allocator);
    errdefer {
        for (results.items) |hit| {
            allocator.free(hit.path);
            allocator.free(hit.text);
        }
        results.deinit();
    }

    try walkDir(allocator, io, dir, abs_root, lowered, max_results, &results);

    if (relative) {
        for (results.items) |*hit| {
            const abs = hit.path;
            var rel = abs;
            if (std.mem.startsWith(u8, abs, abs_root)) {
                rel = std.mem.trimStart(u8, abs[abs_root.len..], "/");
            }
            hit.path = try allocator.dupe(u8, rel);
            allocator.free(abs);
        }
    }

    return results.toOwnedSlice();
}

fn walkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    base_path: []const u8,
    lowered_query: []const u8,
    max_results: usize,
    results: *compat.ManagedArrayList(WorkspaceHit),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (results.items.len >= max_results) return;
        if (shouldIgnore(entry.name)) continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });
                defer allocator.free(sub_path);
                try walkDir(allocator, io, sub, sub_path, lowered_query, max_results, results);
            },
            .file => {
                const content = dir.readFileAlloc(io, entry.name, allocator, .limited(8 * 1024 * 1024)) catch continue;
                defer allocator.free(content);
                try searchContent(allocator, base_path, entry.name, content, lowered_query, max_results, results);
            },
            else => {},
        }
    }
}

fn searchContent(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    name: []const u8,
    content: []const u8,
    lowered_query: []const u8,
    max_results: usize,
    results: *compat.ManagedArrayList(WorkspaceHit),
) !void {
    // Treat files containing NUL bytes as binary and skip them.
    if (std.mem.indexOfScalar(u8, content, 0) != null) return;

    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_end = i == content.len;
        const is_nl = !at_end and content[i] == '\n';
        if (is_nl or at_end) {
            const line_slice = content[line_start..i];
            if (indexOfIgnoreCase(line_slice, lowered_query)) |offset| {
                const trimmed = std.mem.trim(u8, line_slice, " \t\r");
                const path = try std.fs.path.join(allocator, &.{ base_path, name });
                errdefer allocator.free(path);
                const text = try allocator.dupe(u8, trimmed);
                try results.append(.{
                    .path = path,
                    .line = line,
                    .col = offset + 1,
                    .text = text,
                });
                if (results.items.len >= max_results) return;
            }
            line += 1;
            line_start = i + 1;
        }
    }
}

/// Agent tool: `{"query": "...", "max_results"?: N}` → JSON array of
/// `{"path","line","col","text"}` hits with workspace-relative paths.
pub fn searchWorkspaceTool() tool_mod.Tool {
    const Entry = struct {
        path: []const u8,
        line: usize,
        col: usize,
        text: []const u8,
    };

    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;

            var parsed = try std.json.parseFromSlice(struct {
                query: []const u8,
                max_results: ?usize = null,
            }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            const max_results = @min(parsed.value.max_results orelse 50, MAX_SEARCH_RESULTS);
            const hits = workspaceSearch(allocator, ctx.workspace_root, parsed.value.query, max_results, true) catch |err| {
                return tool_mod.ToolResult.failure(@errorName(err));
            };
            defer {
                for (hits) |hit| {
                    allocator.free(hit.path);
                    allocator.free(hit.text);
                }
                allocator.free(hits);
            }

            const entries = try allocator.alloc(Entry, hits.len);
            defer allocator.free(entries);
            for (hits, 0..) |hit, i| {
                entries[i] = .{ .path = hit.path, .line = hit.line, .col = hit.col, .text = hit.text };
            }

            var output = compat.ManagedArrayList(u8).init(allocator);
            defer output.deinit();
            const bytes = try compat.jsonStringifyAlloc(allocator, entries, .{});
            defer allocator.free(bytes);
            try output.appendSlice(bytes);
            return tool_mod.ToolResult.success(try output.toOwnedSlice());
        }
    };
    return tool_mod.fromFn(.{
        .id = "workspace.search",
        .description = "Case-insensitive grep across the workspace; returns relative paths",
        .side_effect = .workspace_read,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}

// ── Workspace tree walker ─────────────────────────────────────────────────────

pub const EntryKind = enum(u8) { directory, file };

/// One node of the workspace tree. `name`/`path` are allocator-owned; `path`
/// is relative to the workspace root and uses `/` separators. `mtime_ns` is
/// the file's last-modified time in nanoseconds (0 for directories) — the
/// file watcher uses it to detect content edits with an unchanged size.
pub const WorkspaceEntry = struct {
    name: []const u8,
    path: []const u8,
    kind: EntryKind,
    size: u64,
    mtime_ns: i128,
};

/// Enumerates the workspace in a single pass, filtering junk directories,
/// skipping binary files by content sniffing is NOT needed here (no reads),
/// and returning entries sorted directory-first, then by path — which is also
/// parent-before-child, so callers can rebuild the hierarchy in one pass.
/// Caller owns the returned slice (and every entry's strings).
pub fn workspaceTree(
    allocator: std.mem.Allocator,
    root: []const u8,
    max_entries: usize,
) ![]WorkspaceEntry {
    const io = std.Io.Threaded.global_single_threaded.io();
    const abs_root = compat.realpathAlloc(allocator, root) catch return error.DirNotFound;
    defer allocator.free(abs_root);

    var dir = try compat.cwd().openDir(io, abs_root, .{ .iterate = true });
    defer dir.close(io);

    var out = compat.ManagedArrayList(WorkspaceEntry).init(allocator);
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        out.deinit();
    }

    try walkTree(allocator, io, dir, "", max_entries, &out);
    std.mem.sort(WorkspaceEntry, out.items, {}, entryLessThan);
    return out.toOwnedSlice();
}

fn entryLessThan(_: void, a: WorkspaceEntry, b: WorkspaceEntry) bool {
    const ak: u8 = if (a.kind == .directory) 0 else 1;
    const bk: u8 = if (b.kind == .directory) 0 else 1;
    if (ak != bk) return ak < bk;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn walkTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    max_entries: usize,
    out: *compat.ManagedArrayList(WorkspaceEntry),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (out.items.len >= max_entries) return;
        if (shouldIgnore(entry.name)) continue;

        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        const name = try allocator.dupe(u8, entry.name);

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                    allocator.free(rel_path);
                    allocator.free(name);
                    continue;
                };
                defer sub.close(io);
                try out.append(.{ .name = name, .path = rel_path, .kind = .directory, .size = 0, .mtime_ns = 0 });
                if (out.items.len >= max_entries) return;
                try walkTree(allocator, io, sub, rel_path, max_entries, out);
            },
            .file => {
                var size: u64 = 0;
                var mtime_ns: i128 = 0;
                if (dir.statFile(io, entry.name, .{})) |st| {
                    if (st.size > 0) size = @intCast(st.size);
                    mtime_ns = st.mtime.nanoseconds;
                } else |_| {}
                try out.append(.{ .name = name, .path = rel_path, .kind = .file, .size = size, .mtime_ns = mtime_ns });
            },
            else => {
                allocator.free(rel_path);
                allocator.free(name);
            },
        }
    }
}

// ── Tests (moved from the IPC server) ─────────────────────────────────────────

const testing = std.testing;

test "workspace.search: finds matches recursively and ignores junk dirs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.zig", .data = "pub fn hello() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "nothing here\n" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/secret.txt", .data = "should be ignored\n" });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deep.zig", .data = "pub fn helloWorld() void {}\n" });

    const hits = try workspaceSearch(testing.allocator, root, "hello", 200, false);
    defer {
        for (hits) |hit| {
            testing.allocator.free(hit.path);
            testing.allocator.free(hit.text);
        }
        testing.allocator.free(hits);
    }

    try testing.expectEqual(@as(usize, 2), hits.len);
    var saw_hello = false;
    var saw_deep = false;
    for (hits) |hit| {
        if (std.mem.endsWith(u8, hit.path, "hello.zig")) {
            saw_hello = true;
            try testing.expectEqual(@as(usize, 1), hit.line);
        }
        if (std.mem.endsWith(u8, hit.path, "deep.zig")) saw_deep = true;
    }
    try testing.expect(saw_hello);
    try testing.expect(saw_deep);
}

test "workspace.search: case-insensitive and respects max_results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "Alpha beta\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "alpha gamma\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "ALPHA delta\n" });

    const hits = try workspaceSearch(testing.allocator, root, "ALPHA", 2, false);
    defer {
        for (hits) |hit| {
            testing.allocator.free(hit.path);
            testing.allocator.free(hit.text);
        }
        testing.allocator.free(hits);
    }
    try testing.expectEqual(@as(usize, 2), hits.len);
}

test "workspace.search: relative mode returns paths under the root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn relSearch() void {}\n" });

    const hits = try workspaceSearch(testing.allocator, root, "relSearch", 50, true);
    defer {
        for (hits) |hit| {
            testing.allocator.free(hit.path);
            testing.allocator.free(hit.text);
        }
        testing.allocator.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/main.zig", hits[0].path);
}

test "workspace.search: agent tool returns a JSON hit array with relative paths" {
    const allocator = testing.allocator;
    const tool = searchWorkspaceTool();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "tool_target.txt", .data = "needleInHaystack\n" });
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(root);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var token = @import("cancel.zig").Token.init(null);
    var sys = @import("clock.zig").SystemClock{};
    var tool_ctx = tool_mod.ToolContext{
        .allocator = arena.allocator(),
        .task_id = 1,
        .agent_id = "test",
        .cancel = &token,
        .clock = sys.clock(),
        .workspace_root = root,
    };

    const result = try tool.invoke(&tool_ctx, "{\"query\":\"needleInHaystack\"}");
    try testing.expect(result.ok);
    try testing.expect(std.mem.indexOf(u8, result.output, "tool_target.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "needleInHaystack") != null);
}

test "workspace.tree: enumerates sorted relative entries with sizes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.txt", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "x" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/secret.txt", .data = "ignored" });

    const entries = try workspaceTree(testing.allocator, root, 5000);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.name);
            testing.allocator.free(e.path);
        }
        testing.allocator.free(entries);
    }

    // All directories first (path order), then all files (path order).
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("src", entries[0].path);
    try testing.expectEqual(EntryKind.directory, entries[0].kind);
    try testing.expectEqualStrings("alpha.txt", entries[1].path);
    try testing.expectEqual(EntryKind.file, entries[1].kind);
    try testing.expectEqual(@as(u64, 1), entries[1].size);
    try testing.expectEqualStrings("src/main.zig", entries[2].path);
    try testing.expectEqual(EntryKind.file, entries[2].kind);
    try testing.expectEqual(@as(u64, 21), entries[2].size);
    try testing.expectEqualStrings("zeta.txt", entries[3].path);
    try testing.expectEqual(@as(u64, 5), entries[3].size);
    // Junk dirs are excluded.
    for (entries) |e| try testing.expect(!std.mem.startsWith(u8, e.path, ".git"));
}

test "workspace.tree: respects max_entries cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "2" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "3" });

    const entries = try workspaceTree(testing.allocator, root, 2);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.name);
            testing.allocator.free(e.path);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
}
