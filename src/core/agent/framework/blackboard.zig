/// Structured working memory shared by agents ("blackboard").
///
/// Spec §1.3: agents read structured working memory, not chat transcripts —
/// symbol IDs, patch candidates, diagnostics, policy verdicts, and test
/// artifacts. Spec §1.4: when classification is `confidential` or higher the
/// board stores a typed hash reference instead of the raw value.
///
/// The store is append-only: writing a key produces a new immutable version, so
/// slices handed to concurrently running agents stay valid for the lifetime of
/// the board. Speculative writes are quarantined until `promoteTask` runs.
const std = @import("std");
const compat = @import("../../compat.zig");
const agent_types = @import("../types.zig");
const working_memory = @import("../../memory/working_memory.zig");
const classifier = @import("../../security/classifier.zig");
const clock_mod = @import("clock.zig");

pub const ArtifactKind = working_memory.ArtifactKind;
pub const Classification = classifier.Classification;

pub const MemoryError = error{
    ArtifactNotFound,
    KeyTooLong,
    OutOfMemory,
};

pub const Visibility = enum(u8) {
    /// Written by a speculative branch; invisible to committed readers.
    speculative,
    /// Promoted into the shared artifact store.
    committed,
    /// Rolled back; retained for audit but never returned by `get`.
    discarded,
};

/// How the payload is materialised on the board.
pub const StoreMode = enum(u8) {
    /// Raw bytes are retained.
    raw,
    /// Only a typed hash reference is retained (mandatory for confidential+).
    hash_reference,
};

pub const Handle = struct {
    id: u64,
    version: u32,
    kind: ArtifactKind,
    classification: Classification,
    store_mode: StoreMode,
    byte_len: u32,
    hash: [32]u8,

    /// Lowercase hex digest of the artifact payload.
    /// @example
    /// const hex = handle.hexDigest();
    pub fn hexDigest(self: Handle) [64]u8 {
        var out: [64]u8 = undefined;
        const hex = std.fmt.bytesToHex(self.hash, .lower);
        @memcpy(&out, &hex);
        return out;
    }
};

pub const Entry = struct {
    handle: Handle,
    key: []u8,
    bytes: []u8,
    task_id: u128,
    visibility: Visibility,
    created_ms: i64,
    /// Previous entry for the same key, newest-first linked list.
    prev_same_key: ?usize = null,
};

pub const PutOptions = struct {
    classification: Classification = .public,
    task_id: u128 = 0,
    speculative: bool = false,
    /// Allows raw retention of confidential payloads (audited escape hatch used
    /// by local-only self-hosted deployments).
    allow_raw_sensitive: bool = false,
};

const MAX_KEY_LEN: usize = 512;

/// Thread-safe, append-only, versioned artifact store.
pub const Blackboard = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// key → index of the newest entry for that key.
    index: std.StringHashMapUnmanaged(usize) = .empty,
    /// artifact id → entry index for O(1) handle-based lookup.
    id_index: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    /// Number of live entries at each classification level.
    classification_counts: [5]u64 = .{ 0, 0, 0, 0, 0 },
    next_id: u64 = 1,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    clock: clock_mod.Clock,

    /// Creates an empty blackboard.
    /// @example
    /// var board = Blackboard.init(allocator, clock_mod.system());
    pub fn init(allocator: std.mem.Allocator, c: clock_mod.Clock) Blackboard {
        return .{ .allocator = allocator, .clock = c };
    }

    pub fn deinit(self: *Blackboard) void {
        for (self.entries.items) |entry| {
            // Zero sensitive payloads before release (spec §3.4 secret zero-leak).
            if (@intFromEnum(entry.handle.classification) >= @intFromEnum(Classification.confidential)) {
                @memset(entry.bytes, 0);
            }
            self.allocator.free(entry.bytes);
            self.allocator.free(entry.key);
        }
        self.entries.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.id_index.deinit(self.allocator);
        self.* = undefined;
    }

    /// Publishes a new immutable version of `key`.
    /// Confidential-or-higher payloads are reduced to a hash reference unless
    /// `allow_raw_sensitive` is set.
    /// @example
    /// const handle = try board.put("patch/main.zig", .patch_candidate, diff, .{ .task_id = task.id });
    pub fn put(
        self: *Blackboard,
        key: []const u8,
        kind: ArtifactKind,
        bytes: []const u8,
        opts: PutOptions,
    ) MemoryError!Handle {
        if (key.len == 0 or key.len > MAX_KEY_LEN) return MemoryError.KeyTooLong;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});

        const sensitive = @intFromEnum(opts.classification) >= @intFromEnum(Classification.confidential);
        const mode: StoreMode = if (sensitive and !opts.allow_raw_sensitive) .hash_reference else .raw;

        const stored: []u8 = switch (mode) {
            .raw => try self.allocator.dupe(u8, bytes),
            .hash_reference => blk: {
                var buf: [96]u8 = undefined;
                const hex = std.fmt.bytesToHex(hash[0..16], .lower);
                const text = std.fmt.bufPrint(&buf, "hiide:ref:{s}:{d}", .{
                    @as([]const u8, &hex),
                    bytes.len,
                }) catch return MemoryError.OutOfMemory;
                break :blk try self.allocator.dupe(u8, text);
            },
        };
        errdefer self.allocator.free(stored);

        self.mutex.lock();
        defer self.mutex.unlock();

        const previous_idx = self.index.get(key);
        const previous_version: u32 = if (previous_idx) |idx|
            self.entries.items[idx].handle.version
        else
            0;

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        // Reserve index space up front so the append below is the last fallible
        // step; this keeps ownership transfer exception-safe.
        try self.index.ensureUnusedCapacity(self.allocator, 1);
        try self.id_index.ensureUnusedCapacity(self.allocator, 1);

        const handle = Handle{
            .id = self.next_id,
            .version = previous_version + 1,
            .kind = kind,
            .classification = opts.classification,
            .store_mode = mode,
            .byte_len = @intCast(@min(bytes.len, std.math.maxInt(u32))),
            .hash = hash,
        };

        try self.entries.append(self.allocator, .{
            .handle = handle,
            .key = owned_key,
            .bytes = stored,
            .task_id = opts.task_id,
            .visibility = if (opts.speculative) .speculative else .committed,
            .created_ms = self.clock.nowMs(),
            .prev_same_key = previous_idx,
        });

        const idx = self.entries.items.len - 1;
        self.index.putAssumeCapacity(owned_key, idx);
        self.id_index.putAssumeCapacity(handle.id, idx);
        self.classification_counts[@intFromEnum(opts.classification)] += 1;

        self.next_id += 1;
        _ = self.generation.fetchAdd(1, .acq_rel);
        return handle;
    }

    /// Returns the newest committed payload for `key`, or null.
    /// Speculative and discarded versions are skipped.
    /// @example
    /// const patch = board.get("patch/main.zig") orelse return;
    pub fn get(self: *Blackboard, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.newestVisibleLocked(key) orelse return null;
        return entry.bytes;
    }

    /// Returns the newest payload for `key` including speculative versions.
    /// @example
    /// const draft = board.getSpeculative("patch/main.zig", task_id);
    pub fn getSpeculative(self: *Blackboard, key: []const u8, task_id: u128) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var idx = self.index.get(key) orelse return null;
        while (true) {
            const entry = &self.entries.items[idx];
            if (entry.visibility != .discarded) {
                if (entry.visibility == .committed or entry.task_id == task_id) {
                    return entry.bytes;
                }
            }
            idx = entry.prev_same_key orelse return null;
        }
    }

    /// Returns the handle metadata for the newest committed version of `key`.
    /// @example
    /// const handle = board.handleOf("policy/verdict") orelse return;
    pub fn handleOf(self: *Blackboard, key: []const u8) ?Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.newestVisibleLocked(key) orelse return null;
        return entry.handle;
    }

    /// Looks a payload up by artifact id regardless of key.
    /// @example
    /// const bytes = board.getById(handle.id) orelse return error.ArtifactNotFound;
    pub fn getById(self: *Blackboard, id: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.id_index.get(id) orelse return null;
        const entry = &self.entries.items[idx];
        if (entry.visibility == .discarded) return null;
        return entry.bytes;
    }

    /// Returns every version handle for `key`, oldest first. Caller owns the slice.
    /// @example
    /// const versions = try board.history(alloc, "patch/main.zig");
    pub fn history(self: *Blackboard, alloc: std.mem.Allocator, key: []const u8) ![]Handle {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = std.ArrayListUnmanaged(Handle).empty;
        errdefer out.deinit(alloc);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) try out.append(alloc, entry.handle);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Promotes every speculative artifact written by `task_id`.
    /// Returns how many entries were promoted.
    /// @example
    /// const promoted = board.promoteTask(task.id);
    pub fn promoteTask(self: *Blackboard, task_id: u128) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.task_id == task_id and entry.visibility == .speculative) {
                entry.visibility = .committed;
                n += 1;
            }
        }
        if (n > 0) _ = self.generation.fetchAdd(1, .acq_rel);
        return n;
    }

    /// Discards every speculative artifact written by `task_id`.
    /// Payload memory is zeroed but retained until `deinit` so that slices held
    /// by in-flight readers never dangle.
    /// @example
    /// const dropped = board.discardTask(task.id);
    pub fn discardTask(self: *Blackboard, task_id: u128) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.task_id == task_id and entry.visibility == .speculative) {
                entry.visibility = .discarded;
                self.classification_counts[@intFromEnum(entry.handle.classification)] -= 1;
                n += 1;
            }
        }
        if (n > 0) _ = self.generation.fetchAdd(1, .acq_rel);
        return n;
    }

    /// Highest classification currently stored; drives provider egress policy.
    /// @example
    /// const max = board.maxClassification();
    pub fn maxClassification(self: *Blackboard) Classification {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = self.classification_counts.len;
        while (i > 0) {
            i -= 1;
            if (self.classification_counts[i] != 0) return @enumFromInt(i);
        }
        return .public;
    }

    /// Handle group compatible with the legacy `WorkingMemoryRef` contract.
    /// @example
    /// const refs = board.snapshotRefs(graph_id, policy_snapshot_id);
    pub fn snapshotRefs(
        self: *Blackboard,
        task_graph_id: u64,
        policy_snapshot_id: u64,
    ) agent_types.WorkingMemoryRef {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .symbol_snapshot_id = self.generation.load(.acquire),
            .task_graph_id = task_graph_id,
            .policy_snapshot_id = policy_snapshot_id,
            .artifact_set_id = if (self.entries.items.len == 0)
                0
            else
                self.entries.items[self.entries.items.len - 1].handle.id,
        };
    }

    /// Number of stored versions (all visibilities).
    pub fn count(self: *Blackboard) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Monotonic write counter used to invalidate stale snapshots (spec §1.5).
    pub fn currentGeneration(self: *const Blackboard) u64 {
        return self.generation.load(.acquire);
    }

    fn newestVisibleLocked(self: *Blackboard, key: []const u8) ?*Entry {
        var idx = self.index.get(key) orelse return null;
        while (true) {
            const entry = &self.entries.items[idx];
            if (entry.visibility == .committed) return entry;
            idx = entry.prev_same_key orelse return null;
        }
    }
};

/// Detects "snapshot taken before a mutation" hazards so the executor can
/// invalidate dependent tasks and reschedule from the planner (spec §1.5).
pub const SnapshotGuard = struct {
    board: *Blackboard,
    taken_generation: u64,

    /// Captures the current generation counter.
    /// @example
    /// const guard = SnapshotGuard.take(&board);
    pub fn take(board: *Blackboard) SnapshotGuard {
        return .{ .board = board, .taken_generation = board.currentGeneration() };
    }

    /// True when the board changed after the snapshot was taken.
    /// @example
    /// if (guard.isStale()) return error.SnapshotStale;
    pub fn isStale(self: SnapshotGuard) bool {
        return self.board.currentGeneration() != self.taken_generation;
    }
};

test "blackboard: versioned append-only writes" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    const h1 = try board.put("patch/main.zig", .patch_candidate, "v1", .{});
    const h2 = try board.put("patch/main.zig", .patch_candidate, "v2", .{});

    try std.testing.expectEqual(@as(u32, 1), h1.version);
    try std.testing.expectEqual(@as(u32, 2), h2.version);
    try std.testing.expectEqualStrings("v2", board.get("patch/main.zig").?);
    try std.testing.expectEqualStrings("v1", board.getById(h1.id).?);

    const versions = try board.history(std.testing.allocator, "patch/main.zig");
    defer std.testing.allocator.free(versions);
    try std.testing.expectEqual(@as(usize, 2), versions.len);
}

test "blackboard: confidential payloads degrade to hash references" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    const handle = try board.put("secret/token", .semantic_query, "sk-live-abcdef", .{
        .classification = .secret,
    });

    try std.testing.expectEqual(StoreMode.hash_reference, handle.store_mode);
    const stored = board.get("secret/token").?;
    try std.testing.expect(!std.mem.containsAtLeast(u8, stored, 1, "sk-live"));
    try std.testing.expect(std.mem.startsWith(u8, stored, "hiide:ref:"));
    try std.testing.expectEqual(Classification.secret, board.maxClassification());
}

test "blackboard: raw retention is possible for self-hosted deployments" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    _ = try board.put("conf/data", .diagnostic_bundle, "payload", .{
        .classification = .confidential,
        .allow_raw_sensitive = true,
    });
    try std.testing.expectEqualStrings("payload", board.get("conf/data").?);
}

test "blackboard: speculative writes are quarantined until promotion" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    _ = try board.put("plan/step", .patch_candidate, "speculative", .{
        .task_id = 7,
        .speculative = true,
    });

    try std.testing.expectEqual(@as(?[]const u8, null), board.get("plan/step"));
    try std.testing.expectEqualStrings("speculative", board.getSpeculative("plan/step", 7).?);
    try std.testing.expectEqual(@as(?[]const u8, null), board.getSpeculative("plan/step", 8));

    try std.testing.expectEqual(@as(usize, 1), board.promoteTask(7));
    try std.testing.expectEqualStrings("speculative", board.get("plan/step").?);
}

test "blackboard: discarded speculation never becomes visible" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    _ = try board.put("plan/step", .patch_candidate, "committed", .{ .task_id = 1 });
    _ = try board.put("plan/step", .patch_candidate, "rolled-back", .{ .task_id = 2, .speculative = true });

    try std.testing.expectEqual(@as(usize, 1), board.discardTask(2));
    try std.testing.expectEqualStrings("committed", board.get("plan/step").?);
    try std.testing.expectEqual(@as(usize, 0), board.promoteTask(2));
}

test "blackboard: snapshot guard detects concurrent mutation" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    _ = try board.put("a", .semantic_query, "1", .{});
    const guard = SnapshotGuard.take(&board);
    try std.testing.expect(!guard.isStale());

    _ = try board.put("b", .semantic_query, "2", .{});
    try std.testing.expect(guard.isStale());
}

test "blackboard: concurrent writers keep every version" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    const Writer = struct {
        fn run(b: *Blackboard, id: u128) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "task/{d}", .{id}) catch return;
                _ = b.put(key, .test_report, "x", .{ .task_id = id }) catch return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Writer.run, .{ &board, @as(u128, i) });
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(usize, 200), board.count());
    const refs = board.snapshotRefs(1, 2);
    try std.testing.expectEqual(@as(u64, 1), refs.task_graph_id);
    try std.testing.expect(refs.artifact_set_id > 0);
}


test "blackboard: classification ceiling remains correct after speculative discard" {
    var board = Blackboard.init(std.testing.allocator, clock_mod.system());
    defer board.deinit();

    _ = try board.put("public", .note, "ok", .{ .classification = .public });
    _ = try board.put("secret", .note, "draft", .{
        .classification = .secret,
        .task_id = 9,
        .speculative = true,
    });

    try std.testing.expectEqual(Classification.secret, board.maxClassification());
    try std.testing.expectEqual(@as(usize, 1), board.discardTask(9));
    try std.testing.expectEqual(Classification.public, board.maxClassification());
}
