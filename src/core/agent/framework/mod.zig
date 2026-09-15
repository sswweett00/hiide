/// hiide agent framework — enterprise multi-agent runtime.
///
/// Layering (each layer only depends on the ones above it):
///
///   primitives : errors, clock, cancel, budget, queue
///   state      : blackboard, prompt
///   governance : tool, approval
///   agent      : agent, context, middleware, registry
///   orchestration: consensus, planner, executor, orchestrator
///   harness    : testing
const std = @import("std");

// ── primitives ───────────────────────────────────────────────────────────────
pub const errors = @import("errors.zig");
pub const clock = @import("clock.zig");
pub const cancel = @import("cancel.zig");
pub const budget = @import("budget.zig");
pub const queue = @import("queue.zig");

// ── state ────────────────────────────────────────────────────────────────────
pub const blackboard = @import("blackboard.zig");
pub const prompt = @import("prompt.zig");

// ── governance ───────────────────────────────────────────────────────────────
pub const tool = @import("tool.zig");
pub const approval = @import("approval.zig");

// ── agent ────────────────────────────────────────────────────────────────────
pub const agent = @import("agent.zig");
pub const context = @import("context.zig");
pub const middleware = @import("middleware.zig");
pub const registry = @import("registry.zig");
pub const file_tools = @import("file_tools.zig");
pub const process_tools = @import("process_tools.zig");
pub const workspace_tools = @import("workspace_tools.zig");
pub const groq_coder = @import("groq_coder.zig");

// ── orchestration ────────────────────────────────────────────────────────────
pub const consensus = @import("consensus.zig");
pub const executor = @import("executor.zig");
pub const planner = @import("planner.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
}
