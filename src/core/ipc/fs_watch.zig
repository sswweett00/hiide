/// Native workspace file watcher.
///
/// The Flutter frontend subscribes to a workspace root via `watch.subscribe`;
/// this module detects changes on disk and pushes `fs.change` events back over
/// the subscriber's socket. Detection is a hybrid:
///
///  1. **Trigger** — on Linux an inotify instance watches the workspace root
///     and every subdirectory (recursive watch maintenance); elsewhere a
///     periodic scan (1s) is used.
///  2. **Report** — on every trigger, the root is re-enumerated with the same
///     native `workspaceTree` walker the IDE uses and diffed against the last
///     snapshot (path / kind / size / mtime), so created / modified / deleted
///     changes are computed once and pushed in a single event line.
///
/// Threading: one background thread owns the inotify fd and the rescan logic.
/// Subscribers are registered in a process-global list guarded by a mutex;
/// the watcher holds that mutex while pushing (writes are small, one line) and
/// the connection thread never takes it while writing responses, so the lock
/// ordering is acyclic. Each subscriber owns a per-connection write mutex so a
/// push can never interleave with a request/response write.
const std = @import("std");
const compat = @import("../compat.zig");
const builtin = @import("builtin");
const workspace_tools = @import("../agent/framework/workspace_tools.zig");

const is_linux = builtin.os.tag == .linux;

const allocator = std.heap.c_allocator;
const max_entries: usize = 50_000;
const max_subscribers: usize = 32;
const max_roots_per_connection: usize = 2;

pub const ChangeKind = enum { created, modified, deleted };

pub const Change = struct {
    path: []const u8, // workspace-relative, allocator-owned
    is_dir: bool,
    kind: ChangeKind,
};

/// One connected client watching one root.
pub const Subscriber = struct {
    id: u64,
    root: []const u8, // allocator-owned copy (subscription root as sent)
    conn: compat.TcpConnection,
    write_mutex: *compat.Mutex,
};

// ── Snapshot diff (pure, unit-tested) ────────────────────────────────────────

const Meta = struct { is_dir: bool, size: u64, mtime_ns: i128 };

/// Computes the change set between two enumerations of the same root.
/// `new` files/dirs missing from `old` are `created`; entries whose kind, size
/// or mtime changed are `modified`; `old` entries missing from `new` are
/// `deleted`. Result paths are allocator-owned.
pub fn diffSnapshots(
    a: std.mem.Allocator,
    old: []const workspace_tools.WorkspaceEntry,
    new: []const workspace_tools.WorkspaceEntry,
) ![]Change {
    var old_map = std.StringHashMap(Meta).init(a);
    defer old_map.deinit();
    for (old) |e| {
        try old_map.put(e.path, .{ .is_dir = e.kind == .directory, .size = e.size, .mtime_ns = e.mtime_ns });
    }

    var new_map = std.StringHashMap(Meta).init(a);
    defer new_map.deinit();
    for (new) |e| {
        try new_map.put(e.path, .{ .is_dir = e.kind == .directory, .size = e.size, .mtime_ns = e.mtime_ns });
    }

    var changes = compat.ManagedArrayList(Change).init(a);
    errdefer {
        for (changes.items) |c| a.free(c.path);
        changes.deinit();
    }

    for (new) |e| {
        const meta = old_map.get(e.path) orelse {
            try changes.append(.{
                .path = try a.dupe(u8, e.path),
                .is_dir = e.kind == .directory,
                .kind = .created,
            });
            continue;
        };
        if (meta.is_dir != (e.kind == .directory) or meta.size != e.size or meta.mtime_ns != e.mtime_ns) {
            try changes.append(.{
                .path = try a.dupe(u8, e.path),
                .is_dir = e.kind == .directory,
                .kind = .modified,
            });
        }
    }

    for (old) |e| {
        if (!new_map.contains(e.path)) {
            try changes.append(.{
                .path = try a.dupe(u8, e.path),
                .is_dir = e.kind == .directory,
                .kind = .deleted,
            });
        }
    }

    return changes.toOwnedSlice();
}

// ── Global subscriber registry ───────────────────────────────────────────────

var registry: std.ArrayListUnmanaged(Subscriber) = .empty;
var registry_mutex: compat.Mutex = .init;
var subs_version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var next_sub_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
/// root (allocator-owned key) → last enumeration (allocator-owned entries).
var snapshots: std.StringHashMapUnmanaged([]workspace_tools.WorkspaceEntry) = .{};

var watcher_started = std.atomic.Value(bool).init(false);

/// Spins up the background watcher thread (idempotent).
pub fn ensureStarted() void {
    if (watcher_started.load(.acquire)) return;

    if (watcher_started.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        if (!startWatcher()) {
            watcher_started.store(false, .release);
        }
    }
}

/// Allocates a fresh connection id for `handleConnection`.
pub fn newConnectionId() u64 {
    return next_sub_id.fetchAdd(1, .monotonic);
}

/// Registers `conn` (which writes through `write_mutex`) as a subscriber for
/// `root`. `root` is copied.
pub fn subscribe(
    id: u64,
    root: []const u8,
    conn: compat.TcpConnection,
    write_mutex: *compat.Mutex,
) !void {
    // Validate the root before retaining it. This also rejects files and
    // vanished paths instead of letting the watcher silently spin forever.
    const probe = workspace_tools.workspaceTree(allocator, root, 1) catch return error.InvalidWatchRoot;
    defer {
        for (probe) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(probe);
    }

    registry_mutex.lock();
    defer registry_mutex.unlock();

    var roots_for_connection: usize = 0;
    for (registry.items) |sub| {
        if (sub.id != id) continue;
        if (std.mem.eql(u8, sub.root, root)) return; // already subscribed
        roots_for_connection += 1;
    }

    if (roots_for_connection >= max_roots_per_connection) return error.TooManyWatchRoots;
    if (registry.items.len >= max_subscribers) return error.TooManyWatchers;

    try registry.append(allocator, .{
        .id = id,
        .root = try allocator.dupe(u8, root),
        .conn = conn,
        .write_mutex = write_mutex,
    });
    _ = subs_version.fetchAdd(1, .acq_rel);
}

/// Removes every subscription owned by connection `id` (called when the
/// connection closes, before its socket is torn down).
pub fn unsubscribeAll(id: u64) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    var i: usize = 0;
    while (i < registry.items.len) {
        if (registry.items[i].id == id) {
            allocator.free(registry.items[i].root);
            _ = registry.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    _ = subs_version.fetchAdd(1, .acq_rel);
    pruneSnapshotsLocked();
}

fn pruneSnapshotsLocked() void {
    var it = snapshots.iterator();
    while (it.next()) |entry| {
        var still_watched = false;
        for (registry.items) |sub| {
            if (std.mem.eql(u8, sub.root, entry.key_ptr.*)) {
                still_watched = true;
                break;
            }
        }
        if (!still_watched) {
            freeEntries(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
            _ = snapshots.remove(entry.key_ptr.*);
        }
    }
}

fn freeEntries(entries: []workspace_tools.WorkspaceEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
    }
    allocator.free(entries);
}

// ── Rescan + push (registry_mutex must be held) ──────────────────────────────

/// Changes computed for the most recently rescanned root; consumed by
/// `rescanAndPushLocked` to push one event per subscriber of that root.
/// The `Change.path` strings are OWNED by this list.
var last_changes: compat.ManagedArrayList(Change) = compat.ManagedArrayList(Change).init(allocator);
var last_changes_root: []const u8 = "";

/// Re-enumerates every distinct subscribed root once, diffs against its last
/// snapshot, and pushes one event line per subscriber whose root changed.
fn rescanAndPushLocked() void {
    var seen = compat.ManagedArrayList([]const u8).init(allocator);
    defer seen.deinit();

    for (registry.items) |*sub| {
        var already = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, sub.root)) {
                already = true;
                break;
            }
        }
        if (!already) {
            seen.append(sub.root) catch return;
            rescanRootLocked(sub.root);
        }
        if (last_changes.items.len > 0 and std.mem.eql(u8, last_changes_root, sub.root)) {
            pushRootLocked(sub);
        }
    }

    for (last_changes.items) |c| allocator.free(c.path);
    last_changes.deinit();
    last_changes = compat.ManagedArrayList(Change).init(allocator);
    last_changes_root = "";
}

/// Rescans `root`, stores the new snapshot, and leaves the resulting changes
/// (if any) in `last_changes` with `last_changes_root = root`.
fn rescanRootLocked(root: []const u8) void {
    // Release the previous cycle's changes (paths owned by last_changes).
    for (last_changes.items) |c| allocator.free(c.path);
    last_changes.deinit();
    last_changes = compat.ManagedArrayList(Change).init(allocator);
    last_changes_root = "";

    const entries = workspace_tools.workspaceTree(allocator, root, max_entries) catch return;
    errdefer freeEntries(entries);

    const old = snapshots.get(root);
    if (old) |o| {
        const changes = diffSnapshots(allocator, o, entries) catch return;
        errdefer {
            for (changes) |c| allocator.free(c.path);
            allocator.free(changes);
        }
        freeEntries(o);
        // With an existing key this cannot allocate, so it cannot fail here.
        snapshots.put(allocator, root, entries) catch return;
        // Transfer path ownership to last_changes: appendSlice copies the
        // Change structs, the path strings move with them. Only the diff's
        // array container is freed; on append failure the errdefer above
        // frees the strings and the caller aborts the cycle.
        last_changes.appendSlice(changes) catch return;
        allocator.free(changes);
    } else {
        const key = allocator.dupe(u8, root) catch return;
        snapshots.put(allocator, key, entries) catch return;
    }
    last_changes_root = root;
}

/// Serializes and writes one `fs.change` event line to `sub`'s socket.
fn pushRootLocked(sub: *Subscriber) void {
    var line = compat.ManagedArrayList(u8).init(allocator);
    defer line.deinit();
    serializeEvent(&line, sub.root, last_changes.items) catch return;

    sub.write_mutex.lock();
    defer sub.write_mutex.unlock();
    sub.conn.stream.writeAll(line.items) catch {};
}

const ChangeJson = struct {
    path: []const u8,
    kind: []const u8,
    is_dir: bool,
};

const EventJson = struct {
    event: []const u8 = "fs.change",
    params: struct {
        root: []const u8,
        changes: []const ChangeJson,
    },
};

fn serializeEvent(line: *compat.ManagedArrayList(u8), root: []const u8, changes: []const Change) !void {
    const json_changes = try allocator.alloc(ChangeJson, changes.len);
    defer allocator.free(json_changes);
    for (changes, 0..) |c, i| {
        json_changes[i] = .{ .path = c.path, .kind = @tagName(c.kind), .is_dir = c.is_dir };
    }
    const ev = EventJson{ .params = .{ .root = root, .changes = json_changes } };
    const bytes = try compat.jsonStringifyAlloc(allocator, ev, .{});
    defer allocator.free(bytes);
    try line.appendSlice(bytes);
    try line.append('\n');
}

// ── Watcher thread ───────────────────────────────────────────────────────────

fn startWatcher() bool {
    const thread = std.Thread.spawn(.{}, watcherThread, .{}) catch return false;
    thread.detach();
    return true;
}

fn watcherThread() void {
    if (comptime is_linux) {
        linuxWatcherThread();
    } else {
        pollWatcherThread();
    }
}

/// Non-Linux fallback: full rescan + push every second.
fn pollWatcherThread() void {
    while (true) {
        registry_mutex.lock();
        rescanAndPushLocked();
        registry_mutex.unlock();
        std.time.sleep(std.time.ns_per_s);
    }
}

// ── Linux: inotify (event-driven trigger) ────────────────────────────────────

const linux = std.os.linux;

const IN_ACCESS: u32 = 0x00000001;
const IN_MODIFY: u32 = 0x00000002;
const IN_ATTRIB: u32 = 0x00000004;
const IN_CLOSE_WRITE: u32 = 0x00000008;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_DELETE_SELF: u32 = 0x00000400;
const IN_MOVE_SELF: u32 = 0x00000800;
const IN_IGNORED: u32 = 0x00008000;
const IN_Q_OVERFLOW: u32 = 0x00004000;
const IN_ISDIR: u32 = 0x40000000;

const WATCH_MASK = IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF;

fn linuxWatcherThread() void {
    const fd = std.posix.inotify_init1(0) catch return;
    defer std.posix.close(fd);

    // wd → absolute directory path (allocator-owned)
    var wd_map = std.AutoHashMap(i32, []u8).init(allocator);
    defer {
        var it = wd_map.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        wd_map.deinit();
    }

    var last_version: u32 = 0;
    var idle_ticks: u32 = 0;
    var pollfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};

    while (true) {
        const version = subs_version.load(.acquire);
        if (version != last_version) {
            rebuildWatches(fd, &wd_map);
            last_version = version;
        }

        const ready = std.posix.poll(&pollfds, 1000) catch 0;
        if (ready == 0) {
            // Safety net: a full rescan every few seconds catches anything
            // inotify missed (rare, e.g. a watch we failed to add).
            idle_ticks += 1;
            if (idle_ticks >= 3) {
                idle_ticks = 0;
                registry_mutex.lock();
                rescanAndPushLocked();
                registry_mutex.unlock();
            }
            continue;
        }
        idle_ticks = 0;

        var buf: [65536]u8 align(8) = undefined;
        const count = std.posix.read(fd, &buf) catch continue;

        var touched = false;
        var off: usize = 0;
        while (off < count) {
            const ev: *const linux.inotify_event = @alignCast(@ptrCast(&buf[off]));
            off += @sizeOf(linux.inotify_event) + ev.len;

            if (ev.mask & (IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_Q_OVERFLOW) != 0) {
                touched = true;
            }
            if (ev.mask & IN_IGNORED != 0) {
                // Kernel dropped the watch (directory deleted): forget it.
                if (wd_map.fetchRemove(ev.wd)) |kv| allocator.free(kv.value);
                continue;
            }
            // New directory appeared: start watching it so nested changes
            // keep triggering.
            if (ev.mask & IN_ISDIR != 0 and ev.mask & (IN_CREATE | IN_MOVED_TO) != 0) {
                if (ev.getName()) |name| {
                    if (wd_map.get(ev.wd)) |parent| {
                        const sub_path = std.fs.path.join(allocator, &.{ parent, name }) catch continue;
                        addWatch(fd, &wd_map, sub_path) catch allocator.free(sub_path);
                    }
                }
            }
        }

        if (touched) {
            registry_mutex.lock();
            rescanAndPushLocked();
            registry_mutex.unlock();
        }
    }
}

/// Tears down every inotify watch and rebuilds them from the current
/// subscriptions (also seeds fresh snapshots so existing files don't fire).
fn rebuildWatches(fd: i32, wd_map: *std.AutoHashMap(i32, []u8)) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    var it = wd_map.iterator();
    while (it.next()) |entry| {
        std.posix.inotify_rm_watch(fd, entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    wd_map.clearRetainingCapacity();

    var seen = compat.ManagedArrayList([]const u8).init(allocator);
    defer seen.deinit();

    for (registry.items) |sub| {
        var already = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, sub.root)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        seen.append(sub.root) catch continue;

        // Seed the snapshot (no push) so only future changes are reported.
        rescanRootLocked(sub.root);
        const entries = snapshots.get(sub.root) orelse continue;

        // Watch the root itself and every subdirectory. Relative roots are
        // fine — inotify resolves them against the process cwd.
        addWatch(fd, wd_map, sub.root) catch {};
        for (entries) |e| {
            if (e.kind != .directory) continue;
            const abs = std.fs.path.join(allocator, &.{ sub.root, e.path }) catch continue;
            addWatch(fd, wd_map, abs) catch allocator.free(abs);
        }
    }
}

/// Adds an inotify watch for `path` and records wd → path (owned copy).
fn addWatch(fd: i32, wd_map: *std.AutoHashMap(i32, []u8), path: []const u8) !void {
    const wd = std.posix.inotify_add_watch(fd, path, WATCH_MASK) catch return;
    const owned = try allocator.dupe(u8, path);
    wd_map.put(wd, owned) catch {
        std.posix.inotify_rm_watch(fd, wd);
        allocator.free(owned);
        return;
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkEntry(path: []const u8, is_dir: bool, size: u64, mtime_ns: i128) workspace_tools.WorkspaceEntry {
    return .{
        .name = path,
        .path = path,
        .kind = if (is_dir) .directory else .file,
        .size = size,
        .mtime_ns = mtime_ns,
    };
}

test "diff: created, modified and deleted detection" {
    const old = [_]workspace_tools.WorkspaceEntry{
        mkEntry("a.txt", false, 10, 100),
        mkEntry("dir", true, 0, 0),
        mkEntry("gone.txt", false, 5, 200),
    };
    const new = [_]workspace_tools.WorkspaceEntry{
        mkEntry("a.txt", false, 10, 150), // mtime changed → modified
        mkEntry("dir", true, 0, 0),
        mkEntry("fresh.txt", false, 3, 300), // created
    };

    const changes = try diffSnapshots(testing.allocator, &old, &new);
    defer {
        for (changes) |c| testing.allocator.free(c.path);
        testing.allocator.free(changes);
    }

    try testing.expectEqual(@as(usize, 3), changes.len);
    var saw_modified = false;
    var saw_created = false;
    var saw_deleted = false;
    for (changes) |c| {
        if (std.mem.eql(u8, c.path, "a.txt")) {
            saw_modified = true;
            try testing.expectEqual(ChangeKind.modified, c.kind);
            try testing.expect(!c.is_dir);
        } else if (std.mem.eql(u8, c.path, "fresh.txt")) {
            saw_created = true;
            try testing.expectEqual(ChangeKind.created, c.kind);
        } else if (std.mem.eql(u8, c.path, "gone.txt")) {
            saw_deleted = true;
            try testing.expectEqual(ChangeKind.deleted, c.kind);
        }
    }
    try testing.expect(saw_modified);
    try testing.expect(saw_created);
    try testing.expect(saw_deleted);
}

test "diff: size change and kind flip are modifications" {
    const old = [_]workspace_tools.WorkspaceEntry{
        mkEntry("f.txt", false, 10, 100),
        mkEntry("t", false, 4, 50),
    };
    const new = [_]workspace_tools.WorkspaceEntry{
        mkEntry("f.txt", false, 12, 100), // size changed, same mtime
        mkEntry("t", true, 0, 0), // file → directory
    };

    const changes = try diffSnapshots(testing.allocator, &old, &new);
    defer {
        for (changes) |c| testing.allocator.free(c.path);
        testing.allocator.free(changes);
    }
    try testing.expectEqual(@as(usize, 2), changes.len);
    for (changes) |c| try testing.expectEqual(ChangeKind.modified, c.kind);
}

test "diff: identical snapshots produce no changes" {
    const a = [_]workspace_tools.WorkspaceEntry{
        mkEntry("x.zig", false, 8, 42),
        mkEntry("sub", true, 0, 0),
    };
    const changes = try diffSnapshots(testing.allocator, &a, &a);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}
