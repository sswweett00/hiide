/// DAG executor: worker pool, execution modes, retry, and rollback.
///
/// The executor takes a validated plan and drives it to completion under the
/// guarantees of spec §1:
///   * dependency-ordered execution with a bounded worker pool
///   * `sequential`, `parallel_fanout`, `debate_consensus`, `speculative`, and
///     `approval_gated` execution modes
///   * per-node arenas so speculative work is discarded by dropping an arena
///   * cancellation propagation by subtree before any mutation is committed
///   * exponential backoff for transient failures, model downgrade for budget
///     pressure, and approval escalation for divergent debates
const std = @import("std");
const types = @import("../types.zig");
const dag = @import("../dag.zig");
const journal_mod = @import("../journal.zig");
const agent_mod = @import("agent.zig");
const approval_mod = @import("approval.zig");
const budget_mod = @import("budget.zig");
const cancel_mod = @import("cancel.zig");
const clock_mod = @import("clock.zig");
const consensus_mod = @import("consensus.zig");
const context_mod = @import("context.zig");
const errors_mod = @import("errors.zig");
const middleware_mod = @import("middleware.zig");
const queue_mod = @import("queue.zig");
const registry_mod = @import("registry.zig");

pub const ExecutorError = error{
    PlanEmpty,
    PlanTooLarge,
    ExecutorShuttingDown,
    ExecutorSaturated,
    OutOfMemory,
};

pub const MAX_PLAN_NODES: usize = 16_384;

/// Terminal disposition of one plan node.
pub const NodeStatus = enum(u8) {
    completed,
    failed,
    skipped,
    canceled,
    awaiting_approval,

    pub fn isSuccess(self: NodeStatus) bool {
        return self == .completed;
    }
};

pub const NodeResult = struct {
    task_id: u128,
    parent_id: ?u128,
    kind: types.AgentKind,
    mode: types.ExecutionMode,
    status: NodeStatus,
    agent_status: agent_mod.AgentStatus,
    /// Duplicated into the report allocator; the node arena is already gone.
    summary: []const u8,
    digest: [32]u8,
    confidence: u8,
    attempts: u16,
    latency_ms: u32,
    tokens_in: u32,
    tokens_out: u32,
    tool_calls: u32,
    err: ?anyerror,
    /// Populated for `debate_consensus` nodes.
    consensus: ?consensus_mod.Result = null,
};

pub const RunReport = struct {
    allocator: std.mem.Allocator,
    graph_id: u64,
    results: []NodeResult,
    completed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    canceled: u32 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    wall_ms: u32 = 0,

    pub fn deinit(self: *RunReport) void {
        for (self.results) |r| self.allocator.free(r.summary);
        self.allocator.free(self.results);
        self.* = undefined;
    }

    /// True when every node completed successfully.
    /// @example
    /// if (!report.ok()) return error.PlanFailed;
    pub fn ok(self: RunReport) bool {
        return self.failed == 0 and self.canceled == 0 and self.skipped == 0;
    }

    /// Looks a node result up by task id.
    /// @example
    /// const r = report.find(task_id) orelse return;
    pub fn find(self: RunReport, task_id: u128) ?NodeResult {
        for (self.results) |r| {
            if (r.task_id == task_id) return r;
        }
        return null;
    }
};

pub const Options = struct {
    /// Upper bound on concurrent worker threads. 1 runs the plan inline, which
    /// makes execution fully deterministic for replay tests.
    max_workers: u16 = 8,
    /// Per-node wall-clock ceiling; 0 inherits the agent descriptor value.
    node_timeout_ms: u32 = 0,
    retry_base_backoff_ms: u32 = 25,
    retry_max_backoff_ms: u32 = 2_000,
    /// Replica count for `debate_consensus` nodes.
    debate_replicas: u8 = 3,
    consensus: consensus_mod.Config = .{},
    /// Cancel the failing node's subtree when it fails permanently.
    fail_fast_subtree: bool = true,
    /// Promote speculative artifacts automatically on success instead of
    /// waiting for an explicit promotion call.
    auto_promote_speculative: bool = false,
};

/// A validated, schedulable plan. `tasks` must outlive the plan because task
/// titles are borrowed, not copied.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    graph_id: u64,
    tasks: []types.AgentTask,
    children: [][]usize,
    parents: [][]usize,
    indegree: []u32,

    /// Compiles and validates a task list into an executable plan.
    /// Cycles and missing dependencies are rejected at compile time (spec §1.5).
    /// Sequential parents get synthetic sibling edges so their children run in
    /// declaration order without special-casing the worker loop.
    /// @example
    /// var plan = try Plan.compile(alloc, &tasks, 1);
    pub fn compile(
        alloc: std.mem.Allocator,
        tasks: []const types.AgentTask,
        graph_id: u64,
    ) !Plan {
        if (tasks.len == 0) return ExecutorError.PlanEmpty;
        if (tasks.len > MAX_PLAN_NODES) return ExecutorError.PlanTooLarge;

        var graph = try dag.DagCompiler.compile(alloc, tasks, graph_id);
        defer graph.deinit();

        const n = tasks.len;
        var children = try alloc.alloc([]usize, n);
        var parents = try alloc.alloc([]usize, n);
        const indegree = try alloc.alloc(u32, n);
        const owned_tasks = try alloc.dupe(types.AgentTask, tasks);
        @memset(indegree, 0);

        var child_lists = try alloc.alloc(std.ArrayListUnmanaged(usize), n);
        var parent_lists = try alloc.alloc(std.ArrayListUnmanaged(usize), n);
        defer alloc.free(child_lists);
        defer alloc.free(parent_lists);
        for (child_lists) |*l| l.* = .empty;
        for (parent_lists) |*l| l.* = .empty;

        errdefer {
            for (child_lists) |*l| l.deinit(alloc);
            for (parent_lists) |*l| l.deinit(alloc);
            alloc.free(children);
            alloc.free(parents);
            alloc.free(indegree);
            alloc.free(owned_tasks);
        }

        // Structural parent → child edges from the compiled DAG.
        for (graph.nodes.items, 0..) |node, i| {
            for (node.children.items) |child_idx| {
                try child_lists[i].append(alloc, child_idx);
                try parent_lists[child_idx].append(alloc, i);
            }
        }

        // Serial edges between siblings of a `sequential` parent.
        for (graph.nodes.items, 0..) |node, i| {
            if (tasks[i].mode != .sequential) continue;
            const kids = node.children.items;
            if (kids.len < 2) continue;
            for (kids[0 .. kids.len - 1], kids[1..]) |a, b| {
                try child_lists[a].append(alloc, b);
                try parent_lists[b].append(alloc, a);
            }
        }

        for (0..n) |i| {
            children[i] = try child_lists[i].toOwnedSlice(alloc);
            parents[i] = try parent_lists[i].toOwnedSlice(alloc);
        }
        for (0..n) |i| indegree[i] = @intCast(parents[i].len);

        return .{
            .allocator = alloc,
            .graph_id = graph_id,
            .tasks = owned_tasks,
            .children = children,
            .parents = parents,
            .indegree = indegree,
        };
    }

    pub fn deinit(self: *Plan) void {
        for (self.children) |c| self.allocator.free(c);
        for (self.parents) |p| self.allocator.free(p);
        self.allocator.free(self.children);
        self.allocator.free(self.parents);
        self.allocator.free(self.indegree);
        self.allocator.free(self.tasks);
        self.* = undefined;
    }

    pub fn nodeCount(self: Plan) usize {
        return self.tasks.len;
    }

    /// Index of the task with `task_id`.
    /// @example
    /// const idx = plan.indexOf(task_id) orelse return;
    pub fn indexOf(self: Plan, task_id: u128) ?usize {
        for (self.tasks, 0..) |t, i| {
            if (t.id == task_id) return i;
        }
        return null;
    }
};

/// Mutable per-node scheduling state.
const NodeState = struct {
    pending_deps: std.atomic.Value(u32),
    dependency_failed: std.atomic.Value(bool),
    result: NodeResult,
    meter: budget_mod.Meter,
    token: *cancel_mod.Token,
};

/// Shared run context handed to every worker thread.
const RunState = struct {
    executor: *Executor,
    plan: *const Plan,
    nodes: []NodeState,
    ready: queue_mod.WorkQueue(usize),
    remaining: std.atomic.Value(usize),
    tree: *cancel_mod.Tree,
    root_meter: *budget_mod.Meter,
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    services: *context_mod.Services,
    agents: *registry_mod.Registry,
    options: Options,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Creates an executor bound to a service bundle and agent registry.
    /// @example
    /// var executor = Executor.init(alloc, &services, &agents, .{});
    pub fn init(
        allocator: std.mem.Allocator,
        services: *context_mod.Services,
        agents: *registry_mod.Registry,
        options: Options,
    ) Executor {
        return .{
            .allocator = allocator,
            .services = services,
            .agents = agents,
            .options = options,
        };
    }

    /// Signals workers to stop accepting new nodes.
    /// @example
    /// executor.shutdown();
    pub fn shutdown(self: *Executor) void {
        self.shutting_down.store(true, .release);
    }

    /// Executes `plan` to completion and returns a per-node report.
    /// Caller owns the report.
    /// @example
    /// var report = try executor.run(&plan, &root_meter);
    /// defer report.deinit();
    pub fn run(self: *Executor, plan: *const Plan, root_meter: *budget_mod.Meter) !RunReport {
        if (self.shutting_down.load(.acquire)) return ExecutorError.ExecutorShuttingDown;
        const n = plan.nodeCount();
        if (n == 0) return ExecutorError.PlanEmpty;

        const started_ms = self.services.clock.nowMs();

        // Cancellation tree: reuse the shared one when present so external
        // cancellation (UI, IPC) reaches in-flight nodes.
        var local_tree = cancel_mod.Tree.init(self.allocator);
        const tree: *cancel_mod.Tree = self.services.cancel_tree orelse &local_tree;
        defer if (self.services.cancel_tree == null) local_tree.deinit();

        const nodes = try self.allocator.alloc(NodeState, n);
        defer self.allocator.free(nodes);

        for (plan.tasks, 0..) |task, i| {
            const deadline: ?i64 = blk: {
                const budget_ms = if (self.options.node_timeout_ms > 0) self.options.node_timeout_ms else 0;
                if (budget_ms == 0) break :blk null;
                break :blk self.services.clock.deadlineIn(budget_ms);
            };
            const token = try tree.register(task.id, task.parent_id, deadline);

            nodes[i] = .{
                .pending_deps = std.atomic.Value(u32).init(plan.indegree[i]),
                .dependency_failed = std.atomic.Value(bool).init(false),
                .result = .{
                    .task_id = task.id,
                    .parent_id = task.parent_id,
                    .kind = task.kind,
                    .mode = task.mode,
                    .status = .skipped,
                    .agent_status = .no_op,
                    .summary = "",
                    .digest = @as([32]u8, @splat(0)),
                    .confidence = 0,
                    .attempts = 0,
                    .latency_ms = 0,
                    .tokens_in = 0,
                    .tokens_out = 0,
                    .tool_calls = 0,
                    .err = null,
                },
                .meter = budget_mod.Meter.child(root_meter, task.budget),
                .token = token,
            };
        }

        const ring_slots = try std.math.ceilPowerOfTwo(usize, @max(n + 1, 4));
        var state = RunState{
            .executor = self,
            .plan = plan,
            .nodes = nodes,
            .ready = try queue_mod.WorkQueue(usize).init(self.allocator, ring_slots),
            .remaining = std.atomic.Value(usize).init(n),
            .tree = tree,
            .root_meter = root_meter,
        };
        defer state.ready.deinit(self.allocator);

        for (plan.indegree, 0..) |deg, i| {
            if (deg == 0) {
                if (!state.ready.push(i)) return ExecutorError.ExecutorSaturated;
            }
        }

        const worker_count: usize = @min(@as(usize, @max(self.options.max_workers, 1)), n);
        if (worker_count <= 1) {
            workerLoop(&state);
        } else {
            const threads = try self.allocator.alloc(std.Thread, worker_count);
            defer self.allocator.free(threads);

            var spawned: usize = 0;
            errdefer {
                state.ready.close();
                for (threads[0..spawned]) |t| t.join();
            }
            while (spawned < worker_count) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{&state});
            }
            for (threads[0..spawned]) |t| t.join();
        }

        // ── build the report ────────────────────────────────────────────────
        var report = RunReport{
            .allocator = self.allocator,
            .graph_id = plan.graph_id,
            .results = self.allocator.alloc(NodeResult, n) catch |err| {
                // Release summaries that would otherwise leak.
                for (nodes) |node_state| self.allocator.free(node_state.result.summary);
                return err;
            },
        };

        for (nodes, 0..) |node_state, i| {
            // Ownership of `summary` moves from the node state to the report.
            const result = node_state.result;
            report.results[i] = result;

            switch (result.status) {
                .completed => report.completed += 1,
                .failed => report.failed += 1,
                .skipped => report.skipped += 1,
                .canceled => report.canceled += 1,
                .awaiting_approval => report.failed += 1,
            }
            report.tokens_in += result.tokens_in;
            report.tokens_out += result.tokens_out;
        }

        const elapsed = self.services.clock.nowMs() - started_ms;
        report.wall_ms = if (elapsed <= 0) 0 else @intCast(@min(elapsed, std.math.maxInt(u32)));
        return report;
    }
};

fn workerLoop(state: *RunState) void {
    while (state.ready.pop()) |idx| {
        executeNode(state, idx);

        // Release dependents.
        const failed = !state.nodes[idx].result.status.isSuccess();
        for (state.plan.children[idx]) |child_idx| {
            if (failed) state.nodes[child_idx].dependency_failed.store(true, .release);
            const before = state.nodes[child_idx].pending_deps.fetchSub(1, .acq_rel);
            if (before == 1) {
                _ = state.ready.push(child_idx);
            }
        }

        if (state.remaining.fetchSub(1, .acq_rel) == 1) {
            state.ready.close();
            return;
        }
    }
}

fn executeNode(state: *RunState, idx: usize) void {
    const self = state.executor;
    const task = state.plan.tasks[idx];
    const node = &state.nodes[idx];
    const services = self.services;

    // Dependency failure or cancellation short-circuits the node.
    if (node.dependency_failed.load(.acquire)) {
        node.result.status = .skipped;
        node.result.err = errors_mod.LifecycleError.DependencyUnsatisfied;
        return;
    }
    if (node.token.isCanceled()) {
        node.result.status = .canceled;
        node.result.err = cancel_mod.CancelError.Canceled;
        return;
    }
    if (self.shutting_down.load(.acquire)) {
        node.result.status = .canceled;
        node.result.err = ExecutorError.ExecutorShuttingDown;
        return;
    }

    // Resolve the agent implementation for this node.
    const factory = self.agents.byKind(task.kind) orelse {
        node.result.status = .failed;
        node.result.err = registry_mod.RegistryError.AgentNotRegistered;
        return;
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const node_alloc = arena.allocator();

    const instance = factory.create(node_alloc) catch |err| {
        node.result.status = .failed;
        node.result.err = err;
        return;
    };
    defer factory.destroy(node_alloc, instance);

    const sw = clock_mod.Stopwatch.start(services.clock);
    const speculative = task.mode == .speculative or task.mode == .approval_gated;

    const outcome = switch (task.mode) {
        .debate_consensus => runDebate(state, idx, instance, node_alloc, speculative),
        else => runWithRetry(state, idx, instance, node_alloc, speculative, 0),
    };

    node.result.latency_ms = sw.elapsedMs();
    node.result.attempts = outcome.attempts;
    node.result.tokens_in = outcome.tokens_in;
    node.result.tokens_out = outcome.tokens_out;
    node.result.tool_calls = outcome.tool_calls;
    node.result.consensus = outcome.consensus;

    if (outcome.err) |err| {
        node.result.status = switch (errors_mod.classify(err)) {
            .cancellation => .canceled,
            else => .failed,
        };
        node.result.err = err;
        node.result.agent_status = if (node.result.status == .canceled) .canceled else .failed;
        finishNode(state, idx, false, speculative);
        return;
    }

    const output = outcome.output;
    node.result.agent_status = output.status;
    node.result.confidence = output.confidence;
    node.result.digest = output.digest;
    // The summary lives in the node arena, which is about to be torn down, so
    // copy it into the executor allocator. Ownership transfers to the report.
    node.result.summary = self.allocator.dupe(u8, output.summary) catch "";

    if (!output.status.isUsable()) {
        node.result.status = .failed;
        node.result.err = errors_mod.LifecycleError.AgentPanicked;
        finishNode(state, idx, false, speculative);
        return;
    }

    // Approval-gated nodes run speculatively and only commit after a human
    // decision, matching the approval gate in the spec §1.1 diagram.
    if (task.mode == .approval_gated) {
        if (!requestNodeApproval(state, idx, output)) {
            node.result.status = .awaiting_approval;
            node.result.err = approval_mod.ApprovalError.ApprovalRejected;
            finishNode(state, idx, false, speculative);
            return;
        }
    }

    node.result.status = .completed;
    finishNode(state, idx, true, speculative);
}

const Outcome = struct {
    output: agent_mod.AgentOutput = .{},
    err: ?anyerror = null,
    attempts: u16 = 0,
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    tool_calls: u32 = 0,
    consensus: ?consensus_mod.Result = null,
};

fn runWithRetry(
    state: *RunState,
    idx: usize,
    instance: agent_mod.Agent,
    node_alloc: std.mem.Allocator,
    speculative: bool,
    replica: u8,
) Outcome {
    const self = state.executor;
    const services = self.services;
    const task = state.plan.tasks[idx];
    const node = &state.nodes[idx];

    var outcome = Outcome{};
    const max_attempts: u16 = @as(u16, instance.descriptor.max_retries) + 1;

    var attempt: u16 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        outcome.attempts = attempt + 1;

        if (node.token.check(services.clock)) |_| {} else |err| {
            outcome.err = err;
            return outcome;
        }

        var ctx = context_mod.AgentContext{
            .allocator = node_alloc,
            .services = services,
            .task = task,
            .agent_id = instance.descriptor.id,
            .kind = task.kind,
            .cancel = node.token,
            .budget = &node.meter,
            .allowed_tools = instance.descriptor.allowed_tools,
            .attempt = attempt +| (@as(u16, replica) * max_attempts),
            .speculative = speculative,
        };

        if (services.middleware) |pipeline| {
            pipeline.notifyAgent(.{
                .phase = .start,
                .task_id = task.id,
                .agent_id = instance.descriptor.id,
                .kind = task.kind,
                .mode = task.mode,
                .attempt = ctx.attempt,
            });
        }

        const sw = clock_mod.Stopwatch.start(services.clock);
        const tokens_in_before = node.meter.tokens_in.load(.acquire);
        const tokens_out_before = node.meter.tokens_out.load(.acquire);
        const run_result = instance.run(&ctx);
        const latency = sw.elapsedMs();

        if (run_result) |output| {
            // Self-reported token usage is charged by the executor so budget
            // enforcement does not depend on agent discipline.
            if (output.tokens_in != 0 or output.tokens_out != 0 or output.microunits != 0) {
                _ = node.meter.charge(.{
                    .tokens_in = output.tokens_in,
                    .tokens_out = output.tokens_out,
                    .microunits = output.microunits,
                }) catch |err| {
                    outcome.err = err;
                };
            }
            outcome.tokens_in +|= tokenDelta(node.meter.tokens_in.load(.acquire), tokens_in_before);
            outcome.tokens_out +|= tokenDelta(node.meter.tokens_out.load(.acquire), tokens_out_before);
            outcome.tool_calls +|= ctx.stats.tool_calls;

            if (outcome.err != null) {
                notifyFinish(services, task, instance, ctx.attempt, latency, ctx, @intFromEnum(agent_mod.AgentStatus.budget_exhausted), outcome.err);
                return outcome;
            }

            outcome.output = output;
            notifyFinish(services, task, instance, ctx.attempt, latency, ctx, @intFromEnum(output.status), null);
            return outcome;
        } else |err| {
            outcome.tokens_in +|= tokenDelta(node.meter.tokens_in.load(.acquire), tokens_in_before);
            outcome.tokens_out +|= tokenDelta(node.meter.tokens_out.load(.acquire), tokens_out_before);
            outcome.tool_calls +|= ctx.stats.tool_calls;
            outcome.err = err;
            notifyFinish(services, task, instance, ctx.attempt, latency, ctx, @intFromEnum(agent_mod.AgentStatus.failed), err);

            const class = errors_mod.classify(err);
            if (class != .transient or attempt + 1 >= max_attempts) return outcome;

            services.metric("agent.retry", .{ .u64 = 1 });
            instance.reset();
            const backoff = backoffMs(
                attempt,
                self.options.retry_base_backoff_ms,
                self.options.retry_max_backoff_ms,
            );
            services.clock.sleepMs(backoff);
        }
    }
    return outcome;
}

fn tokenDelta(now: u64, before: u64) u32 {
    if (now <= before) return 0;
    return @intCast(@min(now - before, std.math.maxInt(u32)));
}

fn runDebate(
    state: *RunState,
    idx: usize,
    instance: agent_mod.Agent,
    node_alloc: std.mem.Allocator,
    speculative: bool,
) Outcome {
    const self = state.executor;
    const replicas: u8 = @max(self.options.debate_replicas, 1);

    var outputs = std.ArrayListUnmanaged(agent_mod.AgentOutput).empty;
    defer outputs.deinit(node_alloc);

    var aggregate = Outcome{};
    var replica: u8 = 0;
    while (replica < replicas) : (replica += 1) {
        const attempt_outcome = runWithRetry(state, idx, instance, node_alloc, speculative, replica);
        aggregate.attempts +|= attempt_outcome.attempts;
        aggregate.tokens_in +|= attempt_outcome.tokens_in;
        aggregate.tokens_out +|= attempt_outcome.tokens_out;
        aggregate.tool_calls +|= attempt_outcome.tool_calls;

        if (attempt_outcome.err) |err| {
            // A cancelled replica aborts the whole debate; other failures just
            // remove that voter.
            if (errors_mod.classify(err) == .cancellation) {
                aggregate.err = err;
                return aggregate;
            }
            continue;
        }
        outputs.append(node_alloc, attempt_outcome.output) catch break;
        instance.reset();
    }

    if (outputs.items.len == 0) {
        aggregate.err = consensus_mod.ConsensusError.InsufficientVoters;
        return aggregate;
    }

    const result = consensus_mod.evaluate(outputs.items, self.options.consensus) catch |err| {
        aggregate.err = err;
        return aggregate;
    };
    aggregate.consensus = result;

    if (result.outcome == .divergent) {
        self.services.metric("agent.consensus_divergent", .{ .u64 = 1 });
        if (!result.requires_escalation) {
            aggregate.err = consensus_mod.ConsensusError.DivergentOutputs;
            return aggregate;
        }
        // Escalate: a human decides whether the leading answer may proceed.
        if (!requestNodeApproval(state, idx, outputs.items[result.winner_index])) {
            aggregate.err = approval_mod.ApprovalError.ApprovalRejected;
            return aggregate;
        }
    }

    aggregate.output = outputs.items[result.winner_index];
    return aggregate;
}

fn requestNodeApproval(state: *RunState, idx: usize, output: agent_mod.AgentOutput) bool {
    const services = state.executor.services;
    const task = state.plan.tasks[idx];
    const gate = services.approvals orelse return false; // fail closed

    var detail_buf: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "digest={s} confidence={d}", .{
        @as([]const u8, &std.fmt.bytesToHex(output.digest[0..8], .lower)),
        output.confidence,
    }) catch "digest=unavailable";

    _ = gate.requestAndWait(.{
        .task_id = task.id,
        .agent_id = @tagName(task.kind),
        .tool_id = "",
        .side_effect = .workspace_write,
        .summary = task.title,
        .detail = detail,
    }, state.nodes[idx].token) catch return false;

    return true;
}

/// Promotes or discards the node's speculative artifacts and journal entries.
fn finishNode(state: *RunState, idx: usize, success: bool, speculative: bool) void {
    const self = state.executor;
    const services = self.services;
    const task = state.plan.tasks[idx];

    if (speculative) {
        if (success and (self.options.auto_promote_speculative or task.mode == .approval_gated)) {
            _ = services.board.promoteTask(task.id);
            approveTaskJournal(services, task.id);
        } else if (!success) {
            _ = services.board.discardTask(task.id);
        }
    }

    if (!success and self.options.fail_fast_subtree) {
        // Stop descendants before they can journal a side effect.
        _ = state.tree.cancelSubtree(task.id, .upstream_failure) catch {};
        if (services.approvals) |gate| _ = gate.rejectPendingForTask(task.id);
    }
}

/// Approves every pending journal entry belonging to `task_id`.
fn approveTaskJournal(services: *context_mod.Services, task_id: u128) void {
    services.journal_mutex.lock();
    defer services.journal_mutex.unlock();
    for (services.journal.entries.items) |*entry| {
        if (entry.task_id == task_id and entry.state == .pending) {
            entry.state = .approved;
        }
    }
}

fn notifyFinish(
    services: *context_mod.Services,
    task: types.AgentTask,
    instance: agent_mod.Agent,
    attempt: u16,
    latency_ms: u32,
    ctx: context_mod.AgentContext,
    status_code: u8,
    err: ?anyerror,
) void {
    const pipeline = services.middleware orelse return;
    pipeline.notifyAgent(.{
        .phase = .finish,
        .task_id = task.id,
        .agent_id = instance.descriptor.id,
        .kind = task.kind,
        .mode = task.mode,
        .attempt = attempt,
        .status_code = status_code,
        .latency_ms = latency_ms,
        .tool_calls = ctx.stats.tool_calls,
        .err = err,
    });
}

/// Exponential backoff with a hard ceiling; deterministic (no jitter) so replay
/// tests stay reproducible.
/// @example
/// const ms = backoffMs(2, 25, 2_000);
pub fn backoffMs(attempt: u16, base_ms: u32, max_ms: u32) u64 {
    if (base_ms == 0) return 0;
    const shift: u6 = @intCast(@min(attempt, 16));
    const scaled = @as(u64, base_ms) << shift;
    return @min(scaled, @as(u64, max_ms));
}

test "executor: backoff grows exponentially and saturates" {
    try std.testing.expectEqual(@as(u64, 25), backoffMs(0, 25, 2_000));
    try std.testing.expectEqual(@as(u64, 50), backoffMs(1, 25, 2_000));
    try std.testing.expectEqual(@as(u64, 100), backoffMs(2, 25, 2_000));
    try std.testing.expectEqual(@as(u64, 2_000), backoffMs(10, 25, 2_000));
    try std.testing.expectEqual(@as(u64, 0), backoffMs(3, 0, 2_000));
}

test "executor: plan compilation wires parents, children, and serial edges" {
    const alloc = std.testing.allocator;
    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    const tasks = [_]types.AgentTask{
        .{ .id = 1, .parent_id = null, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "root" },
        .{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "a" },
        .{ .id = 3, .parent_id = 1, .kind = .tester, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "b" },
    };

    var plan = try Plan.compile(alloc, &tasks, 7);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan.nodeCount());
    try std.testing.expectEqual(@as(u32, 0), plan.indegree[0]);
    try std.testing.expectEqual(@as(u32, 1), plan.indegree[1]);
    // Node 3 depends on both its parent and its serial predecessor.
    try std.testing.expectEqual(@as(u32, 2), plan.indegree[2]);
    try std.testing.expectEqual(@as(?usize, 1), plan.indexOf(2));
}

test "executor: parallel fanout parents do not add serial edges" {
    const alloc = std.testing.allocator;
    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    const tasks = [_]types.AgentTask{
        .{ .id = 1, .parent_id = null, .kind = .planner, .mode = .parallel_fanout, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "root" },
        .{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "a" },
        .{ .id = 3, .parent_id = 1, .kind = .tester, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "b" },
    };

    var plan = try Plan.compile(alloc, &tasks, 8);
    defer plan.deinit();

    try std.testing.expectEqual(@as(u32, 1), plan.indegree[1]);
    try std.testing.expectEqual(@as(u32, 1), plan.indegree[2]);
}

test "executor: rejects empty and cyclic plans" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(ExecutorError.PlanEmpty, Plan.compile(alloc, &.{}, 1));

    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };
    const cyclic = [_]types.AgentTask{
        .{ .id = 1, .parent_id = 2, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "a" },
        .{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "b" },
    };
    try std.testing.expectError(dag.DagError.CycleDetected, Plan.compile(alloc, &cyclic, 2));
}
