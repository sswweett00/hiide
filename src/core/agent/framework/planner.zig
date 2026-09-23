/// Deterministic planning layer: turns a natural-language instruction into a
/// validated `AgentTask` DAG.
///
/// Spec §1.1 (agent selection & routing) and §5 (plugin contribution to plans).
/// The planner is intentionally heuristic and *deterministic*: it never calls a
/// model, so integration tests can assert on the exact shape of the produced
/// graph.
const std = @import("std");
const types = @import("../types.zig");
const agent_mod = @import("agent.zig");
const prompt_mod = @import("prompt.zig");

/// High-level intent buckets derived from the instruction text.
pub const IntentKind = enum {
    codegen,
    multi_edit,
    review,
    research,
    debate,
    security_audit,
    refactor,
    generic,

    pub fn name(self: IntentKind) []const u8 {
        return switch (self) {
            .codegen => "codegen",
            .multi_edit => "multi_edit",
            .review => "review",
            .research => "research",
            .debate => "debate",
            .security_audit => "security_audit",
            .refactor => "refactor",
            .generic => "generic",
        };
    }
};

/// One step in a plan template. `depends_on` indexes into the template's
/// `steps` array (not task ids).
pub const StepSpec = struct {
    kind: types.AgentKind,
    mode: types.ExecutionMode = .sequential,
    title: []const u8,
    template_id: u32 = 0,
    depends_on: []const usize = &.{},
};

/// A reusable plan shape. Templates are contributed by core and by plugins.
pub const PlanTemplate = struct {
    id: []const u8,
    intent: IntentKind,
    steps: []const StepSpec,
    budget: types.TokenBudget,
};

/// One prebuilt template.
pub const TEMPLATES: [8]PlanTemplate = .{
    .{
        .id = "codegen",
        .intent = .codegen,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .planner, .title = "draft plan", .template_id = 0 },
            .{ .kind = .coder, .title = "implement", .depends_on = &.{0} },
            .{ .kind = .reviewer, .title = "verify", .depends_on = &.{1} },
        },
    },
    .{
        .id = "multi_edit",
        .intent = .multi_edit,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .planner, .title = "split work", .template_id = 0 },
            .{ .kind = .coder, .title = "edit A", .mode = .parallel_fanout, .depends_on = &.{0} },
            .{ .kind = .coder, .title = "edit B", .mode = .parallel_fanout, .depends_on = &.{0} },
            .{ .kind = .reviewer, .title = "verify", .depends_on = &.{ 1, 2 } },
        },
    },
    .{
        .id = "review",
        .intent = .review,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .reviewer, .title = "review change" },
            .{ .kind = .tester, .title = "validate", .depends_on = &.{0} },
        },
    },
    .{
        .id = "research",
        .intent = .research,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .researcher, .title = "investigate" },
            .{ .kind = .coder, .title = "apply findings", .depends_on = &.{0} },
        },
    },
    .{
        .id = "debate",
        .intent = .debate,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .planner, .title = "frame question", .template_id = 0 },
            .{ .kind = .coder, .title = "deliberate", .mode = .debate_consensus, .depends_on = &.{0} },
        },
    },
    .{
        .id = "security_audit",
        .intent = .security_audit,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .security_auditor, .title = "audit security", .template_id = prompt_mod.builtin_id.security_auditor },
            .{ .kind = .tester, .title = "validate controls", .template_id = prompt_mod.builtin_id.tester, .depends_on = &.{0} },
        },
    },
    .{
        .id = "refactor",
        .intent = .refactor,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .refactor_specialist, .title = "design refactor", .template_id = prompt_mod.builtin_id.refactor_specialist },
            .{ .kind = .coder, .title = "apply refactor", .template_id = prompt_mod.builtin_id.coder, .depends_on = &.{0} },
            .{ .kind = .reviewer, .title = "verify invariants", .template_id = prompt_mod.builtin_id.reviewer, .depends_on = &.{1} },
        },
    },
    .{
        .id = "generic",
        .intent = .generic,
        .budget = defaultBudget(),
        .steps = &.{
            .{ .kind = .planner, .title = "plan", .template_id = 0 },
            .{ .kind = .coder, .title = "act", .depends_on = &.{0} },
        },
    },
};

fn defaultBudget() types.TokenBudget {
    return .{
        .soft_limit = 200_000,
        .hard_limit = 0,
        .downgrade_model_id = "test-local",
        .spend_limit_microunits = 0,
    };
}

/// Keyword classifier. Pure and side-effect free.
/// @example
/// const intent = classifyIntent("implement the login form");
pub fn classifyIntent(instruction: []const u8) IntentKind {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, instruction) catch {
        // Fallback: exact compare on slices of the original.
        return classifyIntentFallback(instruction);
    };
    defer std.heap.page_allocator.free(lower);

    const rules = [_]struct { kw: []const u8, intent: IntentKind }{
        .{ .kw = "review", .intent = .review },
        .{ .kw = "audit", .intent = .review },
        .{ .kw = "security", .intent = .security_audit },
        .{ .kw = "vulnerability", .intent = .security_audit },
        .{ .kw = "exploit", .intent = .security_audit },
        .{ .kw = "research", .intent = .research },
        .{ .kw = "investigate", .intent = .research },
        .{ .kw = "debate", .intent = .debate },
        .{ .kw = "deliberate", .intent = .debate },
        .{ .kw = "refactor", .intent = .refactor },
        .{ .kw = "cleanup", .intent = .refactor },
        .{ .kw = "multi", .intent = .multi_edit },
        .{ .kw = "parallel", .intent = .multi_edit },
        .{ .kw = "implement", .intent = .codegen },
        .{ .kw = "build", .intent = .codegen },
        .{ .kw = "create", .intent = .codegen },
        .{ .kw = "add", .intent = .codegen },
    };
    for (rules) |r| {
        if (std.mem.indexOf(u8, lower, r.kw) != null) return r.intent;
    }
    return .generic;
}

fn classifyIntentFallback(instruction: []const u8) IntentKind {
    const rules = [_]struct { kw: []const u8, intent: IntentKind }{
        .{ .kw = "security", .intent = .security_audit },
        .{ .kw = "refactor", .intent = .refactor },
        .{ .kw = "review", .intent = .review },
        .{ .kw = "research", .intent = .research },
        .{ .kw = "debate", .intent = .debate },
        .{ .kw = "multi", .intent = .multi_edit },
        .{ .kw = "implement", .intent = .codegen },
    };
    for (rules) |r| {
        if (std.mem.indexOf(u8, instruction, r.kw) != null) return r.intent;
    }
    return .generic;
}

/// Finds the template matching an intent (or falls back to generic).
/// @example
/// const t = templateFor(.codegen);
pub fn templateFor(intent: IntentKind) PlanTemplate {
    for (TEMPLATES) |t| {
        if (t.intent == intent) return t;
    }
    return TEMPLATES[TEMPLATES.len - 1];
}

/// Produces an `AgentTask` DAG for an instruction. Task ids are assigned
/// sequentially starting at `id_base + 1` and are unique within the plan.
/// @example
/// const tasks = try plan(alloc, "implement feature X", null, 0);
fn promptTemplateForKind(kind: types.AgentKind) u32 {
    return switch (kind) {
        .planner => prompt_mod.builtin_id.planner,
        .coder => prompt_mod.builtin_id.coder,
        .reviewer => prompt_mod.builtin_id.reviewer,
        .tester => prompt_mod.builtin_id.tester,
        .researcher => prompt_mod.builtin_id.researcher,
        .security_auditor => prompt_mod.builtin_id.security_auditor,
        .documentation_writer => prompt_mod.builtin_id.documentation_writer,
        .refactor_specialist => prompt_mod.builtin_id.refactor_specialist,
    };
}

pub fn plan(
    allocator: std.mem.Allocator,
    instruction: []const u8,
    hint: ?IntentKind,
    id_base: u128,
) ![]types.AgentTask {
    const intent = hint orelse classifyIntent(instruction);
    const template = templateFor(intent);
    const steps = template.steps;

    var tasks = try allocator.alloc(types.AgentTask, steps.len);
    errdefer allocator.free(tasks);

    var i: usize = 0;
    while (i < steps.len) : (i += 1) {
        const step = steps[i];
        var parent_id: ?u128 = null;
        if (step.depends_on.len > 0) {
            // First declared dependency defines the task tree parent.
            parent_id = id_base + 1 + step.depends_on[0];
        }
        tasks[i] = .{
            .id = id_base + 1 + i,
            .parent_id = parent_id,
            .kind = step.kind,
            .mode = step.mode,
            .state = .queued,
            .budget = template.budget,
            .memory = .{
                .symbol_snapshot_id = 0,
                .task_graph_id = 0,
                .policy_snapshot_id = 0,
                .artifact_set_id = 0,
            },
            .prompt_template_id = if (step.template_id != 0) step.template_id else promptTemplateForKind(step.kind),
            .rollback_journal_id = 0,
            .title = step.title,
            .objective = instruction,
        };
    }
    return tasks;
}

/// A planner agent that records the chosen template as its summary. It does not
/// itself execute sub-tasks; the orchestrator expands the plan.
///
/// The summary lives in a per-instance buffer, so each task node gets its own
/// instance (the factory creates one per `create`) and the pointer stays valid
/// for the agent's lifetime without heap allocation.
pub const PlannerAgent = struct {
    instruction: []const u8,
    hint: ?IntentKind,
    summary_buf: [128]u8 = undefined,

    /// Returns the planned template name and step count.
    /// @example
    /// const out = try agent.run(&ctx);
    pub fn run(self: *PlannerAgent, ctx: *agent_mod.AgentContext) anyerror!agent_mod.AgentOutput {
        try ctx.checkCancel();
        const objective = if (ctx.task.objective.len > 0) ctx.task.objective else self.instruction;
        const intent = self.hint orelse classifyIntent(objective);
        const t = templateFor(intent);
        const summary = try std.fmt.bufPrint(
            &self.summary_buf,
            "plan:{s}:steps={d}",
            .{ t.id, t.steps.len },
        );
        var output = agent_mod.AgentOutput.fromSummary(summary, 100);
        output.tokens_out = 8;
        return output;
    }

    /// Builds a self-pointer agent with the given descriptor.
    /// @example
    /// const a = try PlannerAgent.asAgent(alloc, desc, "do X", null);
    pub fn asAgent(
        allocator: std.mem.Allocator,
        descriptor: agent_mod.AgentDescriptor,
        instruction: []const u8,
        hint: ?IntentKind,
    ) !agent_mod.Agent {
        const self = try allocator.create(PlannerAgent);
        self.* = .{ .instruction = instruction, .hint = hint };
        return agent_mod.fromImpl(PlannerAgent, self, descriptor);
    }
};

test "planner: classifyIntent picks codegen" {
    try std.testing.expectEqual(IntentKind.codegen, classifyIntent("implement the login form"));
    try std.testing.expectEqual(IntentKind.review, classifyIntent("review the diff"));
    try std.testing.expectEqual(IntentKind.multi_edit, classifyIntent("multi-file parallel edit"));
    try std.testing.expectEqual(IntentKind.generic, classifyIntent("do something vague"));
}

test "planner: plan produces a valid DAG with parent links" {
    const tasks = try plan(std.testing.allocator, "implement feature", null, 0);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqual(@as(types.AgentKind, .planner), tasks[0].kind);
    try std.testing.expectEqual(@as(?u128, null), tasks[0].parent_id);
    try std.testing.expectEqual(@as(u128, 1), tasks[1].parent_id.?);
    try std.testing.expectEqual(@as(u128, 2), tasks[2].parent_id.?);
}

test "planner: every generated node resolves to a built-in prompt" {
    const tasks = try plan(std.testing.allocator, "implement feature", null, 0);
    defer std.testing.allocator.free(tasks);
    for (tasks) |task| {
        try std.testing.expect(task.prompt_template_id > 0);
    }
}

test "planner: objective is propagated to every node" {
    const objective = "fix authentication race in session store";
    const tasks = try plan(std.testing.allocator, objective, null, 0);
    defer std.testing.allocator.free(tasks);
    for (tasks) |task| {
        try std.testing.expectEqualStrings(objective, task.objective);
    }
}

test "planner: security and refactor intents select specialised pipelines" {
    try std.testing.expectEqual(IntentKind.security_audit, classifyIntent("security audit the IPC surface"));
    try std.testing.expectEqual(IntentKind.refactor, classifyIntent("refactor the provider router"));
    try std.testing.expectEqual(@as(types.AgentKind, .security_auditor), templateFor(.security_audit).steps[0].kind);
    try std.testing.expectEqual(@as(types.AgentKind, .refactor_specialist), templateFor(.refactor).steps[0].kind);
}

test "planner: multi_edit fans out two coders" {
    const tasks = try plan(std.testing.allocator, "parallel multi edit", null, 10);
    defer std.testing.allocator.free(tasks);
    try std.testing.expectEqual(@as(types.ExecutionMode, .parallel_fanout), tasks[1].mode);
    try std.testing.expectEqual(@as(types.ExecutionMode, .parallel_fanout), tasks[2].mode);
    try std.testing.expectEqual(@as(u128, 12), tasks[1].id);
    try std.testing.expectEqual(@as(u128, 13), tasks[2].id);
}
