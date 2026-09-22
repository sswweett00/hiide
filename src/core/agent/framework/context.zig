/// Agent execution context and the shared service bundle.
///
/// `AgentContext` is the only channel through which an agent can affect the
/// world. `invokeTool` implements the mediation pipeline mandated by spec §1.4:
///
///   cancel check → allowlist → classify → policy → redact → approval gate →
///   journal (pre-write) → execute → budget charge → journal approve →
///   telemetry + audit ledger
///
/// Every step is fail-closed: an error anywhere leaves the journal entry
/// pending, so `rollbackAll` discards the speculative effect.
const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("../types.zig");
const journal_mod = @import("../journal.zig");
const classifier = @import("../../security/classifier.zig");
const policy_mod = @import("../../security/policy.zig");
const provider_mod = @import("../../provider/router.zig");
const telemetry_mod = @import("../../telemetry/collector.zig");
const approval_mod = @import("approval.zig");
const blackboard_mod = @import("blackboard.zig");
const budget_mod = @import("budget.zig");
const cancel_mod = @import("cancel.zig");
const clock_mod = @import("clock.zig");
const middleware_mod = @import("middleware.zig");
const prompt_mod = @import("prompt.zig");
const tool_mod = @import("tool.zig");

pub const ContextError = error{
    ToolNotFound,
    CapabilityViolation,
    PolicyDenied,
    ApprovalRejected,
    ApprovalTimeout,
    SpeculativeMutationDenied,
    ToolFailed,
    ToolTimeout,
    BudgetExhausted,
    SpendLimitExceeded,
    Canceled,
    DeadlineExceeded,
    NoEligibleProvider,
    OutOfMemory,
};

/// Caller identity attached to policy input and audit records.
pub const Identity = struct {
    user_id: []const u8 = "local",
    workspace_id: []const u8 = "default",
    tenant_id: []const u8 = "default",
};

/// Shared, long-lived subsystems. One instance per engine; agents receive a
/// pointer. Subsystems that are not internally synchronized are guarded here.
pub const Services = struct {
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    board: *blackboard_mod.Blackboard,
    tools: *tool_mod.Registry,
    journal: *journal_mod.SideEffectJournal,

    prompts: ?*prompt_mod.Registry = null,
    policy: ?*policy_mod.PolicyEngine = null,
    ledger: ?*policy_mod.AuditLedger = null,
    router: ?*provider_mod.Router = null,
    telemetry: ?*telemetry_mod.TelemetrySink = null,
    approvals: ?*approval_mod.Gate = null,
    middleware: ?*middleware_mod.Pipeline = null,
    cancel_tree: ?*cancel_mod.Tree = null,

    identity: Identity = .{},
    tenant: provider_mod.TenantConfig = .{
        .allow_byok = true,
        .allow_managed = true,
        .allow_self_hosted = true,
        .allowed_provider_ids = &.{},
    },
    workspace_root: []const u8 = ".",

    // Guards for subsystems whose public APIs are not thread-safe.
    journal_mutex: compat.Mutex = .init,
    ledger_mutex: compat.Mutex = .init,
    telemetry_mutex: compat.Mutex = .init,
    router_mutex: compat.Mutex = .init,

    /// Records a metric, tolerating a saturated sink.
    /// @example
    /// services.metric("agent.retry", .{ .u64 = 1 });
    pub fn metric(self: *Services, name: []const u8, value: telemetry_mod.MetricValue) void {
        const sink = self.telemetry orelse return;
        self.telemetry_mutex.lock();
        defer self.telemetry_mutex.unlock();
        sink.record(.{
            .name = name,
            .ts_unix_ms = self.clock.nowMs(),
            .attrs = &.{},
            .value = value,
        }) catch {};
    }

    /// Appends a tamper-evident audit record.
    /// @example
    /// services.audit(record);
    pub fn audit(self: *Services, record: policy_mod.AuditRecord) void {
        const ledger = self.ledger orelse return;
        self.ledger_mutex.lock();
        defer self.ledger_mutex.unlock();
        ledger.append(record) catch {};
    }

    /// Reserves a journal entry before a mutating effect executes.
    /// @example
    /// const id = try services.journalRecord(.file_write, task_id, payload);
    pub fn journalRecord(
        self: *Services,
        kind: journal_mod.JournalEntryKind,
        task_id: u128,
        payload: []const u8,
    ) !u64 {
        self.journal_mutex.lock();
        defer self.journal_mutex.unlock();
        return self.journal.record(kind, task_id, payload);
    }

    /// Marks a journal entry approved for commit.
    /// @example
    /// try services.journalApprove(entry_id);
    pub fn journalApprove(self: *Services, entry_id: u64) !void {
        self.journal_mutex.lock();
        defer self.journal_mutex.unlock();
        return self.journal.approve(entry_id);
    }

    /// Discards every non-committed journal entry (plan-level rollback).
    /// @example
    /// services.journalRollback();
    pub fn journalRollback(self: *Services) void {
        self.journal_mutex.lock();
        defer self.journal_mutex.unlock();
        self.journal.rollbackAll();
    }

    /// Selects a provider/model under tenant policy.
    /// @example
    /// const route = try services.route(req, alloc);
    pub fn route(
        self: *Services,
        req: provider_mod.RouteRequest,
        alloc: std.mem.Allocator,
    ) provider_mod.RouterError!provider_mod.RouteDecision {
        const router = self.router orelse return provider_mod.RouterError.NoEligibleProvider;
        self.router_mutex.lock();
        defer self.router_mutex.unlock();
        return router.select(req, self.tenant, alloc);
    }

    /// Reports a provider failure to the circuit breaker.
    /// @example
    /// services.reportProviderFailure("openai");
    pub fn reportProviderFailure(self: *Services, provider_id: []const u8) void {
        const router = self.router orelse return;
        self.router_mutex.lock();
        defer self.router_mutex.unlock();
        router.recordFailure(provider_id) catch {};
    }
};

/// Per-invocation statistics surfaced to the executor and telemetry.
pub const RunStats = struct {
    tool_calls: u32 = 0,
    tool_failures: u32 = 0,    approvals_requested: u32 = 0,
    redactions: u32 = 0,
    policy_denials: u32 = 0,
    artifacts_published: u32 = 0,
};

/// Execution context for a single agent attempt.
/// The allocator is a per-task arena owned by the executor; anything allocated
/// through it is released when the node completes, satisfying the "immutable
/// artifacts in per-task arenas" contract of spec §1.3.
pub const AgentContext = struct {
    allocator: std.mem.Allocator,
    services: *Services,
    task: types.AgentTask,
    agent_id: []const u8,
    kind: types.AgentKind,
    cancel: *cancel_mod.Token,
    budget: *budget_mod.Meter,
    allowed_tools: []const []const u8 = &.{},
    attempt: u16 = 0,
    /// Speculative attempts quarantine their artifacts and journal entries.
    speculative: bool = false,
    /// Model chosen for this attempt, if the router was consulted.
    model: ?provider_mod.RouteDecision = null,
    stats: RunStats = .{},

    /// Await-point cancellation/deadline check.
    /// @example
    /// try ctx.checkCancel();
    pub fn checkCancel(self: *AgentContext) cancel_mod.CancelError!void {
        return self.cancel.check(self.services.clock);
    }

    /// Milliseconds remaining before the task deadline.
    /// @example
    /// const left = ctx.remainingMs();
    pub fn remainingMs(self: *AgentContext) ?u64 {
        return self.cancel.remainingMs(self.services.clock);
    }

    /// Publishes an artifact to the shared blackboard.
    /// @example
    /// const handle = try ctx.publish("patch/main.zig", .patch_candidate, diff, .internal);
    pub fn publish(
        self: *AgentContext,
        key: []const u8,
        kind: blackboard_mod.ArtifactKind,
        bytes: []const u8,
        classification: classifier.Classification,
    ) !blackboard_mod.Handle {
        const handle = try self.services.board.put(key, kind, bytes, .{
            .classification = classification,
            .task_id = self.task.id,
            .speculative = self.speculative,
        });
        self.stats.artifacts_published += 1;
        return handle;
    }

    /// Reads the newest committed artifact for `key`.
    /// @example
    /// const patch = ctx.read("patch/main.zig") orelse return;
    pub fn read(self: *AgentContext, key: []const u8) ?[]const u8 {
        return self.services.board.get(key);
    }

    /// Reads an artifact including this task's own speculative writes.
    /// @example
    /// const draft = ctx.readOwn("patch/main.zig");
    pub fn readOwn(self: *AgentContext, key: []const u8) ?[]const u8 {
        return self.services.board.getSpeculative(key, self.task.id);
    }

    /// Renders the agent's prompt template into the task arena.
    /// @example
    /// const prompt = try ctx.renderPrompt(&.{ .{ .key = "task", .value = title } });
    pub fn renderPrompt(self: *AgentContext, vars: []const prompt_mod.Var) ![]u8 {
        const registry = self.services.prompts orelse return prompt_mod.PromptError.TemplateNotFound;
        return registry.render(self.allocator, self.task.prompt_template_id, vars);
    }

    /// Charges the budget meter and returns the resulting verdict.
    /// @example
    /// const verdict = try ctx.charge(.{ .tokens_in = 800, .tokens_out = 120 });
    pub fn charge(self: *AgentContext, c: budget_mod.Charge) budget_mod.BudgetError!budget_mod.Verdict {
        return self.budget.charge(c);
    }

    /// Selects a provider/model honouring the descriptor's capability needs and
    /// the blackboard's current classification ceiling.
    /// @example
    /// const route = try ctx.selectModel(caps, 1);
    pub fn selectModel(
        self: *AgentContext,
        capabilities: provider_mod.ModelCapabilities,
        latency_class: u8,
    ) !provider_mod.RouteDecision {
        const max_class = self.services.board.maxClassification();
        const decision = try self.services.route(.{
            .required_capabilities = capabilities,
            .latency_class = latency_class,
            .max_cost_1k = 0,
            .max_classification = @intFromEnum(max_class),
        }, self.allocator);
        self.model = decision;
        return decision;
    }

    /// Emits a metric scoped to this task.
    /// @example
    /// ctx.metric("agent.plan_nodes", .{ .u64 = 12 });
    pub fn metric(self: *AgentContext, name: []const u8, value: telemetry_mod.MetricValue) void {
        self.services.metric(name, value);
    }

    /// Requests human approval outside a tool call (e.g. plan-level gate).
    /// @example
    /// try ctx.requestApproval("apply 12-file refactor", "refactor/plan", .workspace_write);
    pub fn requestApproval(
        self: *AgentContext,
        summary: []const u8,
        detail: []const u8,
        side_effect: tool_mod.SideEffectClass,
    ) !approval_mod.Decision {
        const gate = self.services.approvals orelse return ContextError.ApprovalRejected;
        self.stats.approvals_requested += 1;
        return gate.requestAndWait(.{
            .task_id = self.task.id,
            .agent_id = self.agent_id,
            .tool_id = "",
            .side_effect = side_effect,
            .summary = summary,
            .detail = detail,
        }, self.cancel);
    }

    /// Invokes a tool through the full mediation pipeline.
    /// @example
    /// const result = try ctx.invokeTool("workspace.read_file", "src/main.zig");
    pub fn invokeTool(self: *AgentContext, tool_id: []const u8, input: []const u8) !tool_mod.ToolResult {
        try self.checkCancel();

        const tool = self.services.tools.get(tool_id) orelse return ContextError.ToolNotFound;
        if (!tool_mod.isAllowed(self.allowed_tools, tool_id)) return ContextError.CapabilityViolation;

        const side_effect = tool.spec.side_effect;
        if (self.speculative and side_effect.isMutating()) {
            self.stats.tool_failures += 1;
            self.finishToolEvent(tool_id, side_effect, false, 0, 0, ContextError.SpeculativeMutationDenied);
            return ContextError.SpeculativeMutationDenied;
        }
        self.stats.tool_calls += 1;

        if (self.services.middleware) |pipeline| {
            pipeline.notifyTool(.{
                .phase = .start,
                .task_id = self.task.id,
                .agent_id = self.agent_id,
                .tool_id = tool_id,
                .side_effect = side_effect,
                .attempt = self.attempt,
                .input_bytes = @intCast(@min(input.len, std.math.maxInt(u32))),
            });
        }

        var effective_input = input;
        var redacted = false;
        var needs_approval = tool.spec.needsApproval();

        // ── policy mediation ────────────────────────────────────────────────
        if (self.services.policy) |policy| {
            const classification = try classifier.ContentClassifier.classify(input, self.allocator);
            const verdict = policy.evaluate(.{
                .user_id = self.services.identity.user_id,
                .action = side_effect.policyAction(),
                .provider_id = if (self.model) |m| m.provider_id else "local",
                .model_id = if (self.model) |m| m.model_id else "local",
                .classifications = &[_]classifier.Classification{classification.max_class},
                .workspace_id = self.services.identity.workspace_id,
            }) catch |err| {
                self.finishToolEvent(tool_id, side_effect, false, 0, 0, err);
                return err;
            };

            switch (verdict.decision) {
                .deny => {
                    self.stats.policy_denials += 1;
                    self.services.metric("tool.policy_denied", .{ .u64 = 1 });
                    self.finishToolEvent(tool_id, side_effect, false, 0, 0, ContextError.PolicyDenied);
                    return ContextError.PolicyDenied;
                },
                .redact => {
                    effective_input = try classifier.ContentClassifier.redact(
                        input,
                        classification.spans,
                        self.allocator,
                    );
                    redacted = true;
                    self.stats.redactions += 1;
                },
                .require_approval => needs_approval = true,
                .allow => {},
            }
        }

        // ── human-in-the-loop gate ──────────────────────────────────────────
        var approved = !needs_approval;
        if (needs_approval) {
            if (self.services.approvals) |gate| {
                self.stats.approvals_requested += 1;
                _ = gate.requestAndWait(.{
                    .task_id = self.task.id,
                    .agent_id = self.agent_id,
                    .tool_id = tool_id,
                    .side_effect = side_effect,
                    .summary = tool.spec.description,
                    .detail = truncate(effective_input, 256),
                }, self.cancel) catch |err| {
                    self.finishToolEvent(tool_id, side_effect, false, 0, 0, err);
                    return err;
                };
                approved = true;
            } else {
                // Fail closed: no gate wired means no approval is possible.
                self.finishToolEvent(tool_id, side_effect, false, 0, 0, ContextError.ApprovalRejected);
                return ContextError.ApprovalRejected;
            }
        }

        // ── journal the intended mutation before executing it ───────────────
        var entry_id: ?u64 = null;
        if (side_effect.journalKind()) |journal_kind| {
            entry_id = self.services.journalRecord(journal_kind, self.task.id, effective_input) catch |err| {
                self.finishToolEvent(tool_id, side_effect, false, 0, 0, err);
                return err;
            };
        }

        // ── execute ─────────────────────────────────────────────────────────
        var tool_ctx = tool_mod.ToolContext{
            .allocator = self.allocator,
            .task_id = self.task.id,
            .agent_id = self.agent_id,
            .cancel = self.cancel,
            .clock = self.services.clock,
            .workspace_root = self.services.workspace_root,
            .attempt = self.attempt,
            .journal_entry_id = entry_id,
        };

        const sw = clock_mod.Stopwatch.start(self.services.clock);
        var result = tool.invoke(&tool_ctx, effective_input) catch |err| {
            self.stats.tool_failures += 1;
            self.services.metric("tool.failure", .{ .u64 = 1 });
            self.finishToolEventFull(tool_id, side_effect, false, sw.elapsedMs(), 0, approved, redacted, err);
            return err;
        };
        result.latency_ms = sw.elapsedMs();

        if (!result.ok) {
            self.stats.tool_failures += 1;
            self.finishToolEventFull(tool_id, side_effect, false, result.latency_ms, result.output.len, approved, redacted, ContextError.ToolFailed);
            return ContextError.ToolFailed;
        }

        // ── account, commit, observe ────────────────────────────────────────
        _ = self.charge(.{
            .tokens_in = result.tokens_in,
            .tokens_out = result.tokens_out,
            .microunits = result.microunits,
        }) catch |err| {
            // Budget overrun after a successful effect: keep the journal entry
            // pending so the plan-level rollback can undo it.
            self.finishToolEventFull(tool_id, side_effect, true, result.latency_ms, result.output.len, approved, redacted, err);
            return err;
        };

        // Non-speculative effects become committable immediately; speculative
        // ones stay pending until the branch is promoted.
        if (entry_id) |id| {
            if (!self.speculative) self.services.journalApprove(id) catch {};
        }

        self.services.audit(.{
            .ts_unix_ms = self.services.clock.nowMs(),
            .user_id_hash = hashOf(self.services.identity.user_id),
            .prompt_hash = hashOf(effective_input),
            .response_hash = hashOf(result.output),
            .provider_id = if (self.model) |m| m.provider_id else "local",
            .model_id = if (self.model) |m| m.model_id else tool_id,
            .latency_ms = result.latency_ms,
            .input_tokens = result.tokens_in,
            .output_tokens = result.tokens_out,
            .decision = .allow,
        });

        self.finishToolEventFull(tool_id, side_effect, true, result.latency_ms, result.output.len, approved, redacted, null);
        return result;
    }

    fn finishToolEvent(
        self: *AgentContext,
        tool_id: []const u8,
        side_effect: tool_mod.SideEffectClass,
        ok: bool,
        latency_ms: u32,
        output_len: usize,
        err: ?anyerror,
    ) void {
        self.finishToolEventFull(tool_id, side_effect, ok, latency_ms, output_len, false, false, err);
    }

    fn finishToolEventFull(
        self: *AgentContext,
        tool_id: []const u8,
        side_effect: tool_mod.SideEffectClass,
        ok: bool,
        latency_ms: u32,
        output_len: usize,
        approved: bool,
        redacted: bool,
        err: ?anyerror,
    ) void {
        const pipeline = self.services.middleware orelse return;
        pipeline.notifyTool(.{
            .phase = .finish,
            .task_id = self.task.id,
            .agent_id = self.agent_id,
            .tool_id = tool_id,
            .side_effect = side_effect,
            .attempt = self.attempt,
            .output_bytes = @intCast(@min(output_len, std.math.maxInt(u32))),
            .ok = ok,
            .approved = approved,
            .redacted = redacted,
            .latency_ms = latency_ms,
            .err = err,
        });
    }
};

fn hashOf(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;}

fn truncate(bytes: []const u8, max_len: usize) []const u8 {
    return bytes[0..@min(bytes.len, max_len)];
}

// ─── tests ───────────────────────────────────────────────────────────────────

const TestHarness = struct {
    arena: std.heap.ArenaAllocator,
    board: blackboard_mod.Blackboard,
    tools: tool_mod.Registry,
    journal: journal_mod.SideEffectJournal,
    policy: policy_mod.PolicyEngine,
    ledger: policy_mod.AuditLedger,
    sink: telemetry_mod.TelemetrySink,
    gate: approval_mod.Gate,
    pipeline: middleware_mod.Pipeline,
    tracer: middleware_mod.TracingMiddleware,
    services: Services,
    token: cancel_mod.Token,
    meter: budget_mod.Meter,

    fn init(alloc: std.mem.Allocator, self: *TestHarness) !void {
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.board = blackboard_mod.Blackboard.init(alloc, clock_mod.system());
        self.tools = tool_mod.Registry.init(alloc);
        self.journal = journal_mod.SideEffectJournal.init(alloc);
        self.policy = policy_mod.PolicyEngine.init(alloc);
        self.ledger = policy_mod.AuditLedger.init(alloc);
        self.sink = telemetry_mod.TelemetrySink.init(alloc, .basic);
        self.gate = approval_mod.Gate.init(alloc, clock_mod.system(), .auto_approve);
        self.pipeline = middleware_mod.Pipeline.init(alloc);
        self.tracer = middleware_mod.TracingMiddleware.init(alloc);
        try self.pipeline.use(self.tracer.middleware());
        try self.policy.loadDefaults();

        self.token = cancel_mod.Token.init(null);
        self.meter = budget_mod.Meter.init(types.TokenBudget.defaultPlanning());
        self.services = .{
            .allocator = alloc,
            .clock = clock_mod.system(),
            .board = &self.board,
            .tools = &self.tools,
            .journal = &self.journal,
            .policy = &self.policy,
            .ledger = &self.ledger,
            .telemetry = &self.sink,
            .approvals = &self.gate,
            .middleware = &self.pipeline,
        };
    }

    fn deinit(self: *TestHarness) void {
        self.pipeline.deinit();
        self.tracer.deinit();
        self.gate.deinit();
        self.sink.deinit();
        self.ledger.deinit();
        self.policy.deinit();
        self.journal.deinit();
        self.tools.deinit();
        self.board.deinit();
        self.arena.deinit();
    }

    fn context(self: *TestHarness) AgentContext {
        return .{
            .allocator = self.arena.allocator(),
            .services = &self.services,
            .task = .{
                .id = 42,
                .parent_id = null,
                .kind = .coder,
                .mode = .sequential,
                .state = .running,
                .budget = types.TokenBudget.defaultPlanning(),
                .memory = .{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 },
                .prompt_template_id = prompt_mod.builtin_id.coder,
                .rollback_journal_id = 0,
                .title = "test task",
            },
            .agent_id = "test.agent.v1",
            .kind = .coder,
            .cancel = &self.token,
            .budget = &self.meter,
        };
    }
};

fn echoTool(tool_ctx: *tool_mod.ToolContext, input: []const u8) anyerror!tool_mod.ToolResult {
    var result = tool_mod.ToolResult.success(try tool_ctx.allocator.dupe(u8, input));
    result.tokens_in = 10;
    result.tokens_out = 5;
    return result;
}

fn failingTool(_: *tool_mod.ToolContext, _: []const u8) anyerror!tool_mod.ToolResult {
    return error.ToolFailed;
}

test "context: pure tool call succeeds and charges budget" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{
        .id = "echo",
        .description = "echo input",
        .side_effect = .pure,
    }, echoTool));

    var ctx = h.context();
    const result = try ctx.invokeTool("echo", "hello");

    try std.testing.expectEqualStrings("hello", result.output);
    try std.testing.expectEqual(@as(u64, 15), h.meter.totalTokens());
    try std.testing.expectEqual(@as(u32, 1), ctx.stats.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), h.tracer.countTool(.start));
    try std.testing.expectEqual(@as(usize, 1), h.tracer.countTool(.finish));
}

test "context: allowlist blocks tools the agent may not use" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{ .id = "echo", .description = "echo", .side_effect = .pure }, echoTool));

    var ctx = h.context();
    ctx.allowed_tools = &.{"workspace.*"};

    try std.testing.expectError(ContextError.CapabilityViolation, ctx.invokeTool("echo", "hi"));
    try std.testing.expectError(ContextError.ToolNotFound, ctx.invokeTool("missing", "hi"));
}

test "context: secret payloads are denied egress by policy" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{
        .id = "provider.complete",
        .description = "send to provider",
        .side_effect = .provider_send,
    }, echoTool));

    var ctx = h.context();
    const result = ctx.invokeTool("provider.complete", "api_key: sk-live-1234567890");

    try std.testing.expectError(ContextError.PolicyDenied, result);
    try std.testing.expectEqual(@as(u32, 1), ctx.stats.policy_denials);
    try std.testing.expect(h.tracer.sawToolError(ContextError.PolicyDenied));
}

test "context: mutating tools are journalled and approved on success" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{
        .id = "vcs.commit",
        .description = "create a commit",
        .side_effect = .vcs_mutation,
    }, echoTool));

    var ctx = h.context();
    _ = try ctx.invokeTool("vcs.commit", "chore: update");

    try std.testing.expectEqual(@as(usize, 1), h.journal.countByState(.approved));    try std.testing.expectEqual(@as(u32, 1), ctx.stats.approvals_requested);
    try std.testing.expect(h.ledger.verifyChain());
    try std.testing.expectEqual(@as(usize, 1), h.ledger.len());
}

test "context: speculative effects stay pending until promotion" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{
        .id = "fs.write",
        .description = "write file",
        .side_effect = .workspace_write,
    }, echoTool));

    var ctx = h.context();
    ctx.speculative = true;
    _ = try ctx.invokeTool("fs.write", "content");

    try std.testing.expectEqual(@as(usize, 1), h.journal.countByState(.pending));
    try std.testing.expectEqual(@as(usize, 0), h.journal.countByState(.approved));

    h.services.journalRollback();
    try std.testing.expectEqual(@as(usize, 1), h.journal.countByState(.rolled_back));
}

test "context: approval rejection fails the tool call closed" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();
    h.gate.setMode(.auto_reject);

    try h.tools.register(tool_mod.fromFn(.{
        .id = "pkg.install",
        .description = "install a package",
        .side_effect = .package_install,
    }, echoTool));

    var ctx = h.context();
    try std.testing.expectError(approval_mod.ApprovalError.ApprovalRejected, ctx.invokeTool("pkg.install", "left-pad"));
    // Nothing was journalled because the gate ran before the journal write.
    try std.testing.expectEqual(@as(usize, 0), h.journal.entries.items.len);
}

test "context: tool failure leaves the journal entry pending for rollback" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{
        .id = "fs.write",
        .description = "write file",
        .side_effect = .workspace_write,
    }, failingTool));

    var ctx = h.context();
    try std.testing.expectError(error.ToolFailed, ctx.invokeTool("fs.write", "content"));
    try std.testing.expectEqual(@as(usize, 1), h.journal.countByState(.pending));
    try std.testing.expectEqual(@as(u32, 1), ctx.stats.tool_failures);
}

test "context: cancellation short-circuits tool invocation" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    try h.tools.register(tool_mod.fromFn(.{ .id = "echo", .description = "echo", .side_effect = .pure }, echoTool));

    var ctx = h.context();
    h.token.cancel(.user_request);
    try std.testing.expectError(cancel_mod.CancelError.Canceled, ctx.invokeTool("echo", "hi"));
}

test "context: publish and read round-trip through the blackboard" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    var ctx = h.context();
    const handle = try ctx.publish("patch/main.zig", .patch_candidate, "diff --git", .internal);
    try std.testing.expectEqual(@as(u32, 1), handle.version);
    try std.testing.expectEqualStrings("diff --git", ctx.read("patch/main.zig").?);
    try std.testing.expectEqual(@as(u32, 1), ctx.stats.artifacts_published);
}

test "context: prompt rendering uses the task template id" {
    var h: TestHarness = undefined;
    try TestHarness.init(std.testing.allocator, &h);
    defer h.deinit();

    var prompts = prompt_mod.Registry.init(std.testing.allocator);
    defer prompts.deinit();
    try prompts.loadBuiltins();
    h.services.prompts = &prompts;

    var ctx = h.context();
    const rendered = try ctx.renderPrompt(&.{
        .{ .key = "task", .value = "fix bug" },
        .{ .key = "file", .value = "main.zig" },
        .{ .key = "diagnostics", .value = "none" },
        .{ .key = "constraints", .value = "keep API" },
    });
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "fix bug"));
}