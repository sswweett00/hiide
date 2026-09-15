const std = @import("std");

pub const AgentKind = enum(u8) {
    planner,
    coder,
    reviewer,
    tester,
    researcher,
    security_auditor,
    documentation_writer,
    refactor_specialist,
};

pub const ExecutionMode = enum(u8) {
    sequential,
    parallel_fanout,
    debate_consensus,
    speculative,
    approval_gated,
};

pub const TaskState = enum(u8) {
    queued,
    running,
    completed,
    canceled,
    failed,
};

pub const TokenBudget = struct {
    soft_limit: u32,
    hard_limit: u32,
    downgrade_model_id: []const u8,
    spend_limit_microunits: u64,

    /// Returns the baseline budget used for local planning tasks.
    /// @example
    /// const budget = TokenBudget.defaultPlanning();
    pub fn defaultPlanning() TokenBudget {
        return .{
            .soft_limit = 16_000,
            .hard_limit = 24_000,
            .downgrade_model_id = "local-fallback-planner",
            .spend_limit_microunits = 0,
        };
    }
};

pub const WorkingMemoryRef = struct {
    symbol_snapshot_id: u64,
    task_graph_id: u64,
    policy_snapshot_id: u64,
    artifact_set_id: u64,
};

pub const AgentTask = struct {
    id: u128,
    parent_id: ?u128,
    kind: AgentKind,
    mode: ExecutionMode,
    state: TaskState,
    budget: TokenBudget,
    memory: WorkingMemoryRef,
    prompt_template_id: u32,
    rollback_journal_id: u64,
    title: []const u8,
};

pub const TaskReceipt = struct {
    task_id: u128,
    state: TaskState,
};

/// Registers an agent implementation at comptime.
/// @example
/// const Registry = AgentRegistry(.{
///     .{ .kind = .planner, .Impl = PlannerAgent },
///     .{ .kind = .coder, .Impl = CoderAgent },
/// });
pub fn AgentRegistry(comptime defs: anytype) type {
    return struct {
        pub fn resolve(kind: AgentKind) type {
            inline for (defs) |def| {
                if (def.kind == kind) return def.Impl;
            }
            @compileError("unregistered agent kind");
        }
    };
}

pub fn nextTaskId(rng: std.rand.Random) u128 {
    return rng.int(u128);
}
