/// hiide — AI-native IDE engine root module.
/// Re-exports all subsystems implementing the Enterprise IDE Specification.
const std = @import("std");

// §1 Multi-Agent Orchestration Engine
pub const agent = struct {
    pub const types = @import("core/agent/types.zig");
    pub const scheduler = @import("core/agent/scheduler.zig");
    pub const dag = @import("core/agent/dag.zig");
    pub const journal = @import("core/agent/journal.zig");
    pub const intent = @import("core/agent/intent.zig");
    pub const framework = @import("core/agent/framework/mod.zig");
};

/// §1 Agent framework, re-exported at the root for ergonomic imports.
pub const framework = agent.framework;

// §1 Editor Core (Zig-native)
pub const editor = struct {
    pub const buffer = @import("core/editor/buffer.zig");
    pub const highlighter = @import("core/editor/highlighter.zig");
    pub const editor = @import("core/editor/editor.zig");
    pub const c_api = @import("core/editor/c_api.zig");
};

// §1 IPC / C ABI
pub const ipc = struct {
    pub const protocol = @import("core/ipc/protocol.zig");
    pub const c_api = @import("core/ipc/c_api.zig");
    pub const server = @import("core/ipc/server.zig");
    pub const server_c_api = @import("core/ipc/server_c_api.zig");
};

// §1 Working Memory
pub const memory = struct {
    pub const working_memory = @import("core/memory/working_memory.zig");
};

// §1 Runtime
pub const runtime = struct {
    pub const config = @import("core/runtime/config.zig");
    pub const app = @import("core/runtime/app.zig");
};

// §2 Semantic Codebase Understanding
pub const semantic = struct {
    pub const graph = @import("core/semantic/graph.zig");
    pub const query = @import("core/semantic/query.zig");
};

// §3 Enterprise Security, Compliance & Policy Engine
pub const security = struct {
    pub const classifier = @import("core/security/classifier.zig");
    pub const policy = @import("core/security/policy.zig");
};

// §4 BYOK + Managed + Self-Hosted Provider Abstraction
pub const provider = struct {
    pub const router = @import("core/provider/router.zig");
    pub const groq = @import("core/provider/groq.zig");
};

// §5 Plugin & Extension Ecosystem
pub const plugin = struct {
    pub const manager = @import("core/plugin/manager.zig");
};

// §6 Observability, Telemetry & Self-Improvement Loop
pub const telemetry = struct {
    pub const collector = @import("core/telemetry/collector.zig");
};

// §7 Real-Time Collaboration & Shared AI Context
pub const collab = struct {
    pub const engine = @import("core/collab/engine.zig");
};

// §8 Cross-Platform Performance Guarantees
pub const bench = struct {
    pub const runner = @import("core/bench/runner.zig");
};

// ── C ABI exports ────────────────────────────────────────────────────────────
// In Zig 0.16+, `pub usingnamespace` no longer re-exports declarations.
// The C API modules are still compiled (their `export fn` symbols appear
// in the object file) — host consumers link against those symbols directly.
pub const c_api = struct {
    pub const agent = @import("core/agent/c_api.zig");
    pub const editor = @import("core/editor/c_api.zig");
    pub const ipc = @import("core/ipc/c_api.zig");
    pub const server_ipc = @import("core/ipc/server_c_api.zig");
    pub const groq = @import("core/provider/groq_c_api.zig");
};

test {
    std.testing.refAllDecls(@This());
}
