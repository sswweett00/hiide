const std = @import("std");
const compat = @import("../compat.zig");
const agent_types = @import("../agent/types.zig");
const Scheduler = @import("../agent/scheduler.zig").Scheduler;
const WorkingMemory = @import("../memory/working_memory.zig").WorkingMemory;
const AppConfig = @import("config.zig").AppConfig;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    prng: std.Random.DefaultPrng,
    scheduler: Scheduler,
    memory: WorkingMemory,

    /// Initializes the engine runtime and shared subsystems.
    /// @example
    /// var app = try App.init(allocator, AppConfig.default());
    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !App {
        const seed = @as(u64, @intCast(compat.milliTimestamp()));
        return .{
            .allocator = allocator,
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
            .scheduler = Scheduler.init(allocator),
            .memory = WorkingMemory.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.memory.deinit();
        self.scheduler.deinit();
        self.* = undefined;
    }

    /// Seeds the scheduler with the first planner task for a workspace.
    /// @example
    /// const receipt = try app.bootstrapPlanningTask("Bootstrap workspace");
    pub fn bootstrapPlanningTask(self: *App, title: []const u8) !agent_types.TaskReceipt {
        const title_artifact = try self.memory.put(.semantic_query, title);

        const task = agent_types.AgentTask{
            .id = agent_types.nextTaskId(self.prng.random()),
            .parent_id = null,
            .kind = .planner,
            .mode = if (self.config.speculative_execution) .speculative else .sequential,
            .state = .queued,
            .budget = agent_types.TokenBudget.defaultPlanning(),
            .memory = self.memory.snapshotRefs(),
            .prompt_template_id = 0,
            .rollback_journal_id = 0,
            .title = title_artifact.bytes,
        };
        try self.scheduler.submit(task);
        return .{ .task_id = task.id, .state = .queued };
    }
};
