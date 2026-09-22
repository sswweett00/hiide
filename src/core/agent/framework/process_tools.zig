/// Process execution tool for agents: runs a shell command in the workspace
/// and returns its combined stdout + stderr so the agent can react to output.
///
/// The command runs under `bash -c` with the workspace root as the working
/// directory. Uses raw Linux syscalls via `compat.runCommand` to avoid the
/// `std.process.Child` API that changed in Zig 0.17.
const std = @import("std");
const compat = @import("../../compat.zig");
const tool_mod = @import("tool.zig");

const default_timeout_ms: u32 = 120_000;

/// Runs `bash -c <command>` in the workspace root.
/// Input: `{"command": "...", "timeout_ms"?: <optional override>}`.
/// Output: combined stdout + stderr (may be empty).
pub fn processRunTool() tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            const allocator = ctx.allocator;

            var parsed = try std.json.parseFromSlice(struct {
                command: []const u8,
                timeout_ms: ?u32 = null,
            }, allocator, input, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            if (parsed.value.command.len == 0) {
                return tool_mod.ToolResult.failure("no command provided");
            }

            // Use compat.runCommand which handles fork/exec/pipe/wait via raw
            // Linux syscalls, avoiding the std.process.Child API that changed
            // in Zig 0.17.
            const requested_timeout = parsed.value.timeout_ms orelse default_timeout_ms;
            const timeout_ms = @min(requested_timeout, 10 * 60 * 1000);
            if (timeout_ms == 0) return tool_mod.ToolResult.failure("timeout_ms must be greater than zero");

            var result = compat.runCommandWithTimeout(allocator, &.{ "bash", "-c", parsed.value.command }, timeout_ms) catch |err| {
                return tool_mod.ToolResult.failure(@errorName(err));
            };
            defer result.deinit(allocator);

            // Build the combined, trimmed output the model will see.
            const out_trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            const err_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");

            var combined = compat.ManagedArrayList(u8).init(allocator);
            defer combined.deinit();
            if (out_trimmed.len > 0) try combined.appendSlice(out_trimmed);
            if (err_trimmed.len > 0) {
                if (combined.items.len > 0) try combined.append('\n');
                try combined.appendSlice(err_trimmed);
            }
            if (combined.items.len == 0) {
                try combined.appendSlice("(command completed with no output)");
            }

            const output = try combined.toOwnedSlice();
            if (result.timed_out) {
                return .{ .ok = false, .output = output, .error_message = "command timed out" };
            }
            if (!result.success) {
                return .{ .ok = false, .output = output, .error_message = "command failed" };
            }
            return tool_mod.ToolResult.success(output);
        }
    };
    return tool_mod.fromFn(.{
        .id = "process.run",
        .description = "Run a shell command in the workspace and return its output",
        .side_effect = .process_exec,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
        .timeout_ms = default_timeout_ms,
        .input_schema = "{\"type\":\"object\",\"required\":[\"command\"],\"properties\":{\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":600000}}}",
        .owner = "core",
    }, Impl.invoke);
}

test "process.run: echoes output from the workspace directory" {
    const allocator = std.testing.allocator;
    const tool = processRunTool();

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
        .workspace_root = ".",
    };

    const result = try tool.invoke(&tool_ctx, "{\"command\":\"echo framework-process-ok\"}");
    try std.testing.expect(result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "framework-process-ok") != null);
}

test "process.run: reports failure for bad commands" {
    const allocator = std.testing.allocator;
    const tool = processRunTool();

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
        .workspace_root = ".",
    };

    const result = try tool.invoke(&tool_ctx, "{\"command\":\"exit 1\"}");
    try std.testing.expect(!result.ok);
}


test "process.run: enforces the execution timeout" {
    const allocator = std.testing.allocator;
    const tool = processRunTool();

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
        .workspace_root = ".",
    };

    const started = compat.milliTimestamp();
    const result = try tool.invoke(&tool_ctx, "{\"command\":\"sleep 1\",\"timeout_ms\":20}");
    const elapsed = compat.milliTimestamp() - started;

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("command timed out", result.error_message);
    try std.testing.expect(elapsed < 900);
}
