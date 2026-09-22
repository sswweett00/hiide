const std = @import("std");
const agent_types = @import("../agent/types.zig");

const MAX_ARTIFACTS: usize = 10_000;
const MAX_ARTIFACT_BYTES: usize = 16 * 1024 * 1024;

pub const ArtifactKind = enum(u8) {
    diagnostic_bundle,
    patch_candidate,
    test_report,
    policy_verdict,
    semantic_query,
};

pub const ArtifactRef = struct {
    id: u64,
    kind: ArtifactKind,
    bytes: []const u8,
};

pub const WorkingMemory = struct {
    allocator: std.mem.Allocator,
    artifacts: std.ArrayListUnmanaged(ArtifactRef) = .empty,
    next_artifact_id: u64 = 1,
    max_artifacts: usize = MAX_ARTIFACTS,
    max_artifact_bytes: usize = MAX_ARTIFACT_BYTES,

    /// Initializes an empty working-memory store for one agent session.
    /// @example
    /// var memory = WorkingMemory.init(allocator);
    pub fn init(allocator: std.mem.Allocator) WorkingMemory {
        return .{ .allocator = allocator };
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        max_artifacts: usize,
        max_artifact_bytes: usize,
    ) WorkingMemory {
        return .{
            .allocator = allocator,
            .max_artifacts = max_artifacts,
            .max_artifact_bytes = max_artifact_bytes,
        };
    }

    pub fn deinit(self: *WorkingMemory) void {
        for (self.artifacts.items) |artifact| {
            self.allocator.free(artifact.bytes);
        }
        self.artifacts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stores an immutable artifact blob and returns a typed handle.
    /// @example
    /// const artifact = try memory.put(.semantic_query, "{\"query\":\"auth\"}");
    pub fn put(self: *WorkingMemory, kind: ArtifactKind, bytes: []const u8) !ArtifactRef {
        if (bytes.len > self.max_artifact_bytes) return error.ArtifactTooLarge;
        if (self.artifacts.items.len >= self.max_artifacts) return error.ArtifactLimitExceeded;
        const owned = try self.allocator.dupe(u8, bytes);
        const artifact = ArtifactRef{
            .id = self.next_artifact_id,
            .kind = kind,
            .bytes = owned,
        };
        self.next_artifact_id += 1;
        try self.artifacts.append(self.allocator, artifact);
        return artifact;
    }

    /// Produces a lightweight handle group that agents can share without copying content.
    /// @example
    /// const snapshot = memory.snapshotRefs();
    pub fn snapshotRefs(self: *const WorkingMemory) agent_types.WorkingMemoryRef {
        return .{
            .symbol_snapshot_id = 0,
            .task_graph_id = 0,
            .policy_snapshot_id = 0,
            .artifact_set_id = if (self.artifacts.items.len == 0) 0 else self.artifacts.items[self.artifacts.items.len - 1].id,
        };
    }
};


test "working memory: bounds oversized artifacts and artifact count" {
    var memory = WorkingMemory.initWithLimits(std.testing.allocator, 8, 16);
    defer memory.deinit();

    const oversized = try std.testing.allocator.alloc(u8, 17);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.ArtifactTooLarge, memory.put(.test_report, oversized));

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try memory.put(.semantic_query, "x");
    }
    try std.testing.expectError(error.ArtifactLimitExceeded, memory.put(.semantic_query, "y"));
}
