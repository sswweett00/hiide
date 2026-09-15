const std = @import("std");
const hiide = @import("hiide");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const cfg = hiide.runtime.config.AppConfig.default();
    var app = try hiide.runtime.app.App.init(allocator, cfg);
    defer app.deinit();

    const receipt = try app.bootstrapPlanningTask("Initialize workspace orchestration runtime");
    const stdout = std.io.getStdOut().writer();
    try stdout.print("hiide engine bootstrapped task={x}\n", .{receipt.task_id});
}
