/// Benchmark harness entry point.
/// Runs all spec §8 benchmark scenarios and reports results to stdout.
const std = @import("std");
const hiide = @import("hiide");
const bench = hiide.bench.runner;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    try stdout.print("hiide benchmark suite — build: 0.1.0-dev\n\n", .{});

    // ── §1 Scheduler enqueue/dequeue latency target: <2 µs p99 ──────────────
    {
        const SchedulerBench = struct {
            var g_scheduler: ?hiide.agent.scheduler.Scheduler = null;
            var g_alloc: std.mem.Allocator = undefined;

            fn setup(a: std.mem.Allocator) void {
                g_alloc = a;
                g_scheduler = hiide.agent.scheduler.Scheduler.init(a);
            }

            fn run() anyerror!void {
                const budget = hiide.agent.types.TokenBudget.defaultPlanning();
                const mem_ref = hiide.agent.types.WorkingMemoryRef{
                    .symbol_snapshot_id = 0,
                    .task_graph_id = 0,
                    .policy_snapshot_id = 0,
                    .artifact_set_id = 0,
                };
                const task = hiide.agent.types.AgentTask{
                    .id = hiide.agent.types.nextTaskId(std.crypto.random),
                    .parent_id = null,
                    .kind = .coder,
                    .mode = .sequential,
                    .state = .queued,
                    .budget = budget,
                    .memory = mem_ref,
                    .prompt_template_id = 0,
                    .rollback_journal_id = 0,
                    .title = "bench",
                };
                try g_scheduler.?.submit(task);
                _ = g_scheduler.?.pop();
            }

            fn teardown() void {
                if (g_scheduler) |*s| s.deinit();
            }
        };

        SchedulerBench.setup(alloc);
        defer SchedulerBench.teardown();

        const samples = try alloc.alloc(f64, 1000);
        defer alloc.free(samples);
        for (samples) |*s| {
            const t = bench.Timer.start();
            try SchedulerBench.run();
            s.* = t.elapsedUs();
        }
        const pct = bench.Percentiles.compute(samples);
        try stdout.print("scheduler enqueue+dequeue (µs):  p50={d:.2}  p95={d:.2}  p99={d:.2}\n", .{ pct.p50, pct.p95, pct.p99 });
    }

    // ── §2 Semantic query latency target: <50 ms p99 on warm cache ───────────
    {
        var graph = hiide.semantic.graph.SemanticGraph.init(alloc);
        defer graph.deinit();

        // Populate with synthetic symbols.
        const added_nodes = try alloc.alloc(hiide.semantic.graph.NodeRecord, 256);
        defer alloc.free(added_nodes);
        var k: u64 = 0;
        while (k < 256) : (k += 1) {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "symbol_{d}", .{k}) catch "sym";
            added_nodes[k] = .{
                .id = hiide.semantic.graph.SymbolId.fromU128(k + 1),
                .kind = .function,
                .name = try alloc.dupe(u8, name),
                .lang = "zig",
                .parent = null,
            };
        }
        try graph.applyDelta(.{
            .snapshot_id = 1,
            .added_nodes = added_nodes,
            .removed_ids = &.{},
            .added_edges = &.{},
            .removed_edges = &.{},
        });
        // Free temporary name buffers; graph owns its own copies.
        for (added_nodes) |node| alloc.free(node.name);

        const store = hiide.semantic.query.SemanticStore.init(&graph);

        const samples = try alloc.alloc(f64, 100);
        defer alloc.free(samples);
        for (samples) |*s| {
            const t = bench.Timer.start();
            const hits = try store.query(.{ .hybrid_search = .{ .text = "symbol_12", .top_k = 10 } }, alloc);
            s.* = t.elapsedMs();
            alloc.free(hits);
        }
        const pct = bench.Percentiles.compute(samples);
        try stdout.print("semantic hybrid_search (ms):      p50={d:.3}  p95={d:.3}  p99={d:.3}\n", .{ pct.p50, pct.p95, pct.p99 });
    }

    // ── §3 Policy evaluation target: <15 ms p95 ──────────────────────────────
    {
        var engine = hiide.security.policy.PolicyEngine.init(alloc);
        defer engine.deinit();
        try engine.loadDefaults();

        const input = hiide.security.policy.PolicyInput{
            .user_id = "bench-user",
            .action = "provider_send",
            .provider_id = "openai",
            .model_id = "gpt-4o",
            .classifications = &[_]hiide.security.classifier.Classification{.public},
            .workspace_id = "ws-bench",
        };

        const samples = try alloc.alloc(f64, 500);
        defer alloc.free(samples);
        for (samples) |*s| {
            const t = bench.Timer.start();
            _ = try engine.evaluate(input);
            s.* = t.elapsedMs();
        }
        const pct = bench.Percentiles.compute(samples);
        try stdout.print("policy evaluate (ms):             p50={d:.4}  p95={d:.4}  p99={d:.4}\n", .{ pct.p50, pct.p95, pct.p99 });
    }

    try stdout.print("\nDone. Run `zig build bench` to repeat.\n", .{});
}
