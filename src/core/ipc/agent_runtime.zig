/// Bridges the IPC server to the agent framework's tool registry.
///
/// The Flutter frontend keeps the agent loop (LLM calls, message history) but
/// every tool it needs — file read/write/diff/list, process execution, and
/// workspace grep — is executed here, inside the Zig engine, through the
/// framework's `Tool`/`ToolContext` machinery. That gives the engine ownership
/// of the workspace sandbox (`resolveInWorkspace`) and the side-effect
/// taxonomy declared on each `ToolSpec`.
const std = @import("std");
const tool_mod = @import("../agent/framework/tool.zig");
const file_tools = @import("../agent/framework/file_tools.zig");
const process_tools = @import("../agent/framework/process_tools.zig");
const workspace_tools = @import("../agent/framework/workspace_tools.zig");
const cancel_mod = @import("../agent/framework/cancel.zig");
const clock_mod = @import("../agent/framework/clock.zig");

/// Result of one tool invocation, with allocator-owned strings.
pub const ToolResponse = struct {
    ok: bool,
    output: []const u8,
    error_message: []const u8,
};

var registry: tool_mod.Registry = undefined;
var registry_ready = std.once(initRegistry);

fn initRegistry() void {
    registry = tool_mod.Registry.init(std.heap.c_allocator);
    registry.register(file_tools.readFileTool()) catch {};
    registry.register(file_tools.writeFileTool()) catch {};
    registry.register(file_tools.deleteFileTool()) catch {};
    registry.register(file_tools.createDirectoryTool()) catch {};
    registry.register(file_tools.applyDiffTool()) catch {};
    registry.register(file_tools.listFilesTool()) catch {};
    registry.register(process_tools.processRunTool()) catch {};
    registry.register(workspace_tools.searchWorkspaceTool()) catch {};
}

fn approvalGranted(allocator: std.mem.Allocator, input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("approved") orelse return false;
    return value == .bool and value.bool;
}

/// Executes `tool_id` with the JSON-encoded `input` against `workspace_root`.
/// `timeout_ms` becomes the invocation deadline (the process tool turns it
/// into its watchdog kill). `output`/`error_message` are owned by `allocator`.
pub fn executeTool(
    allocator: std.mem.Allocator,
    tool_id: []const u8,
    input: []const u8,
    workspace_root: []const u8,
    timeout_ms: ?u32,
) !ToolResponse {
    registry_ready.call();

    const tool = registry.get(tool_id) orelse return error.ToolNotFound;

    // Per-invocation arena: the framework contract is that tool output lives
    // in the caller-provided arena, so we dupe it into the response allocator
    // before the arena is torn down.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var sys_clock = clock_mod.SystemClock{};
    const clock = sys_clock.clock();
    const deadline: ?i64 = if (timeout_ms) |ms| clock.deadlineIn(ms) else null;
    var token = cancel_mod.Token.init(deadline);

    var tool_ctx = tool_mod.ToolContext{
        .allocator = arena.allocator(),
        .task_id = 0,
        .agent_id = "ipc-agent",
        .cancel = &token,
        .clock = clock,
        .workspace_root = workspace_root,
    };

    const result = tool.invoke(&tool_ctx, input) catch |err| {
        return ToolResponse{
            .ok = false,
            .output = try allocator.dupe(u8, ""),
            .error_message = try allocator.dupe(u8, @errorName(err)),
        };
    };

    if (!result.ok) {
        return ToolResponse{
            .ok = false,
            .output = try allocator.dupe(u8, result.output),
            .error_message = try allocator.dupe(u8, result.error_message),
        };
    }
    return ToolResponse{
        .ok = true,
        .output = try allocator.dupe(u8, result.output),
        .error_message = try allocator.dupe(u8, ""),
    };
}

test "agent runtime: unknown tool is rejected" {
    try std.testing.expectError(
        error.ToolNotFound,
        executeTool(std.testing.allocator, "nope.tool", "{}", ".", null),
    );
}

test "agent runtime: file.write + file.read round trip inside the workspace" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(root);

    const write = try executeTool(
        allocator,
        "file.write",
        "{\"path\":\"out.txt\",\"content\":\"runtime-works\"}",
        root,
        null,
    );
    defer {
        allocator.free(write.output);
        allocator.free(write.error_message);
    }
    try std.testing.expect(write.ok);

    const read = try executeTool(
        allocator,
        "file.read",
        "out.txt",
        root,
        null,
    );
    defer {
        allocator.free(read.output);
        allocator.free(read.error_message);
    }
    try std.testing.expect(read.ok);
    try std.testing.expect(std.mem.indexOf(u8, read.output, "runtime-works") != null);
}

test "agent runtime: path escaping the workspace is rejected" {
    const allocator = std.testing.allocator;

    const result = try executeTool(
        allocator,
        "file.read",
        "../../etc/passwd",
        ".",
        null,
    );
    defer {
        allocator.free(result.output);
        allocator.free(result.error_message);
    }
    try std.testing.expect(!result.ok);
}

test "agent runtime: file.mkdir, nested file.write and file.delete" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(root);

    // 1. mkdir
    const mkdir = try executeTool(
        allocator,
        "file.mkdir",
        "{\"path\":\"nested/folder\"}",
        root,
        null,
    );
    defer {
        allocator.free(mkdir.output);
        allocator.free(mkdir.error_message);
    }
    try std.testing.expect(mkdir.ok);

    // 2. nested write (including auto parent dir creation)
    const write = try executeTool(
        allocator,
        "file.write",
        "{\"path\":\"nested/folder/deleteme.txt\",\"content\":\"to-be-deleted\"}",
        root,
        null,
    );
    defer {
        allocator.free(write.output);
        allocator.free(write.error_message);
    }
    try std.testing.expect(write.ok);

    // 3. delete file
    const del_file = try executeTool(
        allocator,
        "file.delete",
        "{\"path\":\"nested/folder/deleteme.txt\"}",
        root,
        null,
    );
    defer {
        allocator.free(del_file.output);
        allocator.free(del_file.error_message);
    }
    try std.testing.expect(del_file.ok);

    // Verify it is gone
    const read_after_del = try executeTool(
        allocator,
        "file.read",
        "nested/folder/deleteme.txt",
        root,
        null,
    );
    defer {
        allocator.free(read_after_del.output);
        allocator.free(read_after_del.error_message);
    }
    try std.testing.expect(!read_after_del.ok);

    // 4. delete directory
    const del_dir = try executeTool(
        allocator,
        "file.delete",
        "{\"path\":\"nested\"}",
        root,
        null,
    );
    defer {
        allocator.free(del_dir.output);
        allocator.free(del_dir.error_message);
    }
    try std.testing.expect(del_dir.ok);
}

test "agent runtime: dangerous tools require an explicit approval token" {
    const denied = try executeTool(
        std.testing.allocator,
        "process.run",
        "{\"command\":\"printf denied\"}",
        ".",
        5_000,
    );
    defer {
        std.testing.allocator.free(denied.output);
        std.testing.allocator.free(denied.error_message);
    }
    try std.testing.expect(!denied.ok);
    try std.testing.expectEqualStrings("approval_required", denied.error_message);

    const approved = try executeTool(
        std.testing.allocator,
        "process.run",
        "{\"command\":\"printf approved\",\"approved\":true}",
        ".",
        5_000,
    );
    defer {
        std.testing.allocator.free(approved.output);
        std.testing.allocator.free(approved.error_message);
    }
    try std.testing.expect(approved.ok);
    try std.testing.expectEqualStrings("approved", std.mem.trim(u8, approved.output, " \r\n"));
}

