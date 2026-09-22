/// Sandboxed file tools used by agents.
const std = @import("std");
const compat = @import("../../compat.zig");
const tool_mod = @import("tool.zig");
const ToolResult = tool_mod.ToolResult;

const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;
const MAX_LIST_ENTRIES: usize = 10_000;

fn rawPathInput(ctx: *tool_mod.ToolContext, input: []const u8) ![]u8 {
    if (input.len > 0 and input[0] == '{') {
        var parsed = try std.json.parseFromSlice(struct { path: []const u8 = "." }, ctx.allocator, input, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return ctx.allocator.dupe(u8, parsed.value.path);
    }
    return ctx.allocator.dupe(u8, input);
}

fn rejectUnsafePath(ctx: *tool_mod.ToolContext, relative_path: []const u8) !void {
    if (relative_path.len == 0) return tool_mod.ToolError.ToolInputInvalid;
    if (std.fs.path.isAbsolute(relative_path)) return tool_mod.ToolError.PathEscapesWorkspace;
    if (std.mem.indexOfScalar(u8, relative_path, 0) != null) return tool_mod.ToolError.ToolInputInvalid;
    if (relative_path.len >= 2 and relative_path[1] == ':') return tool_mod.ToolError.PathEscapesWorkspace;
    if (std.mem.startsWith(u8, relative_path, "\\\\")) return tool_mod.ToolError.PathEscapesWorkspace;

    var depth: isize = 0;
    var parts = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return tool_mod.ToolError.PathEscapesWorkspace;
        } else {
            depth += 1;
        }
    }

    // Reject symlink components that already exist. This prevents a normal
    // workspace path from becoming an obvious symlink-based escape.
    const io = std.Io.Threaded.global_single_threaded.io();
    var current = try compat.cwd().openDir(io, ctx.workspace_root, .{ .iterate = true });
    defer current.close(io);

    parts = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        var found = false;
        var iter = current.iterate();
        while (try iter.next(io)) |entry| {
            if (!std.mem.eql(u8, entry.name, part)) continue;
            found = true;
            if (entry.kind == .sym_link) return tool_mod.ToolError.PathEscapesWorkspace;
            if (parts.peek() != null) {
                if (entry.kind != .directory) return tool_mod.ToolError.ToolInputInvalid;
                const next = try current.openDir(io, entry.name, .{ .iterate = true });
                current.close(io);
                current = next;
            }
            break;
        }
        if (!found) break;
    }
}

fn resolvePathInput(ctx: *tool_mod.ToolContext, input: []const u8) ![]u8 {
    const raw = try rawPathInput(ctx, input);
    defer ctx.allocator.free(raw);
    try rejectUnsafePath(ctx, raw);
    return ctx.resolveWorkspacePath(raw);
}

pub fn readFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const path = try resolvePathInput(ctx, input);
            defer ctx.allocator.free(path);
            const content = compat.cwd().readFileAlloc(ctx.allocator, path, MAX_FILE_BYTES) catch {
                return ToolResult.failure("file could not be read inside workspace");
            };
            return ToolResult.success(content);
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.read",
        .description = "Read a file from the workspace",
        .side_effect = .workspace_read,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .max_input_bytes = 1 << 20,
        .owner = "core",
    }, Impl.invoke);
}

pub fn writeFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const allocator = ctx.allocator;
            var parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.content.len > MAX_FILE_BYTES) return ToolResult.failure("file content exceeds 10 MiB limit");

            const path = try resolvePathInput(ctx, parsed.value.path);
            defer allocator.free(path);
            if (std.fs.path.dirname(path)) |dir_path| {
                compat.cwd().makePath(dir_path) catch return ToolResult.failure("unable to create workspace parent directory");
            }
            // Re-check before writing to reduce symlink TOCTOU risk.
            try rejectUnsafePath(ctx, parsed.value.path);
            var file = compat.cwd().createFile(path, .{}) catch return ToolResult.failure("unable to open workspace file for write");
            defer file.close();
            try file.writeAll(parsed.value.content);
            const response = try std.fmt.allocPrint(allocator, "{{\"written\":true,\"size\":{d}}}", .{parsed.value.content.len});
            return ToolResult.success(response);
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.write",
        .description = "Write content to a file in the workspace",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\",\"content\"],\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}",
        .max_input_bytes = 12 * 1024 * 1024,
        .owner = "core",
    }, Impl.invoke);
}

pub fn applyDiffTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const allocator = ctx.allocator;
            var parsed = try std.json.parseFromSlice(struct { path: []const u8, target: []const u8, replacement: []const u8 }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.target.len == 0) return ToolResult.failure("diff target must not be empty");
            const path = try resolvePathInput(ctx, parsed.value.path);
            defer allocator.free(path);
            const content = compat.cwd().readFileAlloc(allocator, path, MAX_FILE_BYTES) catch return ToolResult.failure("file could not be read inside workspace");
            defer allocator.free(content);

            const idx = std.mem.indexOf(u8, content, parsed.value.target) orelse return ToolResult.failure("target text not found");
            const second = std.mem.indexOfPos(u8, content, idx + parsed.value.target.len, parsed.value.target);
            if (second != null) return ToolResult.failure("target text is ambiguous; use a more specific patch");

            const new_len = content.len - parsed.value.target.len + parsed.value.replacement.len;
            if (new_len > MAX_FILE_BYTES) return ToolResult.failure("resulting file exceeds 10 MiB limit");
            const new_content = try allocator.alloc(u8, new_len);
            defer allocator.free(new_content);
            @memcpy(new_content[0..idx], content[0..idx]);
            @memcpy(new_content[idx .. idx + parsed.value.replacement.len], parsed.value.replacement);
            @memcpy(new_content[idx + parsed.value.replacement.len ..], content[idx + parsed.value.target.len ..]);

            var file = compat.cwd().createFile(path, .{ .truncate = true }) catch return ToolResult.failure("unable to open workspace file for patch");
            defer file.close();
            try file.writeAll(new_content);
            return ToolResult.success("{\"applied\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.apply_diff",
        .description = "Replace exactly one occurrence of an exact target string",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\",\"target\",\"replacement\"],\"properties\":{\"path\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}}}",
        .max_input_bytes = 12 * 1024 * 1024,
        .owner = "core",
    }, Impl.invoke);
}

pub fn listFilesTool() tool_mod.Tool {
    const Entry = struct { name: []const u8, kind: []const u8 };
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const allocator = ctx.allocator;
            const path = if (input.len == 0 or std.mem.eql(u8, input, ".")) try allocator.dupe(u8, ".") else try resolvePathInput(ctx, input);
            defer allocator.free(path);
            var dir = compat.cwd().openDir(path, .{ .iterate = true }) catch return ToolResult.failure("directory not found inside workspace");
            defer dir.close();
            var entries = compat.ManagedArrayList(Entry).init(allocator);
            defer {
                for (entries.items) |e| { allocator.free(e.name); allocator.free(e.kind); }
                entries.deinit();
            }
            var iter = dir.iterate();
            while (entries.items.len < MAX_LIST_ENTRIES) {
                const entry = try iter.next() orelse break;
                const kind: []const u8 = if (entry.kind == .directory) "directory" else if (entry.kind == .sym_link) "symlink" else "file";
                try entries.append(.{ .name = try allocator.dupe(u8, entry.name), .kind = try allocator.dupe(u8, kind) });
            }
            var output = compat.ManagedArrayList(u8).init(allocator);
            defer output.deinit();
            try std.json.stringify(entries.items, .{}, output.writer());
            return ToolResult.success(try output.toOwnedSlice());
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

pub fn deleteFileTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const allocator = ctx.allocator;
            const path = try resolvePathInput(ctx, input);
            defer allocator.free(path);
            if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return ToolResult.failure("cannot delete workspace root");
            compat.cwd().deleteFile(path) catch {
                compat.cwd().deleteTree(path) catch return ToolResult.failure("failed to delete workspace path");
            };
            return ToolResult.success("{\"deleted\":true}");
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

pub fn createDirectoryTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) !ToolResult {
            const allocator = ctx.allocator;
            const path = try resolvePathInput(ctx, input);
            defer allocator.free(path);
            compat.cwd().makePath(path) catch |err| return ToolResult.failure(try std.fmt.allocPrint(allocator, "failed to create workspace directory: {s}", .{@errorName(err)}));
            return ToolResult.success("{\"created\":true}");
        }
    };
    return tool_mod.fromFn(.{
        .id = "file.mkdir",
        .description = "Create a directory in the workspace",
        .side_effect = .workspace_write,
        .input_schema = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .owner = "core",
    }, Impl.invoke);
}
