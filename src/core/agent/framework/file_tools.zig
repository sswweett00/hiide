/// File I/O tools for agents: read, write, list, and targeted diff edits.
const std = @import("std");
const compat = @import("../../compat.zig");
const tool_mod = @import("tool.zig");

/// Accepts either a raw path string (framework convention) or a JSON object
/// `{"path": "..."}` (uniform tool-input convention used over IPC). Returns
/// the workspace-resolved path; caller owns the buffer.
fn resolvePathInput(ctx: *tool_mod.ToolContext, input: []const u8) anyerror![]u8 {
    if (input.len > 0 and input[0] == '{') {
        var parsed = try std.json.parseFromSlice(struct {
            path: []const u8 = ".",
        }, ctx.allocator, input, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return ctx.resolveWorkspacePath(parsed.value.path);
    }
    return ctx.resolveWorkspacePath(input);
}

/// Reads a file from the workspace.
pub fn readFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const path = try resolvePathInput(ctx, input);
            defer ctx.allocator.free(path);

            const content = compat.cwd().readFileAlloc(ctx.allocator, path, 10 * 1024 * 1024) catch {
                return tool_mod.ToolResult.failure(
                    try std.fmt.allocPrint(ctx.allocator, "file not found: {s}", .{path}),
                );
            };
            return tool_mod.ToolResult.success(content);
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.read",
        .description = "Read a file from the workspace",
        .side_effect = .workspace_read,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
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

            const path = try ctx.resolveWorkspacePath(parsed.value.path);
            defer allocator.free(path);

            if (std.fs.path.dirname(path)) |dir_path| {
                compat.cwd().makePath(dir_path) catch {};
            }

            var file = try compat.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(parsed.value.content);
            const out = try std.fmt.allocPrint(allocator, "{{\"written\":true,\"size\":{d}}}", .{parsed.value.content.len});
            return tool_mod.ToolResult.success(out);
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.write",
        .description = "Write content to a file in the workspace (creates parent directories if needed)",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}

/// Replaces the first occurrence of `target` with `replacement` in a file.
/// Input: `{"path": "...", "target": "...", "replacement": "..."}`.
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

            const path = try ctx.resolveWorkspacePath(parsed.value.path);
            defer allocator.free(path);

            const content = compat.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
                return tool_mod.ToolResult.failure(
                    try std.fmt.allocPrint(allocator, "file not found: {s}", .{path}),
                );
            };
            defer allocator.free(content);

            const idx = std.mem.indexOf(u8, content, parsed.value.target) orelse {
                return tool_mod.ToolResult.failure(
                    try std.fmt.allocPrint(allocator, "target text not found in {s}; read the file first and retry with the exact text", .{path}),
                );
            };

            const new_len = content.len - parsed.value.target.len + parsed.value.replacement.len;
            const new_content = try allocator.alloc(u8, new_len);
            defer allocator.free(new_content);
            @memcpy(new_content[0..idx], content[0..idx]);
            @memcpy(new_content[idx .. idx + parsed.value.replacement.len], parsed.value.replacement);
            @memcpy(new_content[idx + parsed.value.replacement.len ..], content[idx + parsed.value.target.len ..]);

            var file = try compat.cwd().createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(new_content);
            return tool_mod.ToolResult.success("{\"applied\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.apply_diff",
        .description = "Replace the first occurrence of an exact target string in a workspace file",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}

/// Lists files in a directory as a JSON array of `{"name","kind"}` entries.
/// `kind` is `"directory"` or `"file"`.
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
                return tool_mod.ToolResult.failure(
                    try std.fmt.allocPrint(allocator, "directory not found: {s}", .{path}),
                );
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
            while (try iter.next()) |entry| {
                const kind: []const u8 = if (entry.kind == .directory) "directory" else "file";
                try entries.append(.{
                    .name = try allocator.dupe(u8, entry.name),
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

            // Try deleting as a single file first
            compat.cwd().deleteFile(path) catch {
                // If it failed, attempt deleting as a directory tree
                compat.cwd().deleteTree(path) catch {
                    return tool_mod.ToolResult.failure(
                        try std.fmt.allocPrint(allocator, "failed to delete file or directory: {s}", .{path}),
                    );
                };
            };

            return tool_mod.ToolResult.success("{\"deleted\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.delete",
        .description = "Delete a file or directory in the workspace",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
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
                    try std.fmt.allocPrint(allocator, "failed to create directory {s}: {s}", .{ path, @errorName(err) }),
                );
            };

            return tool_mod.ToolResult.success("{\"created\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.mkdir",
        .description = "Create a directory in the workspace (creates parent directories if needed)",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}
