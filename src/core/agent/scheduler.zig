const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("types.zig");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    ready: std.ArrayListUnmanaged(types.AgentTask) = .empty,
    canceled: std.AutoHashMapUnmanaged(u128, void) = .{},

    /// Initializes the scheduler state for a single engine instance.
    /// @example
    /// var scheduler = Scheduler.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        self.ready.deinit(self.allocator);
        self.canceled.deinit(self.allocator);
        self.* = undefined;
    }

    /// Enqueues a task if it has not been cancelled.
    /// @example
    /// try scheduler.submit(task);
    pub fn submit(self: *Scheduler, task: types.AgentTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.canceled.contains(task.id)) return error.TaskCanceled;
        try self.ready.append(self.allocator, task);
    }

    /// Returns the next runnable task in FIFO order, skipping and purging cancelled tasks.
    /// @example
    /// const task = scheduler.pop() orelse return;
    pub fn pop(self: *Scheduler) ?types.AgentTask {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.ready.items.len > 0) {
            const task = self.ready.orderedRemove(0);
            if (!self.canceled.contains(task.id)) return task;
            // Cancelled task is silently discarded; keep draining.
        }
        return null;
    }

    /// Cancels a task subtree rooted at `root_task_id` using BFS.
    /// All transitive descendants are marked cancelled, not just direct children.
    /// @example
    /// try scheduler.cancelSubtree(task_id);
    pub fn cancelSubtree(self: *Scheduler, root_task_id: u128) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // BFS frontier: collect all IDs to cancel transitively.
        var frontier = std.ArrayListUnmanaged(u128).empty;
        defer frontier.deinit(self.allocator);

        try frontier.append(self.allocator, root_task_id);

        while (frontier.items.len > 0) {
            const current_id = frontier.swapRemove(0);
            try self.canceled.put(self.allocator, current_id, {});

            // Find all direct children of current_id in the ready queue.
            for (self.ready.items) |task| {
                if (task.parent_id == current_id and !self.canceled.contains(task.id)) {
                    try frontier.append(self.allocator, task.id);
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

    // Submit: root(1) → child(2) → grandchild(3).
    try scheduler.submit(.{ .id = 1, .parent_id = null,  .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "root" });
    try scheduler.submit(.{ .id = 2, .parent_id = 1,    .kind = .coder,   .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "child" });
    try scheduler.submit(.{ .id = 3, .parent_id = 2,    .kind = .tester,  .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "grandchild" });

    try scheduler.cancelSubtree(1);

    // All three should be cancelled — pop should return null.
    try std.testing.expectEqual(@as(?types.AgentTask, null), scheduler.pop());
    try std.testing.expect(scheduler.canceled.contains(1));
    try std.testing.expect(scheduler.canceled.contains(2));
    try std.testing.expect(scheduler.canceled.contains(3));
}

test "scheduler: pop skips multiple cancelled tasks and returns first valid one" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    try scheduler.submit(.{ .id = 10, .parent_id = null, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t10" });
    try scheduler.submit(.{ .id = 11, .parent_id = null, .kind = .coder,   .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t11" });
    try scheduler.submit(.{ .id = 12, .parent_id = null, .kind = .tester,  .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "t12" });

    try scheduler.cancelSubtree(10);
    try scheduler.cancelSubtree(11);

    const task = scheduler.pop();
    try std.testing.expect(task != null);
    try std.testing.expectEqual(@as(u128, 12), task.?.id);
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
