const std = @import("std");
const App = @import("../runtime/app.zig").App;
const AppConfig = @import("../runtime/config.zig").AppConfig;
const agent_types = @import("../agent/types.zig");

pub const EngineHandle = *App;
const version_cstr: [*:0]const u8 = "0.1.0-dev";

pub const CTaskReceipt = extern struct {
    task_id_hi: u64,
    task_id_lo: u64,
    state: u8,
};

/// Returns the engine version string exposed over the C ABI.
/// @example
/// const version = hiide_engine_version();
pub export fn hiide_engine_version() callconv(.C) [*:0]const u8 {
    return version_cstr;
}

/// Creates an engine instance using default local configuration.
/// @example
/// const handle = hiide_engine_init();
pub export fn hiide_engine_init() callconv(.C) ?EngineHandle {
    const allocator = std.heap.c_allocator;
    const app = allocator.create(App) catch return null;
    app.* = App.init(allocator, AppConfig.default()) catch {
        allocator.destroy(app);
        return null;
    };
    return app;
}

/// Destroys a previously created engine instance.
/// @example
/// hiide_engine_deinit(handle);
pub export fn hiide_engine_deinit(handle: ?EngineHandle) callconv(.C) void {
    if (handle) |app| {
        const allocator = std.heap.c_allocator;
        app.deinit();
        allocator.destroy(app);
    }
}

/// Submits the initial workspace bootstrap task.
/// @example
/// const receipt = hiide_engine_submit_bootstrap_task(handle, "Bootstrap workspace");
pub export fn hiide_engine_submit_bootstrap_task(handle: ?EngineHandle, title: [*:0]const u8) callconv(.C) CTaskReceipt {
    if (handle == null) return .{ .task_id_hi = 0, .task_id_lo = 0, .state = @intFromEnum(agent_types.TaskState.failed) };

    const slice = std.mem.span(title);
    const receipt = handle.?.bootstrapPlanningTask(slice) catch {
        return .{ .task_id_hi = 0, .task_id_lo = 0, .state = @intFromEnum(agent_types.TaskState.failed) };
    };
    return .{
        .task_id_hi = @truncate(receipt.task_id >> 64),
        .task_id_lo = @truncate(receipt.task_id),
        .state = @intFromEnum(receipt.state),
    };
}
