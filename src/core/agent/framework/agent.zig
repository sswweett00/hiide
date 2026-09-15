/// Agent contract: descriptor, output, and the erased `Agent` interface.
///
/// An agent is a pure function of structured working memory plus mediated tool
/// calls. It never performs IO directly: everything observable goes through
/// `AgentContext`, which enforces policy, budget, approval, and journalling.
const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../../provider/router.zig");
const blackboard_mod = @import("blackboard.zig");
const context_mod = @import("context.zig");

pub const AgentContext = context_mod.AgentContext;

pub const AgentError = error{
    AgentNotRegistered,
    AgentAlreadyRegistered,
    AgentPanicked,
    OutOfMemory,
};

pub const AgentStatus = enum(u8) {
    /// Produced a usable result.
    ok,
    /// Produced a partial result; the planner may schedule a follow-up.
    partial,
    /// Nothing to do for this input.
    no_op,
    /// Blocked pending human approval.
    needs_approval,
    /// Stopped because the budget ceiling was reached.
    budget_exhausted,
    /// Cooperatively cancelled.
    canceled,
    /// Terminal failure.
    failed,

    /// True when downstream tasks may consume this output.
    /// @example
    /// if (!output.status.isUsable()) return error.DependencyUnsatisfied;
    pub fn isUsable(self: AgentStatus) bool {
        return self == .ok or self == .partial or self == .no_op;
    }

    /// Maps onto the legacy `TaskState` reported over IPC.
    /// @example
    /// const state = status.toTaskState();
    pub fn toTaskState(self: AgentStatus) types.TaskState {
        return switch (self) {
            .ok, .partial, .no_op => .completed,
            .canceled => .canceled,
            .needs_approval => .running,
            .budget_exhausted, .failed => .failed,
        };
    }
};

/// Immutable result of one agent execution.
pub const AgentOutput = struct {
    status: AgentStatus = .ok,
    /// Short human-readable summary; artifacts carry the real payload.
    summary: []const u8 = "",
    /// Primary artifact published to the blackboard, if any.
    artifact: ?blackboard_mod.Handle = null,
    /// Content digest used for consensus comparison in debate mode.
    digest: [32]u8 = @splat(0),
    /// Self-reported confidence, 0–100.
    confidence: u8 = 0,
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    microunits: u64 = 0,
    /// Tasks the agent proposes appending to the plan (planner agents only).
    proposed_tasks: []const types.AgentTask = &.{},

    /// Builds an output whose digest is derived from `summary`.
    /// @example
    /// return AgentOutput.fromSummary("patched 2 files", 85);
    pub fn fromSummary(summary: []const u8, confidence: u8) AgentOutput {
        var out = AgentOutput{ .summary = summary, .confidence = confidence };
        std.crypto.hash.sha2.Sha256.hash(summary, &out.digest, .{});
        return out;
    }

    /// Recomputes the digest from arbitrary bytes (e.g. a patch body).
    /// @example
    /// output.setDigest(patch_bytes);
    pub fn setDigest(self: *AgentOutput, bytes: []const u8) void {
        std.crypto.hash.sha2.Sha256.hash(bytes, &self.digest, .{});
    }

    /// True when two outputs are byte-identical by digest (consensus check).
    /// @example
    /// if (a.agreesWith(b)) votes += 1;
    pub fn agreesWith(self: AgentOutput, other: AgentOutput) bool {
        return std.mem.eql(u8, &self.digest, &other.digest);
    }
};

/// Static metadata describing an agent implementation.
pub const AgentDescriptor = struct {
    /// Stable id, e.g. "core.coder.v1".
    id: []const u8,
    kind: types.AgentKind,
    version: u16 = 1,
    /// Tool allowlist; empty means "any registered tool", "*" is explicit.
    allowed_tools: []const []const u8 = &.{},
    /// Model capabilities this agent needs from the provider router.
    required_capabilities: provider_mod.ModelCapabilities = .{
        .tool_use = false,
        .vision = false,
        .structured_output = true,
        .long_context = false,
        .streaming = false,
    },
    default_budget: types.TokenBudget = types.TokenBudget.defaultPlanning(),
    prompt_template_id: u32 = 0,
    /// Retry attempts for transient failures (0 = no retry).
    max_retries: u8 = 2,
    /// Per-attempt wall-clock ceiling.
    timeout_ms: u32 = 60_000,
    /// True when the same input always produces the same output; enables
    /// caching and makes the agent eligible for debate replicas.
    deterministic: bool = false,
    /// True when one instance may run on several worker threads concurrently.
    concurrency_safe: bool = true,
    /// Latency class forwarded to the provider router (0/1/2).
    latency_class: u8 = 1,
};

/// Erased agent instance.
pub const Agent = struct {
    descriptor: AgentDescriptor,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (*anyopaque, *AgentContext) anyerror!AgentOutput,
        /// Clears per-run state before a retry.
        reset: ?*const fn (*anyopaque) void = null,
        /// Releases instance resources.
        deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    };

    /// Executes the agent body.
    /// @example
    /// const output = try agent.run(&ctx);
    pub fn run(self: Agent, ctx: *AgentContext) anyerror!AgentOutput {
        return self.vtable.run(self.ctx, ctx);
    }

    /// Resets instance state between retry attempts.
    /// @example
    /// agent.reset();
    pub fn reset(self: Agent) void {
        if (self.vtable.reset) |f| f(self.ctx);
    }

    /// Releases instance resources.
    /// @example
    /// agent.deinit(allocator);
    pub fn deinit(self: Agent, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |f| f(self.ctx, allocator);
    }
};

/// Wraps a concrete implementation type as an `Agent`.
/// `T` must expose `pub fn run(self: *T, ctx: *AgentContext) anyerror!AgentOutput`
/// and may optionally expose `reset` and `deinit`.
/// @example
/// const agent = fromImpl(CoderAgent, &coder, descriptor);
pub fn fromImpl(comptime T: type, instance: *T, descriptor: AgentDescriptor) Agent {
    const Shim = struct {
        fn run(ptr: *anyopaque, ctx: *AgentContext) anyerror!AgentOutput {
            const self: *T = @ptrCast(@alignCast(ptr));
            return T.run(self, ctx);
        }
        fn reset(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            T.reset(self);
        }
        fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            T.deinit(self, allocator);
        }

        const vtable = Agent.VTable{
            .run = run,
            .reset = if (@hasDecl(T, "reset")) reset else null,
            .deinit = if (@hasDecl(T, "deinit")) deinit else null,
        };
    };

    return .{
        .descriptor = descriptor,
        .ctx = instance,
        .vtable = &Shim.vtable,
    };
}

/// Wraps a stateless function as an `Agent`.
/// @example
/// const agent = fromFn(descriptor, myRunFn);
pub fn fromFn(
    descriptor: AgentDescriptor,
    comptime run_fn: fn (*AgentContext) anyerror!AgentOutput,
) Agent {
    const Shim = struct {
        fn run(_: *anyopaque, ctx: *AgentContext) anyerror!AgentOutput {
            return run_fn(ctx);
        }
        const vtable = Agent.VTable{ .run = run };
    };
    return .{
        .descriptor = descriptor,
        .ctx = @constCast(@ptrCast(&Shim.vtable)),
        .vtable = &Shim.vtable,
    };
}

test "agent: status maps to task state and usability" {
    try std.testing.expect(AgentStatus.ok.isUsable());
    try std.testing.expect(AgentStatus.no_op.isUsable());
    try std.testing.expect(!AgentStatus.failed.isUsable());
    try std.testing.expectEqual(types.TaskState.completed, AgentStatus.partial.toTaskState());
    try std.testing.expectEqual(types.TaskState.canceled, AgentStatus.canceled.toTaskState());
    try std.testing.expectEqual(types.TaskState.failed, AgentStatus.budget_exhausted.toTaskState());
}

test "agent: output digests drive consensus agreement" {
    const a = AgentOutput.fromSummary("same result", 90);
    const b = AgentOutput.fromSummary("same result", 40);
    const c = AgentOutput.fromSummary("different", 90);

    try std.testing.expect(a.agreesWith(b));
    try std.testing.expect(!a.agreesWith(c));

    var d = AgentOutput{};
    d.setDigest("same result");
    try std.testing.expect(a.agreesWith(d));
}

test "agent: descriptor defaults are conservative" {
    const d = AgentDescriptor{ .id = "core.coder.v1", .kind = .coder };
    try std.testing.expectEqual(@as(u8, 2), d.max_retries);
    try std.testing.expect(d.required_capabilities.structured_output);
    try std.testing.expect(!d.required_capabilities.tool_use);
    try std.testing.expect(d.concurrency_safe);
    try std.testing.expect(!d.deterministic);
}
