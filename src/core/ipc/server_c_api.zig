const std = @import("std");
const ipc = @import("server.zig");

pub const ServerHandle = *ipc.IpcServer;

pub export fn hiide_ipc_start(port: u16) callconv(.C) ?ServerHandle {
    const allocator = std.heap.c_allocator;
    const server = allocator.create(ipc.IpcServer) catch return null;
    server.* = ipc.IpcServer.init(allocator, port) catch {
        allocator.destroy(server);
        return null;
    };
    const thread = std.Thread.spawn(.{}, ipc.IpcServer.run, .{server}) catch {
        server.deinit();
        allocator.destroy(server);
        return null;
    };
    thread.detach();
    return server;
}

pub export fn hiide_ipc_stop(handle: ?ServerHandle) callconv(.C) void {
    if (handle) |server| {
        server.deinit();
        std.heap.c_allocator.destroy(server);
    }
}
