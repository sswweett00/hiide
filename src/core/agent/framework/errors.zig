/// Unified error taxonomy for the hiide agent framework.
/// Every subsystem maps its failures onto this taxonomy so that middleware,
/// retry policies, and the executor can make uniform decisions without
/// pattern-matching on subsystem-specific error sets.
const std = @import("std");

/// Lifecycle and orchestration failures.
pub const LifecycleError = error{
    AgentNotRegistered,
    AgentAlreadyRegistered,
    AgentPanicked,
    ExecutorShuttingDown,
    ExecutorSaturated,
    PlanEmpty,
    PlanTooLarge,
    DependencyUnsatisfied,
};

/// Cancellation and deadline failures.
pub const CancellationError = error{
    Canceled,
    DeadlineExceeded,
};

/// Budget accounting failures.
pub const BudgetError = error{
    BudgetExhausted,
    SpendLimitExceeded,
};

/// Policy, classification, and approval failures.
pub const GovernanceError = error{
    PolicyDenied,
    ApprovalRejected,
    ApprovalTimeout,
    CapabilityViolation,
    ClassificationTooHigh,
};

/// Tool subsystem failures.
pub const ToolError = error{
    ToolNotFound,
    ToolAlreadyRegistered,
    ToolTimeout,
    ToolFailed,
    ToolInputInvalid,
};

/// Prompt subsystem failures.
pub const PromptError = error{
    TemplateNotFound,
    TemplateMalformed,
    MissingPromptVariable,
};

/// Blackboard (structured working memory) failures.
pub const MemoryError = error{
    ArtifactNotFound,
    ArtifactImmutable,
    SnapshotStale,
};

/// Consensus failures for debate execution mode.
pub const ConsensusError = error{
    NoQuorum,
    DivergentOutputs,
    InsufficientVoters,
};

/// The complete framework error set. Public APIs return narrow subsets where
/// possible and this union only where a call may fail across layers.
pub const FrameworkError = LifecycleError ||
    CancellationError ||
    BudgetError ||
    GovernanceError ||
    ToolError ||
    PromptError ||
    MemoryError ||
    ConsensusError ||
    std.mem.Allocator.Error;

/// Coarse behavioural class used by retry policies and the executor.
pub const ErrorClass = enum(u8) {
    /// Safe to retry with backoff (timeouts, saturation, transient tool faults).
    transient,
    /// Retrying cannot help; the plan node must fail.
    permanent,
    /// Blocked by policy/approval; never retried automatically.
    governance,
    /// Budget ceiling hit; the executor may downgrade instead of retrying.
    budget,
    /// Cooperative cancellation or deadline expiry.
    cancellation,
    /// Allocation failure; propagate immediately.
    resource,
};

/// Classifies an arbitrary framework error into a retry/escalation class.
/// @example
/// if (classify(err) == .transient) try retry();
pub fn classify(err: anyerror) ErrorClass {
    return switch (err) {
        error.Canceled, error.DeadlineExceeded => .cancellation,

        error.BudgetExhausted, error.SpendLimitExceeded => .budget,

        error.PolicyDenied,
        error.ApprovalRejected,
        error.ApprovalTimeout,
        error.CapabilityViolation,
        error.ClassificationTooHigh,
        => .governance,

        error.ToolTimeout,
        error.ExecutorSaturated,
        error.ToolFailed,
        error.AgentPanicked,
        error.NoQuorum,
        => .transient,

        error.OutOfMemory => .resource,

        else => .permanent,
    };
}

/// Returns true when the executor is allowed to retry after `err`.
/// @example
/// const again = isRetryable(error.ToolTimeout);
pub fn isRetryable(err: anyerror) bool {
    return classify(err) == .transient;
}

/// Stable numeric code for FFI / IPC surfaces.
/// @example
/// const code = toCode(error.PolicyDenied);
pub fn toCode(err: anyerror) u16 {
    return switch (err) {
        error.Canceled => 1,
        error.DeadlineExceeded => 2,
        error.BudgetExhausted => 3,
        error.SpendLimitExceeded => 4,
        error.PolicyDenied => 5,
        error.ApprovalRejected => 6,
        error.ApprovalTimeout => 7,
        error.CapabilityViolation => 8,
        error.ClassificationTooHigh => 9,
        error.ToolNotFound => 10,
        error.ToolTimeout => 11,
        error.ToolFailed => 12,
        error.ToolInputInvalid => 13,
        error.TemplateNotFound => 14,
        error.TemplateMalformed => 15,
        error.MissingPromptVariable => 16,
        error.ArtifactNotFound => 17,
        error.NoQuorum => 18,
        error.DivergentOutputs => 19,
        error.AgentNotRegistered => 20,
        error.ExecutorShuttingDown => 21,
        error.ExecutorSaturated => 22,
        error.OutOfMemory => 23,
        else => 0xFFFF,
    };
}

test "errors: classification buckets" {
    try std.testing.expectEqual(ErrorClass.cancellation, classify(error.Canceled));
    try std.testing.expectEqual(ErrorClass.budget, classify(error.BudgetExhausted));
    try std.testing.expectEqual(ErrorClass.governance, classify(error.PolicyDenied));
    try std.testing.expectEqual(ErrorClass.transient, classify(error.ToolTimeout));
    try std.testing.expectEqual(ErrorClass.resource, classify(error.OutOfMemory));
    try std.testing.expectEqual(ErrorClass.permanent, classify(error.ToolInputInvalid));
}

test "errors: retryability and codes are stable" {
    try std.testing.expect(isRetryable(error.ToolTimeout));
    try std.testing.expect(!isRetryable(error.PolicyDenied));
    try std.testing.expectEqual(@as(u16, 5), toCode(error.PolicyDenied));
    try std.testing.expectEqual(@as(u16, 0xFFFF), toCode(error.Unexpected));
}
