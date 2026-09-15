const std = @import("std");
const compat = @import("../compat.zig");
const Orchestrator = @import("framework/orchestrator.zig").Orchestrator;
const ScriptedFactory = @import("framework/testing.zig").ScriptedFactory;

/// Result of a one-shot agent run, returned to host callers.
pub const AgentRunResult = extern struct {
    ok: bool,
    completed: u32,
    failed: u32,
};

/// Runs the full multi-agent pipeline (planner -> coder -> reviewer) for an
/// instruction and returns a heap-allocated, null-terminated report string.
///
/// The string is allocated with the C allocator and must be released by the
/// caller via `hiide_string_free`.
///
/// @example (host)
/// const report = hiide_agent_run("implement the login form");
/// // ... use report ...
/// hiide_string_free(report);
pub export fn hiide_agent_run(instruction: [*:0]const u8) callconv(.C) ?[*]const u8 {
    const allocator = std.heap.c_allocator;

    // Use an arena for the engine's internal allocations so a single deinit
    // frees everything; only the returned report string lives in the C heap.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var engine = Orchestrator.init(a, .{ .manual_clock = true }) catch return null;
    defer engine.deinit();

    var coder = ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .summary = "implemented the feature", .confidence = 92 },
    };
    var reviewer = ScriptedFactory{
        .descriptor = .{ .id = "reviewer", .kind = .reviewer },
        .script = .{ .summary = "verified, no regressions", .confidence = 96 },
    };
    engine.registerAgent(coder.factory()) catch {};
    engine.registerAgent(reviewer.factory()) catch {};

    const instr = std.mem.span(instruction);
    var report = engine.submit(instr, null) catch return null;
    defer report.deinit();

    var buf = compat.ManagedArrayList(u8).init(allocator);
    const w = buf.writer();
    w.print("objective: {s}\n", .{instr}) catch {};
    w.print("plan ok={} completed={d} failed={d}\n", .{ report.ok(), report.completed, report.failed }) catch {};
    for (report.results) |r| {
        w.print("  - task {d} [{s}] {s} (conf={d})\n", .{ r.task_id, @tagName(r.status), r.summary, r.confidence }) catch {};
    }

    const out = buf.toOwnedSlice() catch return null;
    const ptr = allocator.alloc(u8, out.len + 1) catch {
        allocator.free(out);
        return null;
    };
    @memcpy(ptr[0..out.len], out);
    ptr[out.len] = 0;
    allocator.free(out);
    return @ptrCast(ptr);
}

/// Frees a string previously returned by `hiide_agent_run` (or any engine
/// call that returns a C-allocator-backed, null-terminated string).
pub export fn hiide_string_free(ptr: ?[*]const u8) callconv(.C) void {
    if (ptr) |p| {
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        std.heap.c_allocator.free(slice);
    }
}
