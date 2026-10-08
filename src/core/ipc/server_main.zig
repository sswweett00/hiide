const std = @import("std");
const ipc = @import("mod.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const port: u16 = 4879;
    const auth_token = init.minimal.environ.getPosix("HIIDE_IPC_TOKEN");

    std.debug.print("Hiide IPC Server starting on 127.0.0.1:{}\n", .{port});
    var server = ipc.server.IpcServer.init(allocator, port, auth_token) catch |err| {
        std.debug.print("Failed to start IPC server: {}\n", .{err});
        return err;
    };
    defer server.deinit();

    std.debug.print("IPC Server running. Press Ctrl+C to stop.\n", .{});
    try server.run();
}
