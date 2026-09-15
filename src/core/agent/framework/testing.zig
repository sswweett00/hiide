/// Deterministic test harness: scripted agents, fault injection, and a fully
/// wired engine instance.
///
/// Spec §1.6 asks for model-free deterministic tests of DAG compilation,
/// cancellation propagation, budget enforcement, and rollback correctness. This
/// module is shipped (not test-only) so downstream plugins can validate their
/// agents against the same harness the core uses.
const std = @import("std");
const types = @import("../types.zig");
const journal_mod = @import("../journal.zig");
const policy_mod = @import("../../security/policy.zig");
const telemetry_mod = @import("../../telemetry/collector.zig");
const agent_mod = @import("agent.zig");
const approval_mod = @import("approval.zig");
const blackboard_mod = @import("blackboard.zig");
const budget_mod = @import("budget.zig");
const cancel_mod = @import("cancel.zig");
const clock_mod = @import("clock.zig");
const context_mod = @import("context.zig");
const executor_mod = @import("executor.zig");
const middleware_mod = @import("middleware.zig");
const prompt_mod = @import("prompt.zig");
const registry_mod = @import("registry.zig");
const tool_mod = @import("tool.zig");

/// Behaviour script for a mock agent. All fields are plain data so a test can
/// describe an entire scenario declaratively.
pub const Script = struct {
    summary: []const u8 = "ok",
    confidence: u8 = 100,
    status: agent_mod.AgentStatus = .ok,
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    /// Fail this many attempts before succeeding (transient error).
    fail_attempts: u16 = 0,
    /// Error returned while `fail_attempts` has not been exhausted.
    transient_error: anyerror = error.ToolTimeout,
    /// Always fail with this error, regardless of attempt count.
    permanent_error: ?anyerror = null,
    /// Virtual milliseconds consumed per attempt.
    work_ms: u32 = 0,
    /// Tool invoked once per successful attempt.
    tool_id: ?[]const u8 = null,
    tool_input: []const u8 = "{}",
    /// Blackboard key written on success.
    publish_key: ?[]const u8 = null,
    publish_bytes: []const u8 = "artifact",
    /// Distinct summaries cycled across replicas, used to model debate
    /// divergence: replica N uses `divergent_summaries[N % len]`.
    divergent_summaries: []const []const u8 = &.{},
};

/// Mock agent driven by a `Script`. Registered through `scriptedFactory`.
pub const ScriptedAgent = struct {
    script: *const Script,
    attempts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Executes one scripted attempt.
    /// @example
    /// const output = try agent.run(&ctx);
    pub fn run(self: *ScriptedAgent, ctx: *agent_mod.AgentContext) anyerror!agent_mod.AgentOutput {
        const attempt = self.attempts.fetchAdd(1, .acq_rel);
        const script = self.script;

        try ctx.checkCancel();
        if (script.work_ms > 0) ctx.services.clock.sleepMs(script.work_ms);
        try ctx.checkCancel();

        if (script.permanent_error) |err| return err;
        if (attempt < script.fail_attempts) return script.transient_error;

        if (script.tool_id) |tool_id| {
            _ = try ctx.invokeTool(tool_id, script.tool_input);
        }

        var handle: ?blackboard_mod.Handle = null;
        if (script.publish_key) |key| {
            handle = try ctx.publish(key, .patch_candidate, script.publish_bytes, .internal);
        }

        const run_index = self.runs.fetchAdd(1, .acq_rel);
        const summary = if (script.divergent_summaries.len > 0)
            script.divergent_summaries[run_index % script.divergent_summaries.len]
        else
            script.summary;

        var output = agent_mod.AgentOutput.fromSummary(summary, script.confidence);
        output.status = script.status;
        output.tokens_in = script.tokens_in;
        output.tokens_out = script.tokens_out;
        output.artifact = handle;
        return output;
    }

    /// Clears attempt-scoped state between retries (the attempt counter is
    /// deliberately preserved so `fail_attempts` can be honoured).
    /// @example
    /// agent.reset();
    pub fn reset(_: *ScriptedAgent) void {}
};

/// Caller-owned factory producing `ScriptedAgent`s that share one script.
pub const ScriptedFactory = struct {
    descriptor: agent_mod.AgentDescriptor,
    script: Script,
    owner: []const u8 = "test",
    /// Shared across every instance so retry counts survive re-creation.
    shared: ScriptedAgent = undefined,
    initialized: bool = false,

    fn create(ptr: *anyopaque, _: std.mem.Allocator) anyerror!agent_mod.Agent {
        const self: *ScriptedFactory = @ptrCast(@alignCast(ptr));
        if (!self.initialized) {
            self.shared = .{ .script = &self.script };
            self.initialized = true;
        }
        return agent_mod.fromImpl(ScriptedAgent, &self.shared, self.descriptor);
    }

    fn destroy(_: *anyopaque, _: std.mem.Allocator, _: agent_mod.Agent) void {}

    const vtable = registry_mod.Factory.VTable{ .create = create, .destroy = destroy };

    /// Returns the erased factory handle.
    /// @example
    /// try harness.agents.register(sf.factory());
    pub fn factory(self: *ScriptedFactory) registry_mod.Factory {
        return .{
            .descriptor = self.descriptor,
            .ctx = self,
            .owner = self.owner,
            .vtable = &vtable,
        };
    }

    /// Number of attempts executed so far.
    /// @example
    /// const n = sf.attemptCount();
    pub fn attemptCount(self: *ScriptedFactory) u32 {
        if (!self.initialized) return 0;
        return self.shared.attempts.load(.acquire);
    }
};

// ─── mock tools ──────────────────────────────────────────────────────────────

/// Echoes its input and reports a fixed token cost.
/// @example
/// try harness.tools.register(echoTool("echo", .pure));
pub fn echoTool(id: []const u8, side_effect: tool_mod.SideEffectClass) tool_mod.Tool {
    const Impl = struct {
        fn invoke(ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
            var result = tool_mod.ToolResult.success(try ctx.allocator.dupe(u8, input));
            result.tokens_in = 4;
            result.tokens_out = 4;
            return result;
        }
    };
    return tool_mod.fromFn(.{
        .id = id,
        .description = "test echo tool",
        .side_effect = side_effect,
        .owner = "test",
    }, Impl.invoke);
}

/// Always fails, for fault-injection tests.
/// @example
/// try harness.tools.register(failingTool("flaky", .workspace_write));
pub fn failingTool(id: []const u8, side_effect: tool_mod.SideEffectClass) tool_mod.Tool {
    const Impl = struct {
        fn invoke(_: *tool_mod.ToolContext, _: []const u8) anyerror!tool_mod.ToolResult {
            return error.ToolFailed;
        }
    };
    return tool_mod.fromFn(.{
        .id = id,
        .description = "test failing tool",
        .side_effect = side_effect,
        .owner = "test",
    }, Impl.invoke);
}

// ─── harness ─────────────────────────────────────────────────────────────────

pub const HarnessOptions = struct {
    approval_mode: approval_mod.Mode = .auto_approve,
    telemetry_level: telemetry_mod.TelemetryLevel = .basic,
    load_default_policy: bool = true,
    load_builtin_prompts: bool = true,
    /// Use a virtual clock so timeouts and backoff cost no real time.
    manual_clock: bool = true,
    executor: executor_mod.Options = .{ .max_workers = 1, .retry_base_backoff_ms = 1 },
    plan_budget: types.TokenBudget = .{
        .soft_limit = 1_000_000,
        .hard_limit = 0,
        .downgrade_model_id = "test-local",
        .spend_limit_microunits = 0,
    },
};

/// A fully wired engine for tests. Heap-allocated because `services` points at
/// sibling fields.
pub const Harness = struct {
    allocator: std.mem.Allocator,
    manual_clock: clock_mod.ManualClock,
    board: blackboard_mod.Blackboard,
    tools: tool_mod.Registry,
    journal: journal_mod.SideEffectJournal,
    prompts: prompt_mod.Registry,
    policy: policy_mod.PolicyEngine,
    ledger: policy_mod.AuditLedger,
    telemetry: telemetry_mod.TelemetrySink,
    approvals: approval_mod.Gate,
    pipeline: middleware_mod.Pipeline,
    tracer: middleware_mod.TracingMiddleware,
    cancel_tree: cancel_mod.Tree,
    agents: registry_mod.Registry,
    services: context_mod.Services,
    executor: executor_mod.Executor,
    plan_meter: budget_mod.Meter,

    /// Builds a harness with every subsystem wired together.
    /// @example
    /// var h = try Harness.create(std.testing.allocator, .{});
    /// defer h.destroy();
    pub fn create(allocator: std.mem.Allocator, options: HarnessOptions) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.manual_clock = clock_mod.ManualClock.init(1_700_000_000_000);
        const c = if (options.manual_clock) self.manual_clock.clock() else clock_mod.system();

        self.board = blackboard_mod.Blackboard.init(allocator, c);
        self.tools = tool_mod.Registry.init(allocator);
        self.journal = journal_mod.SideEffectJournal.init(allocator);
        self.prompts = prompt_mod.Registry.init(allocator);
        self.policy = policy_mod.PolicyEngine.init(allocator);
        self.ledger = policy_mod.AuditLedger.init(allocator);
        self.telemetry = telemetry_mod.TelemetrySink.init(allocator, options.telemetry_level);
        self.approvals = approval_mod.Gate.init(allocator, c, options.approval_mode);
        self.pipeline = middleware_mod.Pipeline.init(allocator);
        self.tracer = middleware_mod.TracingMiddleware.init(allocator);
        self.cancel_tree = cancel_mod.Tree.init(allocator);
        self.agents = registry_mod.Registry.init(allocator);
        self.plan_meter = budget_mod.Meter.init(options.plan_budget);

        try self.pipeline.use(self.tracer.middleware());
        if (options.load_default_policy) try self.policy.loadDefaults();
        if (options.load_builtin_prompts) try self.prompts.loadBuiltins();

        self.services = .{
            .allocator = allocator,
            .clock = c,
            .board = &self.board,
            .tools = &self.tools,
            .journal = &self.journal,
            .prompts = &self.prompts,
            .policy = &self.policy,
            .ledger = &self.ledger,
            .telemetry = &self.telemetry,
            .approvals = &self.approvals,
            .middleware = &self.pipeline,
            .cancel_tree = &self.cancel_tree,
        };
        self.executor = executor_mod.Executor.init(allocator, &self.services, &self.agents, options.executor);
        return self;
    }

    pub fn destroy(self: *Harness) void {
        const allocator = self.allocator;
        self.agents.deinit();
        self.cancel_tree.deinit();
        self.tracer.deinit();
        self.pipeline.deinit();
        self.approvals.deinit();
        self.telemetry.deinit();
        self.ledger.deinit();
        self.policy.deinit();
        self.prompts.deinit();
        self.journal.deinit();
        self.tools.deinit();
        self.board.deinit();
        allocator.destroy(self);
    }

    /// Compiles and runs a task list, returning the report.
    /// @example
    /// var report = try h.run(&tasks);
    /// defer report.deinit();
    pub fn run(self: *Harness, tasks: []const types.AgentTask) !executor_mod.RunReport {
        var plan = try executor_mod.Plan.compile(self.allocator, tasks, 1);
        defer plan.deinit();
        return self.executor.run(&plan, &self.plan_meter);
    }

    /// Registers a scripted agent factory (caller keeps ownership of `sf`).
    /// @example
    /// try h.registerScripted(&sf);
    pub fn registerScripted(self: *Harness, sf: *ScriptedFactory) !void {
        try self.agents.register(sf.factory());
    }
};

/// Builds a task with sensible test defaults.
/// @example
/// const task = makeTask(.{ .id = 1, .kind = .coder });
pub fn makeTask(overrides: struct {
    id: u128,
    parent_id: ?u128 = null,
    kind: types.AgentKind = .coder,
    mode: types.ExecutionMode = .sequential,
    title: []const u8 = "test task",
    prompt_template_id: u32 = 0,
    budget: ?types.TokenBudget = null,
}) types.AgentTask {
    return .{
        .id = overrides.id,
        .parent_id = overrides.parent_id,
        .kind = overrides.kind,
        .mode = overrides.mode,
        .state = .queued,
        .budget = overrides.budget orelse .{
            .soft_limit = 100_000,
            .hard_limit = 0,
            .downgrade_model_id = "test-local",
            .spend_limit_microunits = 0,
        },
        .memory = .{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 },
        .prompt_template_id = overrides.prompt_template_id,
        .rollback_journal_id = 0,
        .title = overrides.title,
    };
}

test "harness: wires every subsystem and runs a single node" {
    var h = try Harness.create(std.testing.allocator, .{});
    defer h.destroy();

    var sf = ScriptedFactory{
        .descriptor = .{ .id = "test.coder.v1", .kind = .coder },
        .script = .{ .summary = "done", .confidence = 90 },
    };
    try h.registerScripted(&sf);

    const tasks = [_]types.AgentTask{makeTask(.{ .id = 1 })};
    var report = try h.run(&tasks);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u32, 1), report.completed);
    try std.testing.expectEqualStrings("done", report.results[0].summary);
    try std.testing.expectEqual(@as(u32, 1), sf.attemptCount());
}

test "harness: scripted tool invocation flows through mediation" {
    var h = try Harness.create(std.testing.allocator, .{});
    defer h.destroy();

    try h.tools.register(echoTool("test.echo", .pure));

    var sf = ScriptedFactory{
        .descriptor = .{ .id = "test.coder.v1", .kind = .coder },
        .script = .{ .tool_id = "test.echo", .tool_input = "payload", .publish_key = "patch/x" },
    };
    try h.registerScripted(&sf);

    const tasks = [_]types.AgentTask{makeTask(.{ .id = 1 })};
    var report = try h.run(&tasks);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u32, 1), report.results[0].tool_calls);
    try std.testing.expectEqualStrings("artifact", h.board.get("patch/x").?);
    try std.testing.expectEqual(@as(usize, 1), h.tracer.countTool(.finish));
}

test "harness: makeTask defaults are valid for plan compilation" {
    const tasks = [_]types.AgentTask{
        makeTask(.{ .id = 1, .kind = .planner, .mode = .parallel_fanout }),
        makeTask(.{ .id = 2, .parent_id = 1, .kind = .coder }),
    };
    var plan = try executor_mod.Plan.compile(std.testing.allocator, &tasks, 1);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.nodeCount());
}

test "harness: parallel fanout runs every coder replica" {
    var h = try Harness.create(std.testing.allocator, .{ .executor = .{ .max_workers = 2 } });
    defer h.destroy();

    var sf = ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .summary = "patched" },
    };
    try h.registerScripted(&sf);
    var sp = ScriptedFactory{
        .descriptor = .{ .id = "planner", .kind = .planner },
        .script = .{ .summary = "planned" },
    };
    try h.registerScripted(&sp);

    const tasks = [_]types.AgentTask{
        makeTask(.{ .id = 1, .kind = .planner }),
        makeTask(.{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .parallel_fanout }),
        makeTask(.{ .id = 3, .parent_id = 1, .kind = .coder, .mode = .parallel_fanout }),
    };
    var report = try h.run(&tasks);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u32, 3), report.completed);
    try std.testing.expectEqual(@as(u32, 2), sf.attemptCount());
}

test "harness: debate consensus detects divergence" {
    var h = try Harness.create(std.testing.allocator, .{ .executor = .{ .debate_replicas = 3 } });
    defer h.destroy();

    var sf = ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .divergent_summaries = &.{ "alpha", "beta", "gamma" } },
    };
    try h.registerScripted(&sf);

    const tasks = [_]types.AgentTask{
        makeTask(.{ .id = 1, .kind = .coder, .mode = .debate_consensus }),
    };
    var report = try h.run(&tasks);
    defer report.deinit();

    try std.testing.expect(report.completed == 1);
    const c = report.results[0].consensus;
    try std.testing.expect(c != null);
    try std.testing.expect(c.?.distinct > 1);
}

test "harness: budget breach downgrades instead of failing" {
    var h = try Harness.create(std.testing.allocator, .{});
    defer h.destroy();

    var sf = ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .summary = "done", .tokens_in = 1_000_000, .tokens_out = 1_000_000 },
    };
    try h.registerScripted(&sf);

    const tasks = [_]types.AgentTask{
        makeTask(.{ .id = 1, .kind = .coder, .budget = .{
            .soft_limit = 10,
            .hard_limit = 0,
            .downgrade_model_id = "test-local",
            .spend_limit_microunits = 0,
        } }),
    };
    var report = try h.run(&tasks);
    defer report.deinit();

    // Soft-limit breach must downgrade the model, not abort the node.
    try std.testing.expectEqual(@as(u32, 1), report.completed);
}
