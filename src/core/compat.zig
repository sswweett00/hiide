    var i: usize = 0;
    while (i < total) {
        const end = std.mem.indexOfScalarPos(u8, buf[0..total], i, 0) orelse break;
        const entry = buf[i..end];
        i = end + 1;
        if (std.mem.startsWith(u8, entry, name) and
            entry.len > name.len and
            entry[name.len] == '=')
        {
            return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn realpathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]u8 {
    if (builtin.os.tag == .linux) {
        var buf: [4096]u8 = undefined;
        const len = linux.getcwd(&buf, buf.len);
        if (len == 0) return error.NotFound;
        const cwd_path = buf[0..len];
        return std.fs.path.joinZ(allocator, &.{ cwd_path, rel_path });
    }
    return error.NotFound;
}

pub const ChildResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
    timed_out: bool = false,

    pub fn deinit(self: *ChildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !ChildResult {
    return runCommandWithTimeout(allocator, argv, 0);
}

/// Executes argv and optionally kills the child when timeout_ms elapses.
/// A zero timeout preserves the legacy unbounded behaviour.
pub fn runCommandWithTimeout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u32,
) !ChildResult {
    if (argv.len == 0) return error.InvalidArgument;
    if (argv.len > 64) return error.TooManyArguments;

    var stdout_pipe: [2]i32 = undefined;
    var stderr_pipe: [2]i32 = undefined;
    if (linux.pipe(&stdout_pipe) != 0) return error.PipeFailed;
    if (linux.pipe(&stderr_pipe) != 0) {
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stdout_pipe[1]);
        return error.PipeFailed;
    }

    const pid_result = linux.fork();
    if (pid_result > @as(usize, @intCast(std.math.maxInt(i32) - 1))) {
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stdout_pipe[1]);
        _ = linux.close(stderr_pipe[0]);
        _ = linux.close(stderr_pipe[1]);
        return error.ForkFailed;
    }

    if (pid_result == 0) {
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stderr_pipe[0]);
        _ = linux.close(stderr_pipe[1]);
        _ = linux.dup2(stdout_pipe[1], 1);
        // Merge stderr into stdout so a child cannot deadlock on two full pipes.
        _ = linux.dup2(stdout_pipe[1], 2);
        _ = linux.close(stdout_pipe[1]);

        var args_buf: [64][]const u8 = undefined;
        const argc = @min(argv.len, args_buf.len);
        for (argv[0..argc], 0..) |arg, i| {
            args_buf[i] = arg;
        }

        var arg_zs: [64][:0]const u8 = undefined;
        for (args_buf[0..argc], 0..) |arg, i| {
            arg_zs[i] = try std.heap.page_allocator.dupeSentinel(u8, arg, 0);
        }

        var ptrs: [65:null]?[*:0]const u8 = undefined;
        for (arg_zs[0..argc], 0..) |arg, i| {
            ptrs[i] = arg.ptr;
        }
        ptrs[argc] = null;

        const default_path = "/usr/bin:/bin";
        const path_env = getEnvAlloc(std.heap.page_allocator, "PATH") orelse default_path;
        defer if (path_env.ptr != default_path.ptr) std.heap.page_allocator.free(path_env);
        var path_iter = std.mem.splitScalar(u8, path_env, ':');
        while (path_iter.next()) |dir| {
            const full_path = std.fs.path.join(std.heap.page_allocator, &.{ dir, argv[0] }) catch continue;
            defer std.heap.page_allocator.free(full_path);
            const path_z = std.heap.page_allocator.dupeSentinel(u8, full_path, 0) catch continue;
            defer std.heap.page_allocator.free(path_z);

            const envp = [_:null]?[*:0]const u8{null};
            _ = linux.execve(path_z.ptr, &ptrs, &envp);
        }

        linux.exit(127);
    }

    _ = linux.close(stdout_pipe[1]);
    _ = linux.close(stderr_pipe[0]);
    _ = linux.close(stderr_pipe[1]);

    const max_output_bytes: usize = 4 * 1024 * 1024;
    var stdout_list = std.ArrayList(u8).initCapacity(allocator, 4096) catch {
        var dummy: u32 = 0;
        _ = linux.close(stdout_pipe[0]);
        _ = linux.waitpid(@intCast(pid_result), &dummy, 0);
        return error.OutOfMemory;
    };
    defer stdout_list.deinit(allocator);

    // The stderr pipe is intentionally merged into stdout in the child. Keep a
    // zero-length stderr buffer in the public result for API compatibility.
    var stderr_list = std.ArrayList(u8).initCapacity(allocator, 0) catch {
        var dummy: u32 = 0;
        _ = linux.close(stdout_pipe[0]);
        _ = linux.waitpid(@intCast(pid_result), &dummy, 0);
        return error.OutOfMemory;
    };
    defer stderr_list.deinit(allocator);

    const Watchdog = struct {
        done: *std.atomic.Value(bool),
        timed_out: *std.atomic.Value(bool),
        pid: i32,
        timeout_ms: u32,
        started_ms: i64,

        fn run(self: *@This()) void {
            while (!self.done.load(.acquire)) {
                const elapsed = milliTimestamp() - self.started_ms;
                if (elapsed >= @as(i64, @intCast(self.timeout_ms))) {
                    self.timed_out.store(true, .release);
                    _ = linux.kill(self.pid, 9);
                    return;
                }
                const remaining = @as(u64, @intCast(@max(@as(i64, 0), @as(i64, @intCast(self.timeout_ms)) - elapsed)));
                sleep(@min(remaining, 5));
            }
        }
    };

    var done = std.atomic.Value(bool).init(timeout_ms == 0);
    var timed_out = std.atomic.Value(bool).init(false);
    var watchdog_state: Watchdog = undefined;
    var watchdog_thread: ?std.Thread = null;

    if (timeout_ms > 0) {
        const pid: i32 = @intCast(pid_result);
        watchdog_state = .{
            .done = &done,
            .timed_out = &timed_out,
            .pid = pid,
            .timeout_ms = timeout_ms,
            .started_ms = milliTimestamp(),
        };
        watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog_state}) catch {
            _ = linux.kill(pid, 9);
            var dummy: u32 = 0;
            _ = linux.waitpid(pid, &dummy, 0);
            _ = linux.close(stdout_pipe[0]);
            return error.WatchdogSpawnFailed;