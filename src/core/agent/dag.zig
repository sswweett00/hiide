/// Task DAG (Directed Acyclic Graph) compiler and cycle detector.
/// Detects cycles at plan compile time and rejects invalid plans per spec §1.5.
const std = @import("std");
const types = @import("types.zig");

pub const DagError = error{
    CycleDetected,
    DuplicateNode,
    MissingDependency,
    OutOfMemory,
};

/// Lightweight DAG node referencing an AgentTask by id.
pub const DagNode = struct {
    id: u128,
    parent_id: ?u128,
    kind: types.AgentKind,
    mode: types.ExecutionMode,
    /// Indices into the compiled node list for direct children.
    children: std.ArrayListUnmanaged(usize) = .empty,
};

/// A compiled, validated task graph ready for scheduling.
pub const TaskGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(DagNode),
    /// Maps task id → node index for O(1) lookup.
    id_map: std.AutoHashMapUnmanaged(u128, usize),
    graph_id: u64,

    pub fn deinit(self: *TaskGraph) void {
        for (self.nodes.items) |*node| {
            node.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.id_map.deinit(self.allocator);
    }

    /// Returns topological ordering (Kahn's algorithm).
    /// Caller owns returned slice.
    /// @example
    /// const order = try graph.topoSort(alloc);
    pub fn topoSort(self: *const TaskGraph, alloc: std.mem.Allocator) ![]usize {
        const n = self.nodes.items.len;
        var in_degree = try alloc.alloc(usize, n);
        defer alloc.free(in_degree);
        @memset(in_degree, 0);

        for (self.nodes.items) |*node| {
            for (node.children.items) |child_idx| {
                in_degree[child_idx] += 1;
            }
        }

        var queue = std.ArrayListUnmanaged(usize).empty;
        defer queue.deinit(alloc);
        for (in_degree, 0..) |deg, i| {
            if (deg == 0) try queue.append(alloc, i);
        }

        var order = try std.ArrayListUnmanaged(usize).initCapacity(alloc, n);
        while (queue.items.len > 0) {
            const idx = queue.swapRemove(0);
            try order.append(alloc, idx);
            for (self.nodes.items[idx].children.items) |child| {
                in_degree[child] -= 1;
                if (in_degree[child] == 0) try queue.append(alloc, child);
            }
        }

        if (order.items.len != n) {
            order.deinit(alloc);
            return DagError.CycleDetected;
        }
        return order.toOwnedSlice(alloc);
    }
};

/// Compiles a flat task list into a validated DAG.
/// Rejects plans with cycles or missing parent references.
/// @example
/// const graph = try DagCompiler.compile(alloc, tasks, graph_id);
pub const DagCompiler = struct {
    pub fn compile(
        alloc: std.mem.Allocator,
        tasks: []const types.AgentTask,
        graph_id: u64,
    ) DagError!TaskGraph {
        var graph = TaskGraph{
            .allocator = alloc,
            .nodes = .empty,
            .id_map = .empty,
            .graph_id = graph_id,
        };
        errdefer graph.deinit();

        // First pass: register all nodes.
        for (tasks) |task| {
            if (graph.id_map.contains(task.id)) return DagError.DuplicateNode;
            const idx = graph.nodes.items.len;
            try graph.nodes.append(alloc, .{
                .id = task.id,
                .parent_id = task.parent_id,
                .kind = task.kind,
                .mode = task.mode,
            });
            try graph.id_map.put(alloc, task.id, idx);
        }

        // Second pass: wire parent → child edges.
        for (graph.nodes.items) |node| {
            const parent_id = node.parent_id orelse continue;
            const parent_idx = graph.id_map.get(parent_id) orelse return DagError.MissingDependency;
            const self_idx = graph.id_map.get(node.id).?;
            try graph.nodes.items[parent_idx].children.append(alloc, self_idx);
        }

        // Validate: no cycles via topoSort.
        const order = graph.topoSort(alloc) catch return DagError.CycleDetected;
        alloc.free(order);

        return graph;
    }
};

test "dag: linear chain compiles and sorts" {
    const alloc = std.testing.allocator;
    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    const tasks = [_]types.AgentTask{
        .{ .id = 1, .parent_id = null, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "root" },
        .{ .id = 2, .parent_id = 1, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "child" },
    };

    var graph = try DagCompiler.compile(alloc, &tasks, 1);
    defer graph.deinit();

    const order = try graph.topoSort(alloc);
    defer alloc.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
}

test "dag: cycle detection" {
    const alloc = std.testing.allocator;
    const budget = types.TokenBudget.defaultPlanning();
    const mem_ref = types.WorkingMemoryRef{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 };

    // Create two tasks that reference each other as parents — impossible with this flat structure,
    // so simulate a cycle by crafting parent references that form a loop.
    // Task A parent = B, Task B parent = A.
    const tasks = [_]types.AgentTask{
        .{ .id = 10, .parent_id = 11, .kind = .planner, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "a" },
        .{ .id = 11, .parent_id = 10, .kind = .coder, .mode = .sequential, .state = .queued, .budget = budget, .memory = mem_ref, .prompt_template_id = 0, .rollback_journal_id = 0, .title = "b" },
    };

    const result = DagCompiler.compile(alloc, &tasks, 2);
    try std.testing.expectError(DagError.CycleDetected, result);
}
