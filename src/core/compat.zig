/// Compatibility shims for small APIs that the engine keeps Linux-native.
///
/// Zig 0.17 moved all I/O and synchronization behind the `std.Io` vtable.
/// The agent framework uses simple in-process mutexes, timestamps, and
/// process spawning that don't need the full Io infrastructure. This module
/// provides minimal replacements backed by Linux syscalls or atomics.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// ── TCP networking (std.net was removed in Zig 0.17) ────────────────────────
//
// Zig 0.17 removed the synchronous `std.net.Server` / `std.net.Stream` /
// `std.net.Address` types in favour of the async `std.Io.net` API.
// The IPC server is a simple synchronous thread-per-connection server that
// does NOT need async I/O, so we reimplement the three types used by the
// codebase on top of raw POSIX syscalls.

pub const TcpStream = struct {
    fd: i32,

    pub fn close(self: TcpStream) void {
        _ = linux.close(self.fd);
    }

    pub fn read(self: TcpStream, buf: []u8) !usize {
        const n = linux.read(self.fd, buf.ptr, buf.len);
        if (n == 0) return 0;
        if (n > buf.len) return error.ReadFailed;
        return n;
    }

    pub fn writeAll(self: TcpStream, buf: []const u8) !void {
        var remaining = buf;
        while (remaining.len > 0) {
            const n = linux.write(self.fd, remaining.ptr, remaining.len);
            if (n == 0 or n > remaining.len) return error.WriteFailed;
            remaining = remaining[n..];
        }
    }
};

pub const TcpConnection = struct {
    stream: TcpStream,
    addr_len: u32 = 0,

    pub fn peerStr(self: *const TcpConnection, buf: []u8) []const u8 {
        _ = self;
        return std.fmt.bufPrint(buf, "<client>", .{}) catch "<client>";
    }
};

pub const TcpServer = struct {
    fd: i32,
    port: u16,

    /// Creates, binds and listens on `127.0.0.1:port`.
    pub fn init(port: u16) !TcpServer {
        const fd = @as(i32, @intCast(linux.socket(
            linux.AF.INET,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
            0,
        )));
        if (fd < 0) return error.SocketFailed;
        errdefer _ = linux.close(fd);

        // SO_REUSEADDR
        const one: i32 = 1;
        _ = linux.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            @ptrCast(&one),
            @sizeOf(i32),
        );

        const addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = @byteSwap(port),
            .addr = @byteSwap(@as(u32, 0x7f000001)), // 127.0.0.1
            .zero = .{0, 0, 0, 0, 0, 0, 0, 0},
        };
        const rc_bind = linux.bind(
            fd,
            @ptrCast(&addr),
            @sizeOf(linux.sockaddr.in),
        );
        if (rc_bind != 0) return error.BindFailed;

        const rc_listen = linux.listen(fd, 128);
        if (rc_listen != 0) return error.ListenFailed;

        return .{ .fd = fd, .port = port };
    }

    pub fn deinit(self: *TcpServer) void {
        _ = linux.close(self.fd);
    }

    pub fn accept(self: *TcpServer) !TcpConnection {
        var peer_addr: linux.sockaddr.in = undefined;
        var peer_len: u32 = @sizeOf(linux.sockaddr.in);
        const client_fd = @as(i32, @intCast(linux.accept4(
            self.fd,
            @ptrCast(&peer_addr),
            &peer_len,
            linux.SOCK.CLOEXEC,
        )));
        if (client_fd < 0) return error.AcceptFailed;
        return TcpConnection{ .stream = .{ .fd = client_fd } };
    }
};

// ── Mutex (atomic spinlock) ──────────────────────────────────────────────────

pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub const init: Mutex = .{};

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

pub const Condition = struct {
    seq: std.atomic.Value(u32) = .init(0),

    pub const init: Condition = .{};

    /// Releases mutex, waits for a broadcast/signal, then re-acquires mutex.
    /// Uses a spin-sleep loop for simplicity.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) void {
        const start = milliTimestamp();
        const timeout_ms = timeout_ns / std.time.ns_per_ms;
        const seq = self.seq.load(.acquire);
        mutex.unlock();
        while (self.seq.load(.acquire) == seq) {
            sleep(1);
            if (milliTimestamp() - start >= @as(i64, @intCast(timeout_ms))) break;
        }
        mutex.lock();
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.seq.fetchAdd(1, .release);
    }

    pub fn signal(self: *Condition) void {
        _ = self.seq.fetchAdd(1, .release);
    }
};

pub fn ManagedArrayList(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
        allocator_: std.mem.Allocator,

        pub const empty: @This() = .{ .items = &.{}, .capacity = 0, .allocator_ = undefined };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .items = &.{}, .capacity = 0, .allocator_ = allocator };
        }

        pub fn deinit(self: *@This()) void {
            if (self.capacity > 0) {
                self.allocator_.free(self.items.ptr[0..self.capacity]);
            }
            self.* = undefined;
        }

        pub fn append(self: *@This(), item: T) !void {
            if (self.items.len == self.capacity) {
                const new_cap = if (self.capacity == 0) 8 else self.capacity * 2;
                const new_buf = try self.allocator_.alloc(T, new_cap);
                if (self.capacity > 0) {
                    @memcpy(new_buf[0..self.items.len], self.items);
                    self.allocator_.free(self.items.ptr[0..self.capacity]);
                }
                self.items = new_buf[0..self.items.len];
                self.capacity = new_cap;
            }
            self.items = self.items.ptr[0 .. self.items.len + 1];
            self.items[self.items.len - 1] = item;
        }

        pub fn appendSlice(self: *@This(), slice: []const T) !void {
            for (slice) |item| try self.append(item);
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.items = self.items.ptr[0..0];
        }

        pub fn pop(self: *@This()) T {
            std.debug.assert(self.items.len > 0);
            const index = self.items.len - 1;
            const value = self.items[index];
            self.items = self.items.ptr[0..index];
            return value;
        }

        pub fn toOwnedSlice(self: *@This()) ![]T {
            const result = try self.allocator_.alloc(T, self.items.len);
            @memcpy(result, self.items);
            self.deinit();
            return result;
        }

        pub fn shrinkRetainingCapacity(self: *@This(), new_len: usize) void {
            std.debug.assert(new_len <= self.items.len);
            self.items = self.items.ptr[0..new_len];
        }

        pub fn writer(self: *@This()) Writer {
            return .{ .context = self };
        }

        pub const Writer = struct {
            context: *@This(),

            pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
                try self.context.appendSlice(bytes);
            }

            pub fn writeByte(self: *@This(), byte: u8) anyerror!void {
                try self.context.append(byte);
            }

            pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) anyerror!void {
                var tmp = std.Io.Writer.Allocating.init(self.context.allocator_);
                defer tmp.deinit();
                try tmp.writer.print(fmt, args);
                const slice = try tmp.toOwnedSlice();
                defer self.context.allocator_.free(slice);
                try self.context.appendSlice(slice);
            }
        };
    };
}

pub fn jsonStringifyAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
    options: std.json.Stringify.Options,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(value, options)});
    return out.toOwnedSlice();
}

pub fn nanoTimestamp() i64 {
    if (builtin.os.tag == .linux) {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        if (rc != 0) return 0;
        return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
    }
    return 0;
}

pub fn milliTimestamp() i64 {
    if (builtin.os.tag == .linux) {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }
    return 0;
}

pub fn sleep(ms: u64) void {
    if (builtin.os.tag == .linux) {
        const ns = ms * std.time.ns_per_ms;
        const req = linux.timespec{
            .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        };
        var rem: linux.timespec = undefined;
        const rc = linux.nanosleep(&req, &rem);
        _ = rc;
    }
}

pub fn getEnvAlloc(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (builtin.os.tag != .linux) return null;
    const fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var buf: [32768]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        if (n == 0 or n > buf.len - total) break;
        total += n;
    }

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
        _ = linux.setpgid(0, 0);
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stderr_pipe[0]);
        _ = linux.close(stderr_pipe[1]);
        _ = linux.dup2(stdout_pipe[1], 1);
        // Merge stderr into stdout so a child cannot deadlock on two full pipes.
        _ = linux.dup2(stdout_pipe[1], 2);
        _ = linux.close(stdout_pipe[1]);

        var args_buf: [64][]const u8 = undefined;
        const argc = argv.len;
        for (argv[0..argc], 0..) |arg, i| args_buf[i] = arg;

        var arg_zs: [64][:0]const u8 = undefined;
        for (args_buf[0..argc], 0..) |arg, i| {
            arg_zs[i] = try std.heap.page_allocator.dupeSentinel(u8, arg, 0);
        }

        var ptrs: [65:null]?[*:0]const u8 = undefined;
        for (arg_zs[0..argc], 0..) |arg, i| ptrs[i] = arg.ptr;
        ptrs[argc] = null;

        const default_path = "/usr/bin:/bin";
        const path_env = getEnvAlloc(std.heap.page_allocator, "PATH") orelse default_path;
        defer if (path_env.ptr != default_path.ptr) std.heap.page_allocator.free(path_env);
        var path_iter = std.mem.splitScalar(u8, path_env, ':');
        while (path_iter.next()) |dir| {
            const full_path = std.fs.path.join(std.heap.page_allocator, &.{ dir, argv[0] }) catch continue;
            defer std.heap.page_allocator.free(full_path);
            const path_z = std.heap.page_allocator.dupeSentinel(u8, full_path, 0) catch continue;

            var env_buf: [32768]u8 = undefined;
            const env_fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
            var env_total: usize = 0;
            if (env_fd >= 0) {
                defer _ = linux.close(@intCast(env_fd));
                while (env_total < env_buf.len) {
                    const n = linux.read(@intCast(env_fd), env_buf[env_total..].ptr, env_buf.len - env_total);
                    if (n <= 0 or n > env_buf.len - env_total) break;
                    env_total += n;
                }
            }

            var env_ptrs: [256:null]?[*:0]const u8 = undefined;
            var env_count: usize = 0;
            var pos: usize = 0;
            while (pos < env_total and env_count < env_ptrs.len - 1) {
                const end = std.mem.indexOfScalarPos(u8, env_buf[0..env_total], pos, 0) orelse env_total;
                if (end > pos) {
                    env_ptrs[env_count] = @ptrCast(&env_buf[pos]);
                    env_count += 1;
                }
                pos = @min(end + 1, env_total);
            }
            env_ptrs[env_count] = null;

            _ = linux.execve(path_z.ptr, &ptrs, &env_ptrs);
            std.heap.page_allocator.free(path_z);
        }

        linux.exit(127);
    }

    _ = linux.setpgid(@intCast(pid_result), @intCast(pid_result));
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
                    _ = linux.kill(-self.pid, 9);
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
            _ = linux.kill(-pid, 9);
            var dummy: u32 = 0;
            _ = linux.waitpid(pid, &dummy, 0);
            _ = linux.close(stdout_pipe[0]);
            return error.WatchdogSpawnFailed;
        };
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(stdout_pipe[0], &buf, buf.len);
        if (n == 0 or n > buf.len) break;
        if (stdout_list.items.len < max_output_bytes) {
            const remaining = max_output_bytes - stdout_list.items.len;
            stdout_list.appendSlice(allocator, buf[0..@min(n, remaining)]) catch break;
        }
    }
    _ = linux.close(stdout_pipe[0]);

    done.store(true, .release);

    var status_raw: u32 = 0;
    _ = linux.waitpid(@intCast(pid_result), &status_raw, 0);

    if (watchdog_thread) |*thread| thread.join();

    const status: u32 = status_raw;
    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .success = !timed_out.load(.acquire) and linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0,
        .timed_out = timed_out.load(.acquire),
    };
}
