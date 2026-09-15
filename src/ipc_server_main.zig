// Thin entry adapter for the `hiide-ipc-server` executable.
//
// The build targets this file (instead of `src/core/ipc/server_main.zig`)
// so the root module's directory is `src/`, which keeps relative imports
// used by the ipc module (e.g. `../editor/c_api.zig` in server.zig) inside
// the module path. The canonical main lives in `core/ipc/server_main.zig`.
const std = @import("std");
const server_main = @import("core/ipc/server_main.zig");

pub fn main() !void {
    try server_main.main();
}
