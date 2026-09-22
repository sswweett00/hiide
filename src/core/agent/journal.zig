/// Side-effect journal with idempotent commit and rollback per spec §1.
/// Every filesystem, VCS, or network mutation is recorded before execution.
/// Approved entries are replayed; speculative entries are discarded on rollback.
const std = @import("std");
const compat = @import("../compat.zig");

const MAX_JOURNAL_ENTRIES: usize = 100_000;
const MAX_JOURNAL_PAYLOAD_BYTES: usize = 8 * 1024 * 1024;

pub const JournalEntryKind = enum(u8) {
    file_write,
    file_delete,
    vcs_commit,
    network_request,
    package_install,
    secret_access,
    process_exec,
};

pub const JournalEntryState = enum(u8) {
    pending,
    approved,
    rejected,
    committed,
    rolled_back,
};

pub const JournalEntry = struct {
    id: u64,
    task_id: u128,
    kind: JournalEntryKind,
    state: JournalEntryState,
    /// Serialized payload: path, URL, or identifier for the mutation.
    payload: []const u8,
    /// SHA-256 hash of the payload for integrity verification.
    payload_hash: [32]u8,
    ts_unix_ms: i64,
};

pub const JournalError = error{
    EntryNotFound,
    AlreadyCommitted,
    OutOfMemory,
    EntryLimitExceeded,
    PayloadTooLarge,
};

/// Append-only side-effect journal for one task execution.
/// @example
/// var journal = SideEffectJournal.init(alloc);
/// const entry_id = try journal.record(.file_write, task_id, "/workspace/foo.zig", "fn main() {}");
/// try journal.approve(entry_id);
/// try journal.commitApproved();
pub const SideEffectJournal = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(JournalEntry),
    next_id: u64,

    pub fn init(alloc: std.mem.Allocator) SideEffectJournal {
        return .{
            .allocator = alloc,
            .entries = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *SideEffectJournal) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.payload);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Records a pending side-effect entry and returns its id.
    /// @example
    /// const id = try journal.record(.file_write, task_id, "/path/to/file", content);
    pub fn record(
        self: *SideEffectJournal,
        kind: JournalEntryKind,
        task_id: u128,
        payload: []const u8,
    ) !u64 {
        if (payload.len > MAX_JOURNAL_PAYLOAD_BYTES) return JournalError.PayloadTooLarge;
        if (self.entries.items.len >= MAX_JOURNAL_ENTRIES) return JournalError.EntryLimitExceeded;
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});

        const id = self.next_id;
        self.next_id += 1;

        try self.entries.append(self.allocator, .{
            .id = id,
            .task_id = task_id,
            .kind = kind,
            .state = .pending,
            .payload = owned,
            .payload_hash = hash,
            .ts_unix_ms = compat.milliTimestamp(),
        });
        return id;
    }

    /// Marks an entry as approved for commit.
    /// @example
    /// try journal.approve(entry_id);
    pub fn approve(self: *SideEffectJournal, entry_id: u64) JournalError!void {
        for (self.entries.items) |*entry| {
            if (entry.id == entry_id) {
                if (entry.state == .committed) return JournalError.AlreadyCommitted;
                entry.state = .approved;
                return;
            }
        }
        return JournalError.EntryNotFound;
    }

    /// Replays only approved side effects via the provided IO callback.
    /// The callback receives the entry and should return an error on failure.
    /// @example
    /// try journal.commitApproved(struct { fn apply(e: JournalEntry) !void { _ = e; } }.apply);
    pub fn commitApproved(
        self: *SideEffectJournal,
        comptime apply_fn: fn (JournalEntry) anyerror!void,
    ) !void {
        for (self.entries.items) |*entry| {
            if (entry.state == .approved) {
                try apply_fn(entry.*);
                entry.state = .committed;
            }
        }
    }

    /// Discards all non-committed speculative edits and marks them rolled back.
    /// @example
    /// journal.rollbackAll();
    pub fn rollbackAll(self: *SideEffectJournal) void {
        for (self.entries.items) |*entry| {
            if (entry.state == .pending or entry.state == .approved) {
                entry.state = .rolled_back;
            }
        }
    }

    /// Returns the count of entries in a given state.
    pub fn countByState(self: *const SideEffectJournal, state: JournalEntryState) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.state == state) count += 1;
        }
        return count;
    }
};

test "journal: record, approve, commit" {
    var journal = SideEffectJournal.init(std.testing.allocator);
    defer journal.deinit();

    const id = try journal.record(.file_write, 42, "/workspace/test.zig");
    try std.testing.expectEqual(@as(usize, 1), journal.countByState(.pending));

    try journal.approve(id);
    try std.testing.expectEqual(@as(usize, 1), journal.countByState(.approved));

    const noop = struct {
        fn apply(e: JournalEntry) anyerror!void {
            _ = e;
        }
    }.apply;
    try journal.commitApproved(noop);
    try std.testing.expectEqual(@as(usize, 1), journal.countByState(.committed));
}

test "journal: rollback discards pending and approved" {
    var journal = SideEffectJournal.init(std.testing.allocator);
    defer journal.deinit();

    _ = try journal.record(.file_write, 1, "/a");
    const id2 = try journal.record(.vcs_commit, 1, "msg");
    try journal.approve(id2);

    journal.rollbackAll();
    try std.testing.expectEqual(@as(usize, 2), journal.countByState(.rolled_back));
}


test "journal: enforces bounded entry and payload sizes" {
    var journal = SideEffectJournal.init(std.testing.allocator);
    defer journal.deinit();

    const oversized = try std.testing.allocator.alloc(u8, MAX_JOURNAL_PAYLOAD_BYTES + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(JournalError.PayloadTooLarge, journal.record(.file_write, 1, oversized));

    var i: usize = 0;
    while (i < MAX_JOURNAL_ENTRIES) : (i += 1) {
        _ = try journal.record(.file_write, 2, "x");
    }
    try std.testing.expectError(JournalError.EntryLimitExceeded, journal.record(.file_write, 2, "y"));
}
