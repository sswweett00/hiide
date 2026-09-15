/// End-to-end demonstration of the hiide agent framework.
///
/// Registers a small set of (scripted) agents, expands a natural-language
/// instruction into a plan, and runs it through the full governance pipeline.
/// Build/run with: `zig build agent-demo`.
const std = @import("std");
const hiide = @import("hiide");

const framework = hiide.agent.framework;
const Orchestrator = framework.orchestrator.Orchestrator;
const ScriptedFactory = framework.testing.ScriptedFactory;
const makeTask = framework.testing.makeTask;
const types = hiide.agent.types;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const out = std.io.getStdOut().writer();

    var engine = try Orchestrator.init(allocator, .{ .manual_clock = true });
    defer engine.deinit();

    // The orchestrator already registers a built-in planner agent (id "planner"),
    // so we only register the worker agents here.
    var coder = ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .summary = "implemented the feature", .confidence = 92 },
    };
    var reviewer = ScriptedFactory{
        .descriptor = .{ .id = "reviewer", .kind = .reviewer },
        .script = .{ .summary = "verified, no regressions", .confidence = 96 },
    };
    try engine.registerAgent(coder.factory());
    try engine.registerAgent(reviewer.factory());

    const instruction = "implement the login form with validation";
    try out.print("objective: {s}\n", .{instruction});

    var report = try engine.submit(instruction, null);
    defer report.deinit();

    try out.print("plan ok={} completed={d} failed={d}\n", .{ report.ok(), report.completed, report.failed });
    for (report.results) |r| {
        try out.print("  - task {d} [{s}] {s} (conf={d})\n", .{ r.task_id, @tagName(r.status), r.summary, r.confidence });
    }
}
