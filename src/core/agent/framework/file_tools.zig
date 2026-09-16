/// File I/O tools for agents: read, write, list, and targeted diff edits.
const std = @import("std");
const compat = @import("../../compat.zig");
const tool_mod = @import("tool.zig");

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;
const MAX_LIST_ENTRIES: usize = 10_000;
const MAX_DIFF_BYTES: usize = 10 * 1024 * 1024;

fn rawPathInput(ctx: *tool_mod.ToolContext, input: []const u8) anyerror![]const u8 {
    if (input.len > 0 and input[0] == '{') {
        var parsed = try std.json.parseFromSlice(struct {
            path: []const u8 = ".",
        }, ctx.allocator, input, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return try ctx.allocator.dupe(u8, parsed.value.path);
    }
    return try ctx.allocator.dupe(u8, input);
}

/// Rejects symlink components before an agent tool accesses the path. This
/// closes the common "workspace path -> symlink -> outside workspace" escape
/// while keeping the workspace root itself trusted and configurable.
fn rejectSymlinkComponents(ctx: *tool_mod.ToolContext, relative_path: []const u8) anyerror!void {
    if (relative_path.len == 0) return tool_mod.ToolError.ToolInputInvalid;
    if (std.fs.path.isAbsolute(relative_path)) return tool_mod.ToolError.PathEscapesWorkspace;
    if (std.mem.indexOfScalar(u8, relative_path, 0) != null) return tool_mod.ToolError.ToolInputInvalid;
    if (relative_path.len >= 2 and relative_path[1] == ':') return tool_mod.ToolError.PathEscapesWorkspace;
    if (std.mem.startsWith(u8, relative_path, "\\\\")) return tool_mod.ToolError.PathEscapesWorkspace;

    const io = std.Io.Threaded.global_single_threaded.io();
    var current = try compat.cwd().openDir(io, ctx.workspace_root, .{ .iterate = true });
    defer current.close(io);

    var segments = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return tool_mod.ToolError.PathEscapesWorkspace;

        var found = false;
        var iter = current.iterate();
        while (try iter.next(io)) |entry| {
            if (!std.mem.eql(u8, entry.name, segment)) continue;
            found = true;
            if (entry.kind == .sym_link) return tool_mod.ToolError.PathEscapesWorkspace;
            if (segments.peek() != null) {
                if (entry.kind != .directory) return tool_mod.ToolError.ToolInputInvalid;
                const next = try current.openDir(io, entry.name, .{ .iterate = true });
                current.close(io);
                current = next;
            }
            break;
        }

        // A missing final component is valid for file.write/file.mkdir.
        if (!found) break;
    }
}

/// Accepts either a raw path string (framework convention) or a JSON object
/// `{"path": "..."}` (uniform tool-input convention used over IPC). Returns
/// the workspace-resolved path only after path and symlink validation.
fn resolvePathInput(ctx: *tool_mod.ToolContext, input: []const u8) anyerror![]u8 {
    const raw = try rawPathInput(ctx, input);
    defer ctx.allocator.free(raw);
    try rejectSymlinkComponents(ctx, raw);
    return ctx.resolveWorkspacePath(raw);
}

/// Reads a file from the workspace.
pub fn readFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const path = try resolvePathInput(ctx, input);
            defer ctx.allocator.free(path);

            const content = compat.cwd().readFileAlloc(ctx.allocator, path, MAX_FILE_BYTES) catch {
                return tool_mod.ToolResult.failure("file could not be read inside workspace");
            };
            return tool_mod.ToolResult.success(content);
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.read",
        .description = "Read a file from the workspace",
        .side_effect = .workspace_read,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"maxLength\":10485760}}}",
        .max_input_bytes = 1 << 20,
        .owner = "core",
    }, Impl.invoke);
}

/// Writes content to a file in the workspace (create or overwrite).
pub fn writeFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;

            var parsed = try std.json.parseFromSlice(struct {
                path: []const u8,
                content: []const u8,
            }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            if (parsed.value.content.len > MAX_FILE_BYTES) {
                return tool_mod.ToolResult.failure("file content exceeds 10 MiB limit");
            }

            const path = try resolvePathInput(ctx, parsed.value.path);
            defer allocator.free(path);

            if (std.fs.path.dirname(path)) |dir_path| {
                compat.cwd().makePath(dir_path) catch {
                    return tool_mod.ToolResult.failure("unable to create workspace parent directory");
                };
            }

            // Refuse to follow a symlink that may have been created after the
            // preflight. If an existing target is a symlink, do not overwrite it.
            try rejectSymlinkComponents(ctx, parsed.value.path);

            var file = compat.cwd().createFile(path, .{} ) catch {
                return tool_mod.ToolResult.failure("unable to open workspace file for write");
            };
            defer file.close();
            try file.writeAll(parsed.value.content);
            return ToolResult.success("{\"written\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.write",
        .description = "Write content to a file in the workspace (creates parent directories if needed)",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\",\"content\"],\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\",\"maxLength\":10485760}}}",
        .max_input_bytes = 12 * 1024 * 1024,
        .owner = "core",
    }, Impl.invoke);
}

/// Replaces exactly one occurrence of `target` in a file.
/// Ambiguous patches are rejected instead of silently changing the first match.
pub fn applyDiffTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;

            var parsed = try std.json.parseFromSlice(struct {
                path: []const u8,
                target: []const u8,
                replacement: []const u8,
            }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            if (parsed.value.target.len == 0) return tool_mod.ToolResult.failure("diff target must not be empty");
            if (parsed.value.target.len > MAX_DIFF_BYTES or parsed.value.replacement.len > MAX_DIFF_BYTES) {
                return tool_mod.ToolResult.failure("diff payload exceeds 10 MiB limit");
            }

            const path = try resolvePathInput(ctx, parsed.value.path);
            defer allocator.free(path);

            const content = compat.cwd().readFileAlloc(allocator, path, MAX_FILE_BYTES) catch {
                return tool_mod.ToolResult.failure("file could not be read inside workspace");
            };
            defer allocator.free(content);

            const first = std.mem.indexOf(u8, content, parsed.value.target) orelse {
                return tool_mod.ToolResult.failure("target text not found; read the file first and retry with the exact text");
            };
            const after_first = first + parsed.value.target.len;
            if (std.mem.indexOfPos(u8, content, after_first, parsed.value.target) != null) {
                return tool_mod.ToolResult.failure("target text is ambiguous; use a more specific patch");
            }

            const new_len = content.len - parsed.value.target.len + parsed.value.replacement.len;
            if (new_len > MAX_FILE_BYTES) return tool_mod.ToolResult.failure("resulting file exceeds 10 MiB limit");

            const new_content = try allocator.alloc(u8, new_len);
            defer allocator.free(new_content);
            @memcpy(new_content[0..first], content[0..first]);
            @memcpy(new_content[first .. first + parsed.value.replacement.len], parsed.value.replacement);
            @memcpy(new_content[first + parsed.value.replacement.len ..], content[after_first..]);

            var file = compat.cwd().createFile(path, .{ .truncate = true }) catch {
                return tool_mod.ToolResult.failure("unable to open workspace file for patch");
            };
            defer file.close();
            try file.writeAll(new_content);
            return tool_mod.ToolResult.success("{\"applied\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.apply_diff",
        .description = "Replace exactly one occurrence of an exact target string in a workspace file",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\",\"target\",\"replacement\"],\"properties\":{\"path\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}}}",
        .max_input_bytes = 12 * 1024 * 1024,
        .owner = "core",
    }, Impl.invoke);
}

/// Lists files in a directory as a JSON array of `{"name","kind"}` entries.
pub fn listFilesTool() tool_mod.Tool {
    const Entry = struct { name: []const u8, kind: []const u8 };

    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;
            const path = if (input.len == 0 or std.mem.eql(u8, input, "."))
                try allocator.dupe(u8, ".")
            else
                try resolvePathInput(ctx, input);
            defer allocator.free(path);

            var dir = compat.cwd().openDir(path, .{ .iterate = true }) catch {
                return tool_mod.ToolResult.failure("directory not found inside workspace");
            };
            defer dir.close();

            var entries = compat.ManagedArrayList(Entry).init(allocator);
            defer {
                for (entries.items) |e| {
                    allocator.free(e.name);
                    allocator.free(e.kind);
                }
                entries.deinit();
            }

            var iter = dir.iterate();
            while (entries.items.len < MAX_LIST_ENTRIES) {
                const next = try iter.next() orelse break;
                const kind: []const u8 = if (next.kind == .directory) "directory" else if (next.kind == .sym_link) "symlink" else "file";
                try entries.append(.{
                    .name = try allocator.dupe(u8, next.name),
                    .kind = try allocator.dupe(u8, kind),
                });
            }

            var output = compat.ManagedArrayList(u8).init(allocator);
            defer output.deinit();
            try std.json.stringify(entries.items, .{}, output.writer());
            return tool_mod.ToolResult.success(try output.toOwnedSlice());
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.list",
        .description = "List files in a directory",
        .side_effect = .workspace_read,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}

/// Deletes a file or directory in the workspace.
pub fn deleteFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;
            const path = try resolvePathInput(ctx, input);
            defer allocator.free(path);

            if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) {
                return tool_mod.ToolResult.failure("cannot delete workspace root");
            }

            compat.cwd().deleteFile(path) catch {
                compat.cwd().deleteTree(path) catch {
                    return tool_mod.ToolResult.failure("failed to delete file or directory inside workspace");
                };
            };

            return tool_mod.ToolResult.success("{\"deleted\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.delete",
        .description = "Delete a file or directory in the workspace",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}

/// Creates a directory in the workspace (including parent directories).
pub fn createDirectoryTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;
            const path = try resolvePathInput(ctx, input);
            defer allocator.free(path);

            compat.cwd().makePath(path) catch |err| {
                return tool_mod.ToolResult.failure(
                    try std.fmt.allocPrint(allocator, "failed to create workspace directory: {s}", .{@errorName(err)}),
                );
            };

            return tool_mod.ToolResult.success("{\"created\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.mkdir",
        .description = "Create a directory in the workspace (creates parent directories if needed)",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}
