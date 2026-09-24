const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("types.zig");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    ready: std.ArrayListUnmanaged(types.AgentTask) = .empty,
    ready_head: usize = 0,
    canceled: std.AutoHashMapUnmanaged(u128, void) = .{},
    children: std.AutoHashMapUnmanaged(u128, std.ArrayListUnmanaged(u128)) = .{},

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        self.ready.deinit(self.allocator);
        self.canceled.deinit(self.allocator);

        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.children.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn submit(self: *Scheduler, task: types.AgentTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.canceled.contains(task.id)) return error.TaskCanceled;
        try self.ready.append(self.allocator, task);

        if (task.parent_id) |parent_id| {
            const gop = try self.children.getOrPut(self.allocator, parent_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, task.id);
        }
    }

    /// Returns the next runnable task in FIFO order.
    /// The queue uses a head index so popping is O(1) instead of shifting the
    /// whole backing array on every task. Periodic compaction keeps memory bounded.
    pub fn pop(self: *Scheduler) ?types.AgentTask {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.ready_head < self.ready.items.len) {
            const task = self.ready.items[self.ready_head];
            self.ready_head += 1;

            if (self.canceled.fetchRemove(task.id)) |_| {
                continue;
            }

            self.compactIfNeeded();
            return task;
        }

        self.ready.clearRetainingCapacity();
        self.ready_head = 0;
        return null;
    }

    fn compactIfNeeded(self: *Scheduler) void {
        const consumed = self.ready_head;
        if (consumed == 0) return;
        const remaining = self.ready.items.len - consumed;

        // Compact when the consumed prefix is substantial. This preserves the
        // O(1) hot path while preventing long-lived schedulers from retaining
        // large dead prefixes.
        if (consumed < 1024 and consumed * 2 < self.ready.items.len) return;

        if (remaining > 0) {
            std.mem.copyForwards(types.AgentTask, self.ready.items[0..remaining], self.ready.items[consumed..]);
        }
        self.ready.shrinkRetainingCapacity(remaining);
        self.ready_head = 0;
    }

    /// Cancels a task subtree rooted at `root_task_id` using BFS.
    /// The parent→children index makes this proportional to the affected
    /// subtree rather than rescanning the entire ready queue per node.
    pub fn cancelSubtree(self: *Scheduler, root_task_id: u128) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var frontier = std.ArrayListUnmanaged(u128).empty;
        defer frontier.deinit(self.allocator);
        try frontier.append(self.allocator, root_task_id);

        while (frontier.items.len > 0) {
            const current_id = frontier.pop();
            if (self.canceled.contains(current_id)) continue;
            try self.canceled.put(self.allocator, current_id, {});

            if (self.children.get(current_id)) |descendants| {
                for (descendants.items) |child_id| {
                    if (!self.canceled.contains(child_id)) {
                        try frontier.append(self.allocator, child_id);
                    }
                }
            }
        }
    }
};

test "scheduler: cancelSubtree cancels transitive descendants" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    try scheduler.submit(.{ .id = 1, .parent_id = null, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "root" });
    try scheduler.submit(.{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "child" });
    try scheduler.submit(.{ .id = 3, .parent_id = 2, .kind = .tester, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "grandchild" });

    try scheduler.cancelSubtree(1);
    try std.testing.expectEqual(@as(?types.AgentTask, null), scheduler.pop());
    try std.testing.expectEqual(@as(usize, 0), scheduler.canceled.count());
}

test "scheduler: pop skips multiple cancelled tasks and returns first valid one" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    try scheduler.submit(.{ .id = 10, .parent_id = null, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t10" });
    try scheduler.submit(.{ .id = 11, .parent_id = null, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t11" });
    try scheduler.submit(.{ .id = 12, .parent_id = null, .kind = .tester, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t12" });

    try scheduler.cancelSubtree(10);
    try scheduler.cancelSubtree(11);

    const task = scheduler.pop();
    try std.testing.expect(task != null);
    try std.testing.expectEqual(@as(u128, 12), task.?.id);
    try std.testing.expectEqual(@as(usize, 0), scheduler.canceled.count());
}

test "scheduler enqueues and pops task" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const task = types.AgentTask{
        .id = 1,
        .parent_id = null,
        .kind = .planner,
        .mode = .sequential,
        .state = .queued,
        .budget = types.TokenBudget.defaultPlanning(),
        .memory = .{
            .symbol_snapshot_id = 0,
            .task_graph_id = 0,
            .policy_snapshot_id = 0,
            .artifact_set_id = 0,
        },
        .prompt_template_id = 0,
        .rollback_journal_id = 0,
        .title = "bootstrap",
    };

    try scheduler.submit(task);
    try std.testing.expectEqual(@as(usize, 1), scheduler.ready.items.len);
    const popped = scheduler.pop() orelse return error.ExpectedTask;
    try std.testing.expectEqual(task.id, popped.id);
    try std.testing.expectEqual(task.kind, popped.kind);
}

test "scheduler preserves FIFO order across compaction" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    var id: u128 = 1000;
    while (id < 3100) : (id += 1) {
        try scheduler.submit(.{ .id = id, .parent_id = null, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "fifo" });
    }

    var expected: u128 = 1000;
    while (expected < 3100) : (expected += 1) {
        const task = scheduler.pop() orelse return error.ExpectedTask;
        try std.testing.expectEqual(expected, task.id);
    }
    try std.testing.expectEqual(@as(?types.AgentTask, null), scheduler.pop());
}
