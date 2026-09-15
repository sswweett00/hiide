/// Top-level engine facade. Wires every subsystem, expands instructions into
/// plans, and runs them through the executor with full governance.
///
/// This is the single public entry point used by the runtime/app, the IPC C
/// ABI, and the CLI. It owns the lifecycle of all subsystems so callers do not
/// have to.
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
const planner_mod = @import("planner.zig");
const test_mod = @import("testing.zig");
const prompt_mod = @import("prompt.zig");
const registry_mod = @import("registry.zig");
const tool_mod = @import("tool.zig");

const Pipeline = middleware_mod.Pipeline;
const TracingMiddleware = middleware_mod.TracingMiddleware;

fn planBudget() types.TokenBudget {
    return .{
        .soft_limit = 1_000_000,
        .hard_limit = 0,
        .downgrade_model_id = "test-local",
        .spend_limit_microunits = 0,
    };
}

/// Factory that produces a fresh `PlannerAgent` instance per task node and
/// refreshes its instruction before every run, so the planner node can report
/// the chosen template for the current objective.
const PlannerFactory = struct {
    desc: agent_mod.AgentDescriptor = .{ .id = "planner", .kind = .planner },
    instruction: []const u8 = "",

    fn create(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!agent_mod.Agent {
        const self: *PlannerFactory = @ptrCast(@alignCast(ptr));
        const inst = try allocator.create(planner_mod.PlannerAgent);
        inst.* = .{ .instruction = self.instruction, .hint = null };
        return agent_mod.fromImpl(planner_mod.PlannerAgent, inst, self.desc);
    }

    fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator, instance: agent_mod.Agent) void {
        _ = ptr;
        const inst: *planner_mod.PlannerAgent = @ptrCast(@alignCast(instance.ctx));
        allocator.destroy(inst);
    }

    const vtable = registry_mod.Factory.VTable{ .create = create, .destroy = destroy };

    fn factory(self: *PlannerFactory) registry_mod.Factory {
        return .{ .descriptor = self.desc, .ctx = self, .owner = "core", .vtable = &vtable };
    }
};

pub const Options = struct {
    approval_mode: approval_mod.Mode = .auto_approve,
    telemetry_level: telemetry_mod.TelemetryLevel = .basic,
    manual_clock: bool = false,
    executor: executor_mod.Options = .{},
    plan_budget: types.TokenBudget = planBudget(),
};

/// The engine.
pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    owned_clock: ?clock_mod.ManualClock = null,
    board: blackboard_mod.Blackboard,
    tools: tool_mod.Registry,
    journal: journal_mod.SideEffectJournal,
    prompts: prompt_mod.Registry,
    policy: policy_mod.PolicyEngine,
    ledger: policy_mod.AuditLedger,
    telemetry: telemetry_mod.TelemetrySink,
    approvals: approval_mod.Gate,
    pipeline: Pipeline,
    tracer: TracingMiddleware,
    cancel_tree: cancel_mod.Tree,
    agents: registry_mod.Registry,
    services: context_mod.Services,
    executor: executor_mod.Executor,
    plan_meter: budget_mod.Meter,
    planner_factory: PlannerFactory,
    next_plan_id: std.atomic.Value(u128) = std.atomic.Value(u128).init(1),

    /// Constructs and wires the engine. Heap-allocated because `services`
    /// points at sibling fields.
    /// @example
    /// var engine = try Orchestrator.init(alloc, .{});
    /// defer engine.deinit();
    pub fn init(allocator: std.mem.Allocator, options: Options) !*Orchestrator {
        const self = try allocator.create(Orchestrator);
        errdefer allocator.destroy(self);

        // `allocator.create` leaves fields uninitialized; apply the field
        // defaults explicitly for fields not assigned below.
        self.planner_factory = .{};
        self.next_plan_id = std.atomic.Value(u128).init(1);
        self.owned_clock = null;

        self.allocator = allocator;
        var clock: clock_mod.Clock = undefined;
        if (options.manual_clock) {
            self.owned_clock = clock_mod.ManualClock.init(1_700_000_000_000);
            clock = self.owned_clock.?.clock();
        } else {
            clock = clock_mod.system();
        }

        self.board = blackboard_mod.Blackboard.init(allocator, clock);
        self.tools = tool_mod.Registry.init(allocator);
        self.journal = journal_mod.SideEffectJournal.init(allocator);
        self.prompts = prompt_mod.Registry.init(allocator);
        self.policy = policy_mod.PolicyEngine.init(allocator);
        self.ledger = policy_mod.AuditLedger.init(allocator);
        self.telemetry = telemetry_mod.TelemetrySink.init(allocator, options.telemetry_level);
        self.approvals = approval_mod.Gate.init(allocator, clock, options.approval_mode);
        self.pipeline = Pipeline.init(allocator);
        self.tracer = TracingMiddleware.init(allocator);
        self.cancel_tree = cancel_mod.Tree.init(allocator);
        self.agents = registry_mod.Registry.init(allocator);
        self.plan_meter = budget_mod.Meter.init(options.plan_budget);

        try self.pipeline.use(self.tracer.middleware());
        try self.policy.loadDefaults();
        try self.prompts.loadBuiltins();
        try self.agents.register(self.planner_factory.factory());

        self.services = .{
            .allocator = allocator,
            .clock = clock,
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

    pub fn deinit(self: *Orchestrator) void {
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

    /// Registers an agent factory (descriptor carried by the factory).
    /// @example
    /// try engine.registerAgent(factory);
    pub fn registerAgent(self: *Orchestrator, factory: registry_mod.Factory) !void {
        try self.agents.register(factory);
    }

    /// Registers a tool. Allowlisted and policy-classified automatically.
    /// @example
    /// try engine.registerTool(tool);
    pub fn registerTool(self: *Orchestrator, tool: tool_mod.Tool) !void {
        try self.tools.register(tool);
    }

    /// Loads default policy and builtin prompts (called by `init`).
    /// @example
    /// try engine.installDefaults();
    pub fn installDefaults(self: *Orchestrator) !void {
        try self.policy.loadDefaults();
        try self.prompts.loadBuiltins();
    }

    /// Expands an instruction into a plan and runs it to completion.
    /// @example
    /// var report = try engine.submit("implement the login form", null);
    pub fn submit(self: *Orchestrator, instruction: []const u8, hint: ?planner_mod.IntentKind) !executor_mod.RunReport {
        const intent = hint orelse planner_mod.classifyIntent(instruction);
        self.planner_factory.instruction = instruction;
        const id_base = self.next_plan_id.fetchAdd(1000, .acq_rel);
        const tasks = try planner_mod.plan(self.allocator, instruction, intent, id_base);
        defer self.allocator.free(tasks);
        return self.submitTasks(tasks);
    }

    /// Runs an already-constructed task list.
    /// @example
    /// var report = try engine.submitTasks(&tasks);
    pub fn submitTasks(self: *Orchestrator, tasks: []const types.AgentTask) !executor_mod.RunReport {
        var plan = try executor_mod.Plan.compile(self.allocator, tasks, 1);
        defer plan.deinit();
        return self.executor.run(&plan, &self.plan_meter);
    }

    /// Cancels a task and its subtree by node id.
    /// @example
    /// try engine.cancel(task_id);
    pub fn cancel(self: *Orchestrator, task_id: u128) !void {
        _ = try self.cancel_tree.cancelSubtree(task_id, .user_request);
    }

    /// Returns pending approval requests. Caller frees the slice with `alloc`.
    /// @example
    /// const queue = try engine.pendingApprovals(alloc);
    pub fn pendingApprovals(self: *Orchestrator, alloc: std.mem.Allocator) ![]approval_mod.Request {
        return self.approvals.pending(alloc);
    }

    /// Resolves an approval request. `decision` is `.approved` or `.rejected`.
    /// `by` identifies the human approver.
    /// @example
    /// try engine.resolveApproval(req.id, .approved, "alice@corp");
    pub fn resolveApproval(self: *Orchestrator, id: u64, decision: approval_mod.Decision, by: []const u8) !void {
        try self.approvals.resolve(id, decision, by);
    }

    /// Exposes the blackboard (for inspection / tests).
    /// @example
    /// const v = engine.blackboard().get("patch/x");
    pub fn blackboard(self: *Orchestrator) *blackboard_mod.Blackboard {
        return &self.board;
    }
};

test "orchestrator: submit runs a full codegen plan" {
    var engine = try Orchestrator.init(std.testing.allocator, .{ .manual_clock = true });
    defer engine.deinit();

    var sf = test_mod.ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .summary = "implemented", .confidence = 95 },
    };
    try engine.registerAgent(sf.factory());
    var sfr = test_mod.ScriptedFactory{
        .descriptor = .{ .id = "reviewer", .kind = .reviewer },
        .script = .{ .summary = "verified", .confidence = 98 },
    };
    try engine.registerAgent(sfr.factory());

    var report = try engine.submit("implement the login form", null);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u32, 3), report.completed);
    try std.testing.expectEqualStrings("verified", report.results[2].summary);
}

test "orchestrator: agent error surfaces in the report" {
    var engine = try Orchestrator.init(std.testing.allocator, .{ .manual_clock = true });
    defer engine.deinit();

    var sf = test_mod.ScriptedFactory{
        .descriptor = .{ .id = "coder", .kind = .coder },
        .script = .{ .permanent_error = error.AgentFailed, .summary = "never" },
    };
    try engine.registerAgent(sf.factory());

    const tasks = [_]types.AgentTask{test_mod.makeTask(.{ .id = 1, .kind = .coder })};
    var report = try engine.submitTasks(&tasks);
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(u32, 0), report.completed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    try std.testing.expectEqual(@as(u32, 1), sf.attemptCount());
}
