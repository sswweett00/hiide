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
const compat = @import("../compat.zig");
const context_mod = @import("../agent/framework/context.zig");
const types = @import("../agent/types.zig");
const journal_mod = @import("../agent/journal.zig");
const blackboard_mod = @import("../agent/framework/blackboard.zig");
const policy_mod = @import("../security/policy.zig");
const telemetry_mod = @import("../telemetry/collector.zig");
const approval_mod = @import("../agent/framework/approval.zig");
const budget_mod = @import("../agent/framework/budget.zig");
const classifier = @import("../security/classifier.zig");

/// Result of one tool invocation, with allocator-owned strings.
pub const ToolResponse = struct {
    ok: bool,
    output: []const u8,
    error_message: []const u8,
};

var registry: tool_mod.Registry = undefined;
var registry_mutex: compat.Mutex = .init;
var registry_initialized = std.atomic.Value(bool).init(false);

fn initRegistry() !void {
    registry = tool_mod.Registry.init(std.heap.c_allocator);
    try registry.register(file_tools.readFileTool());
    try registry.register(file_tools.writeFileTool());
    try registry.register(file_tools.deleteFileTool());
    try registry.register(file_tools.createDirectoryTool());
    try registry.register(file_tools.applyDiffTool());
    try registry.register(file_tools.listFilesTool());
    try registry.register(process_tools.processRunTool());
    try registry.register(workspace_tools.searchWorkspaceTool());
}

fn approvalGranted(allocator: std.mem.Allocator, input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("approved") orelse return false;
    return switch (value) { .bool => |flag| flag, else => false };
}

fn ensureRegistry() !void {
    if (registry_initialized.load(.acquire)) return;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (registry_initialized.load(.acquire)) return;
    try initRegistry();
    registry_initialized.store(true, .release);
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
    try ensureRegistry();

    const tool = registry.get(tool_id) orelse return error.ToolNotFound;
    const needs_approval = tool.spec.needsApproval();
    if (needs_approval and !approvalGranted(allocator, input)) {
        return ToolResponse{
            .ok = false,
            .output = try allocator.dupe(u8, ""),
            .error_message = try allocator.dupe(u8, "approval_required"),
        };
    }

    // The IPC boundary must use the same mediation pipeline as the native
    // executor. Direct Tool.invoke bypasses classification, policy, approval,
    // journaling, telemetry, and audit; keeping that path alive would make the
    // security contract dependent on the caller behaving honestly.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var board = blackboard_mod.Blackboard.init(allocator, clock_mod.system());
    defer board.deinit();

    var journal = journal_mod.SideEffectJournal.init(allocator);
    defer journal.deinit();

    var policy = policy_mod.PolicyEngine.init(allocator);
    defer policy.deinit();
    try policy.loadDefaults();

    var ledger = policy_mod.AuditLedger.init(allocator);
    defer ledger.deinit();

    var telemetry = telemetry_mod.TelemetrySink.init(allocator, .basic);
    defer telemetry.deinit();

    // IPC has already received the explicit approval token for dangerous
    // operations, so the gate itself is deterministic and never waits on a UI
    // thread. Policy/classifier still decides whether the operation is legal.
    var gate = approval_mod.Gate.init(
        allocator,
        clock_mod.system(),
        .auto_approve,
    );
    defer gate.deinit();

    var sys_clock = clock_mod.SystemClock{};
    const clock = sys_clock.clock();
    const deadline: ?i64 = if (timeout_ms) |ms| clock.deadlineIn(ms) else null;
    var token = cancel_mod.Token.init(deadline);
    var meter = budget_mod.Meter.init(types.TokenBudget.defaultPlanning());

    var services = context_mod.Services{
        .allocator = allocator,
        .clock = clock,
        .board = &board,
        .tools = &registry,
        .journal = &journal,
        .policy = &policy,
        .ledger = &ledger,
        .telemetry = &telemetry,
        .approvals = &gate,
        .workspace_root = workspace_root,
        .identity = .{
            .user_id = "ipc-agent",
            .workspace_id = workspace_root,
            .tenant_id = "local",
        },
    };

    var ctx = context_mod.AgentContext{
        .allocator = arena_alloc,
        .services = &services,
        .task = .{
            .id = 0,
            .parent_id = null,
            .kind = .coder,
            .mode = .sequential,
            .state = .running,
            .budget = types.TokenBudget.defaultPlanning(),
            .memory = .{
                .symbol_snapshot_id = 0,
                .task_graph_id = 0,
                .policy_snapshot_id = 0,
                .artifact_set_id = 0,
            },
            .prompt_template_id = 0,
            .rollback_journal_id = 0,
            .title = "IPC tool invocation",
        },
        .agent_id = "ipc-agent",
        .kind = .coder,
        .cancel = &token,
        .budget = &meter,
    };

    var result = ctx.invokeTool(tool_id, input) catch |err| {
        return ToolResponse{
            .ok = false,
            .output = try allocator.dupe(u8, ""),
            .error_message = try allocator.dupe(u8, @errorName(err)),
        };
    };

    // Tool output is the boundary where workspace data can leave the local
    // engine and enter the model provider. Never return detected secrets or
    // regulated identifiers to the Flutter agent loop, including failed/timed
    // out commands whose partial stdout/stderr may contain sensitive data.
    if (result.output.len > 0) {
        const classification = classifier.ContentClassifier.classify(
            result.output,
            arena_alloc,
        ) catch {
            return ToolResponse{
                .ok = false,
                .output = try allocator.dupe(u8, ""),
                .error_message = try allocator.dupe(u8, "tool output classification failed"),
            };
        };
        defer arena_alloc.free(classification.spans);

        if (@intFromEnum(classification.max_class) >= @intFromEnum(classifier.Classification.regulated)) {
            result.output = classifier.ContentClassifier.redact(
                result.output,
                classification.spans,
                arena_alloc,
            ) catch {
                return ToolResponse{
                    .ok = false,
                    .output = try allocator.dupe(u8, ""),
                    .error_message = try allocator.dupe(u8, "tool output redaction failed"),
                };
            };
        }
    }

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

test "agent runtime: secret tool output is redacted before IPC egress" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(root);

    const write = try executeTool(
        allocator,
        "file.write",
        "{\"path\":\"secret.txt\",\"content\":\"api_key=sk-super-secret-value\"}",
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
        "{"path":"secret.txt"}",
        root,
        null,
    );
    defer {
        allocator.free(read.output);
        allocator.free(read.error_message);
    }
    try std.testing.expect(read.ok);
    try std.testing.expect(std.mem.indexOf(u8, read.output, "super-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, read.output, "[REDACTED]") != null);
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

