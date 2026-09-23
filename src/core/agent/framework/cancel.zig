/// Cooperative cancellation with subtree propagation and deadlines.
///
/// Spec §1.3 requires cancellation to propagate by subtree ID and to invalidate
/// journal handles *before* any filesystem, network, or VCS mutation. Tokens are
/// therefore checked at every await point: agent entry, tool invocation, retry
/// boundaries, and journal commit.
const std = @import("std");
const compat = @import("../../compat.zig");
const clock_mod = @import("clock.zig");

pub const CancelReason = enum(u8) {
    none = 0,
    user_request,
    parent_canceled,
    deadline_exceeded,
    budget_exhausted,
    policy_denied,
    superseded,
    shutdown,
    upstream_failure,
};

pub const CancelError = error{
    Canceled,
    DeadlineExceeded,
};

/// A cancellation token shared between the scheduler, an agent, and its tools.
/// Tokens form a parent chain so that cancelling an ancestor cancels all
/// descendants without walking a registry.
pub const Token = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reason_raw: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(CancelReason.none)),
    /// Absolute unix-ms deadline; null means unbounded.
    deadline_ms: ?i64 = null,
    parent: ?*Token = null,

    /// Creates a detached root token.
    /// @example
    /// var token = Token.init(null);
    pub fn init(deadline_ms: ?i64) Token {
        return .{ .deadline_ms = deadline_ms };
    }

    /// Creates a token linked to `parent`; the tighter deadline wins.
    /// @example
    /// var child = Token.child(&root, clock.deadlineIn(5_000));
    pub fn child(parent: *Token, deadline_ms: ?i64) Token {
        const inherited = tighter(parent.deadline_ms, deadline_ms);
        return .{ .deadline_ms = inherited, .parent = parent };
    }

    fn tighter(a: ?i64, b: ?i64) ?i64 {
        if (a == null) return b;
        if (b == null) return a;
        return @min(a.?, b.?);
    }

    /// Marks this token cancelled. Idempotent: the first reason is retained.
    /// @example
    /// token.cancel(.user_request);
    pub fn cancel(self: *Token, why: CancelReason) void {
        _ = self.reason_raw.cmpxchgStrong(
            @intFromEnum(CancelReason.none),
            @intFromEnum(why),
            .acq_rel,
            .acquire,
        );
        self.flag.store(true, .release);
    }

    /// Returns true when this token or any ancestor is cancelled.
    /// @example
    /// if (token.isCanceled()) return;
    pub fn isCanceled(self: *const Token) bool {
        if (self.flag.load(.acquire)) return true;
        var cursor = self.parent;
        while (cursor) |p| {
            if (p.flag.load(.acquire)) return true;
            cursor = p.parent;
        }
        return false;
    }

    /// Returns the effective cancellation reason, walking ancestors.
    /// @example
    /// const why = token.reason();
    pub fn reason(self: *const Token) CancelReason {
        if (self.flag.load(.acquire)) {
            return @enumFromInt(self.reason_raw.load(.acquire));
        }
        var cursor = self.parent;
        while (cursor) |p| {
            if (p.flag.load(.acquire)) return .parent_canceled;
            cursor = p.parent;
        }
        return .none;
    }

    /// Returns true when the token's (or an ancestor's) deadline has elapsed.
    /// @example
    /// if (token.isExpired(clock)) return error.DeadlineExceeded;
    pub fn isExpired(self: *const Token, c: clock_mod.Clock) bool {
        const now = c.nowMs();
        if (self.deadline_ms) |d| {
            if (now >= d) return true;
        }
        var cursor = self.parent;
        while (cursor) |p| {
            if (p.deadline_ms) |d| {
                if (now >= d) return true;
            }
            cursor = p.parent;
        }
        return false;
    }

    /// Single await-point check used by agents, tools, and the executor.
    /// Deadline expiry auto-cancels the token so descendants observe it too.
    /// @example
    /// try ctx.cancel.check(clock);
    pub fn check(self: *Token, c: clock_mod.Clock) CancelError!void {
        if (self.isCanceled()) return CancelError.Canceled;
        if (self.isExpired(c)) {
            self.cancel(.deadline_exceeded);
            return CancelError.DeadlineExceeded;
        }
    }

    /// Milliseconds left before the deadline; null when unbounded.
    /// @example
    /// const left = token.remainingMs(clock);
    pub fn remainingMs(self: *const Token, c: clock_mod.Clock) ?u64 {
        var best: ?i64 = self.deadline_ms;
        var cursor = self.parent;
        while (cursor) |p| {
            if (p.deadline_ms) |d| {
                best = if (best) |b| @min(b, d) else d;
            }
            cursor = p.parent;
        }
        const deadline = best orelse return null;
        const delta = deadline - c.nowMs();
        if (delta <= 0) return 0;
        return @intCast(delta);
    }
};

/// Registry of cancellation tokens keyed by task id, mirroring the plan DAG.
/// `cancelSubtree` performs a BFS over registered children so that speculative
/// descendants are stopped before they can journal a side effect.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    nodes: std.AutoHashMapUnmanaged(u128, *Node) = .{},

    pub const Node = struct {
        token: Token,
        task_id: u128,
        parent_id: ?u128,
        children: std.ArrayListUnmanaged(u128) = .empty,
    };

    /// Creates an empty cancellation tree.
    /// @example
    /// var tree = Tree.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.children.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers `task_id` under `parent_id` and returns its stable token pointer.
    /// Re-registering an existing id returns the existing token.
    /// @example
    /// const token = try tree.register(task_id, parent_id, deadline_ms);
    pub fn register(
        self: *Tree,
        task_id: u128,
        parent_id: ?u128,
        deadline_ms: ?i64,
    ) !*Token {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.nodes.get(task_id)) |existing| return &existing.token;

        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);

        var token = Token.init(deadline_ms);
        if (parent_id) |pid| {
            if (self.nodes.get(pid)) |parent_node| {
                token = Token.child(&parent_node.token, deadline_ms);
            }
        }

        node.* = .{ .token = token, .task_id = task_id, .parent_id = parent_id };
        try self.nodes.put(self.allocator, task_id, node);

        if (parent_id) |pid| {
            if (self.nodes.get(pid)) |parent_node| {
                try parent_node.children.append(self.allocator, task_id);
            }
        }
        return &node.token;
    }

    /// Returns the token for `task_id`, or null when unregistered.
    /// @example
    /// const token = tree.get(task_id) orelse return;
    pub fn get(self: *Tree, task_id: u128) ?*Token {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = self.nodes.get(task_id) orelse return null;
        return &node.token;
    }

    /// Removes one task token after its run has fully completed.
    /// This prevents long-lived orchestrators from retaining every historical
    /// task id forever. Callers must ensure no worker still references the token.
    pub fn unregister(self: *Tree, task_id: u128) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = self.nodes.fetchRemove(task_id) orelse return false;
        if (node.value.parent_id) |pid| {
            if (self.nodes.get(pid)) |parent| {
                var i: usize = 0;
                while (i < parent.children.items.len) : (i += 1) {
                    if (parent.children.items[i] == task_id) {
                        _ = parent.children.orderedRemove(i);
                        break;
                    }
                }
            }
        }
        node.value.children.deinit(self.allocator);
        self.allocator.destroy(node.value);
        return true;
    }

    /// Cancels `root_task_id` and every transitive descendant.
    /// Returns the number of tokens transitioned to cancelled.
    /// @example
    /// const n = try tree.cancelSubtree(root_id, .user_request);
    pub fn cancelSubtree(self: *Tree, root_task_id: u128, reason: CancelReason) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var frontier = std.ArrayListUnmanaged(u128).empty;
        defer frontier.deinit(self.allocator);
        try frontier.append(self.allocator, root_task_id);

        var canceled_count: usize = 0;
        var cursor: usize = 0;
        while (cursor < frontier.items.len) : (cursor += 1) {
            const id = frontier.items[cursor];
            const node = self.nodes.get(id) orelse continue;
            if (!node.token.flag.load(.acquire)) {
                node.token.cancel(if (id == root_task_id) reason else .parent_canceled);
                canceled_count += 1;
            }
            for (node.children.items) |child_id| {
                try frontier.append(self.allocator, child_id);
            }
        }
        return canceled_count;
    }

    /// Cancels every registered token, e.g. on engine shutdown.
    /// @example
    /// tree.cancelAll(.shutdown);
    pub fn cancelAll(self: *Tree, reason: CancelReason) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.token.cancel(reason);
        }
    }

    /// Number of registered tasks.
    pub fn count(self: *Tree) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.nodes.count();
    }
};

test "cancel: parent cancellation propagates to child tokens" {
    var root = Token.init(null);
    var child = Token.child(&root, null);
    var grandchild = Token.child(&child, null);

    try std.testing.expect(!grandchild.isCanceled());
    root.cancel(.user_request);
    try std.testing.expect(grandchild.isCanceled());
    try std.testing.expectEqual(CancelReason.parent_canceled, grandchild.reason());
    try std.testing.expectEqual(CancelReason.user_request, root.reason());
}

test "cancel: deadline expiry converts to cancellation" {
    var mc = clock_mod.ManualClock.init(0);
    const c = mc.clock();

    var token = Token.init(c.deadlineIn(100));
    try token.check(c);

    mc.advance(101);
    try std.testing.expectError(CancelError.DeadlineExceeded, token.check(c));
    try std.testing.expect(token.isCanceled());
    try std.testing.expectEqual(CancelReason.deadline_exceeded, token.reason());
}

test "cancel: child inherits the tighter deadline" {
    var mc = clock_mod.ManualClock.init(0);
    const c = mc.clock();

    var root = Token.init(c.deadlineIn(50));
    var child = Token.child(&root, c.deadlineIn(5_000));

    try std.testing.expectEqual(@as(?u64, 50), child.remainingMs(c));
    mc.advance(60);
    try std.testing.expect(child.isExpired(c));
}

test "cancel: tree cancels transitive subtree only" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.register(1, null, null);
    _ = try tree.register(2, 1, null);
    _ = try tree.register(3, 2, null);
    const sibling = try tree.register(4, null, null);

    const n = try tree.cancelSubtree(1, .user_request);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(tree.get(3).?.isCanceled());
    try std.testing.expect(!sibling.isCanceled());
    try std.testing.expectEqual(@as(usize, 4), tree.count());
}

test "cancel: subtree cancellation is idempotent" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.register(10, null, null);
    _ = try tree.register(11, 10, null);

    try std.testing.expectEqual(@as(usize, 2), try tree.cancelSubtree(10, .shutdown));
    try std.testing.expectEqual(@as(usize, 0), try tree.cancelSubtree(10, .shutdown));
}

test "cancel: token is thread-safe under concurrent observers" {
    var root = Token.init(null);
    var observed = std.atomic.Value(u32).init(0);

    const Worker = struct {
        fn run(token: *Token, counter: *std.atomic.Value(u32)) void {
            var spins: usize = 0;
            while (spins < 10_000) : (spins += 1) {
                if (token.isCanceled()) {
                    _ = counter.fetchAdd(1, .acq_rel);
                    return;
                }
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &root, &observed });
    }
    root.cancel(.shutdown);
    for (&threads) |*t| t.join();

    try std.testing.expect(observed.load(.acquire) >= 1);
}
