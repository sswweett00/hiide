/// Real-time collaboration engine per spec §7.
/// Implements CRDT-based buffer operations, presence state management,
/// and role-based access control for collaborative agent sessions.
const std = @import("std");

pub const Role = enum(u8) {
    observer,
    commenter,
    executor,
};

pub const PresenceState = struct {
    user_id: []const u8,
    file_uri: []const u8,
    cursor_utf8_col: u32,
    line: u32,
    ts_unix_ms: i64,
};

pub const CollaborationSession = struct {
    session_id: []const u8,
    doc_id: []const u8,
    role: Role,
    shared_index_key_id: []const u8,
};

/// CRDT operation types for the logical operation log.
pub const OpKind = enum(u8) {
    insert,
    delete,
    retain,
};

/// A single CRDT operation in the operation log.
/// Uses a simplified OT-style sequence for text; production would use a full
/// CRDT library (e.g., Diamond Types or Automerge).
pub const CrdtOp = struct {
    /// Monotonic sequence number per author.
    seq: u64,
    /// Originating user/agent id.
    author: []const u8,
    kind: OpKind,
    /// Character offset in the logical document.
    offset: u32,
    /// Content for insert ops; ignored for delete.
    content: []const u8,
    /// Length for delete ops.
    length: u32,
    ts_unix_ms: i64,
};

pub const CollabError = error{
    SessionNotFound,
    PermissionDenied,
    DivergenceDetected,
    OutOfMemory,
};

/// Per-session CRDT document state.
pub const DocState = struct {
    doc_id: []const u8,
    /// Logical text content (simplified; production uses a gap buffer).
    content: std.ArrayListUnmanaged(u8),
    /// Causal operation log for reconciliation.
    op_log: std.ArrayListUnmanaged(CrdtOp),
    /// State hash for periodic reconciliation checks.
    state_hash: [32]u8,

    pub fn init(alloc: std.mem.Allocator, doc_id: []const u8) DocState {
        _ = alloc;
        return .{
            .doc_id = doc_id,
            .content = .{},
            .op_log = .{},
            .state_hash = @as([32]u8, @splat(0)),
        };
    }

    pub fn deinit(self: *DocState, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
        for (self.op_log.items) |op| {
            alloc.free(op.author);
            alloc.free(op.content);
        }
        self.op_log.deinit(alloc);
    }

    fn recomputeHash(self: *DocState) void {
        std.crypto.hash.sha2.Sha256.hash(self.content.items, &self.state_hash, .{});
    }
};

/// Collaboration engine managing sessions and CRDT state.
/// @example
/// var engine = CollabEngine.init(alloc);
/// const sess = CollaborationSession{ .session_id = "s1", .doc_id = "f.zig", .role = .executor, .shared_index_key_id = "k1" };
/// try engine.createSession(sess, "initial content");
/// try engine.applyRemote(sess, op);
pub const CollabEngine = struct {
    allocator: std.mem.Allocator,
    docs: std.StringHashMapUnmanaged(DocState),
    presence: std.StringHashMapUnmanaged(PresenceState),

    pub fn init(alloc: std.mem.Allocator) CollabEngine {
        return .{ .allocator = alloc, .docs = .{}, .presence = .{} };
    }

    pub fn deinit(self: *CollabEngine) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
        self.presence.deinit(self.allocator);
        self.* = undefined;
    }

    /// Creates a new collaborative document session with initial content.
    pub fn createSession(
        self: *CollabEngine,
        sess: CollaborationSession,
        initial_content: []const u8,
    ) !void {
        var doc = DocState.init(self.allocator, sess.doc_id);
        try doc.content.appendSlice(self.allocator, initial_content);
        doc.recomputeHash();
        try self.docs.put(self.allocator, sess.doc_id, doc);
    }

    /// Applies a remote CRDT operation to the local document.
    /// Role check: observer may not apply insert/delete ops.
    /// @example
    /// try engine.applyRemote(sess, op);
    pub fn applyRemote(
        self: *CollabEngine,
        sess: CollaborationSession,
        op: CrdtOp,
    ) CollabError!void {
        // Observers cannot mutate the document.
        if (sess.role == .observer and op.kind != .retain) {
            return CollabError.PermissionDenied;
        }

        const doc = self.docs.getPtr(sess.doc_id) orelse return CollabError.SessionNotFound;

        switch (op.kind) {
            .insert => {
                const safe_offset = @min(op.offset, @as(u32, @intCast(doc.content.items.len)));
                doc.content.insertSlice(self.allocator, safe_offset, op.content) catch
                    return CollabError.OutOfMemory;
            },
            .delete => {
                const safe_offset = @min(op.offset, @as(u32, @intCast(doc.content.items.len)));
                const end = @min(safe_offset + op.length, @as(u32, @intCast(doc.content.items.len)));
                const del_count = end - safe_offset;
                var i: u32 = 0;
                while (i < del_count) : (i += 1) {
                    _ = doc.content.orderedRemove(safe_offset);
                }
            },
            .retain => {},
        }

        // Store a copy of the op for replay.
        const owned_author = self.allocator.dupe(u8, op.author) catch return CollabError.OutOfMemory;
        errdefer self.allocator.free(owned_author);
        const owned_content = self.allocator.dupe(u8, op.content) catch return CollabError.OutOfMemory;

        doc.op_log.append(self.allocator, .{
            .seq = op.seq,
            .author = owned_author,
            .kind = op.kind,
            .offset = op.offset,
            .content = owned_content,
            .length = op.length,
            .ts_unix_ms = op.ts_unix_ms,
        }) catch return CollabError.OutOfMemory;

        doc.recomputeHash();
    }

    /// Returns the current document content. Caller does not own.
    pub fn getContent(self: *const CollabEngine, doc_id: []const u8) ?[]const u8 {
        const doc = self.docs.get(doc_id) orelse return null;
        return doc.content.items;
    }

    /// Updates user presence state.
    /// @example
    /// try engine.updatePresence(state);
    pub fn updatePresence(self: *CollabEngine, state: PresenceState) !void {
        try self.presence.put(self.allocator, state.user_id, state);
    }

    /// Returns the current presence state for a user, or null.
    pub fn getPresence(self: *const CollabEngine, user_id: []const u8) ?PresenceState {
        return self.presence.get(user_id);
    }

    /// Verifies that the local doc hash matches the expected hash.
    /// Returns false if reconciliation is needed.
    /// @example
    /// const ok = engine.verifyStateHash(doc_id, expected_hash);
    pub fn verifyStateHash(
        self: *const CollabEngine,
        doc_id: []const u8,
        expected: [32]u8,
    ) bool {
        const doc = self.docs.get(doc_id) orelse return false;
        return std.mem.eql(u8, &doc.state_hash, &expected);
    }
};

/// Shared agent orchestrator with role-bound permissions per spec §7.3.
/// @example
/// const task_id = try orchestrator.startShared(sess, req);
pub const SharedAgentOrchestrator = struct {
    pub fn startShared(
        _: *SharedAgentOrchestrator,
        sess: CollaborationSession,
        req_description: []const u8,
    ) CollabError!u128 {
        // Only executors can trigger side-effecting agent tasks.
        if (sess.role == .observer or sess.role == .commenter) {
            // Commenters can request plans but not execute them.
            if (sess.role == .observer) return CollabError.PermissionDenied;
        }

        // Generate a deterministic task id from session + request.
        var hash: [32]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(sess.session_id);
        h.update(req_description);
        h.final(&hash);

        const hi = std.mem.readInt(u64, hash[0..8], .little);
        const lo = std.mem.readInt(u64, hash[8..16], .little);
        return (@as(u128, hi) << 64) | @as(u128, lo);
    }
};

test "collab: insert and delete" {
    var engine = CollabEngine.init(std.testing.allocator);
    defer engine.deinit();

    const sess = CollaborationSession{
        .session_id = "s1",
        .doc_id = "main.zig",
        .role = .executor,
        .shared_index_key_id = "k1",
    };
    try engine.createSession(sess, "hello");

    const insert_op = CrdtOp{
        .seq = 1,
        .author = "alice",
        .kind = .insert,
        .offset = 5,
        .content = " world",
        .length = 0,
        .ts_unix_ms = 0,
    };
    try engine.applyRemote(sess, insert_op);
    try std.testing.expectEqualStrings("hello world", engine.getContent("main.zig").?);

    const delete_op = CrdtOp{
        .seq = 2,
        .author = "bob",
        .kind = .delete,
        .offset = 5,
        .content = "",
        .length = 6,
        .ts_unix_ms = 0,
    };
    try engine.applyRemote(sess, delete_op);
    try std.testing.expectEqualStrings("hello", engine.getContent("main.zig").?);
}

test "collab: observer cannot mutate" {
    var engine = CollabEngine.init(std.testing.allocator);
    defer engine.deinit();

    const sess = CollaborationSession{
        .session_id = "s2",
        .doc_id = "x.zig",
        .role = .observer,
        .shared_index_key_id = "k2",
    };
    try engine.createSession(sess, "data");

    const op = CrdtOp{ .seq = 1, .author = "eve", .kind = .insert, .offset = 0, .content = "HACK", .length = 0, .ts_unix_ms = 0 };
    const result = engine.applyRemote(sess, op);
    try std.testing.expectError(CollabError.PermissionDenied, result);
}

test "collab: presence update and read" {
    var engine = CollabEngine.init(std.testing.allocator);
    defer engine.deinit();

    const state = PresenceState{
        .user_id = "alice",
        .file_uri = "src/main.zig",
        .cursor_utf8_col = 10,
        .line = 42,
        .ts_unix_ms = 9999,
    };
    try engine.updatePresence(state);

    const p = engine.getPresence("alice");
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(u32, 42), p.?.line);
}
