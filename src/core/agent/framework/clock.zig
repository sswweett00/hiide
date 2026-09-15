/// Injectable clock abstraction.
/// Deadlines, backoff, approval timeouts, and telemetry timestamps all read
/// time through this interface so that deterministic tests (spec §1.6) can
/// drive execution without wall-clock sleeps.
const std = @import("std");
const compat = @import("../../compat.zig");

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_ms: *const fn (*anyopaque) i64,
        sleep_ms: *const fn (*anyopaque, u64) void,
    };

    /// Current wall-clock-equivalent time in unix milliseconds.
    /// @example
    /// const now = clock.nowMs();
    pub fn nowMs(self: Clock) i64 {
        return self.vtable.now_ms(self.ptr);
    }

    /// Blocks (or virtually advances) for `ms` milliseconds.
    /// @example
    /// clock.sleepMs(25);
    pub fn sleepMs(self: Clock, ms: u64) void {
        self.vtable.sleep_ms(self.ptr, ms);
    }

    /// Returns true when `deadline_ms` is in the past.
    /// @example
    /// if (clock.isExpired(deadline)) return error.DeadlineExceeded;
    pub fn isExpired(self: Clock, deadline_ms: ?i64) bool {
        const deadline = deadline_ms orelse return false;
        return self.nowMs() >= deadline;
    }

    /// Computes an absolute deadline `ms` in the future, saturating on overflow.
    /// @example
    /// const deadline = clock.deadlineIn(5_000);
    pub fn deadlineIn(self: Clock, ms: u64) i64 {
        const now = self.nowMs();
        const delta: i64 = @intCast(@min(ms, @as(u64, std.math.maxInt(i64) / 2)));
        return now +| delta;
    }
};

/// Monotonic-backed system clock used in production builds.
pub const SystemClock = struct {
    dummy: u8 = 0,

    fn nowMs(_: *anyopaque) i64 {
        return compat.milliTimestamp();
    }

    fn sleepMs(_: *anyopaque, ms: u64) void {
        compat.sleep(ms * std.time.ns_per_ms);
    }

    const vtable = Clock.VTable{
        .now_ms = nowMs,
        .sleep_ms = sleepMs,
    };

    /// Returns the erased Clock interface for this instance.
    /// @example
    /// var sys = SystemClock{};
    /// const c = sys.clock();
    pub fn clock(self: *SystemClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

var system_instance: SystemClock = .{};

/// Returns the process-wide system clock.
/// @example
/// const c = system();
pub fn system() Clock {
    return system_instance.clock();
}

/// Deterministic clock for tests and replay harnesses.
/// `sleepMs` advances virtual time instead of blocking a thread.
pub const ManualClock = struct {
    now: std.atomic.Value(i64),

    /// Creates a manual clock anchored at `start_ms`.
    /// @example
    /// var mc = ManualClock.init(0);
    pub fn init(start_ms: i64) ManualClock {
        return .{ .now = std.atomic.Value(i64).init(start_ms) };
    }

    fn nowMs(ptr: *anyopaque) i64 {
        const self: *ManualClock = @ptrCast(@alignCast(ptr));
        return self.now.load(.acquire);
    }

    fn sleepMs(ptr: *anyopaque, ms: u64) void {
        const self: *ManualClock = @ptrCast(@alignCast(ptr));
        _ = self.now.fetchAdd(@intCast(ms), .acq_rel);
    }

    const vtable = Clock.VTable{
        .now_ms = nowMs,
        .sleep_ms = sleepMs,
    };

    /// Advances virtual time by `ms` milliseconds.
    /// @example
    /// mc.advance(1_000);
    pub fn advance(self: *ManualClock, ms: u64) void {
        _ = self.now.fetchAdd(@intCast(ms), .acq_rel);
    }

    /// Returns the erased Clock interface for this instance.
    /// @example
    /// const c = mc.clock();
    pub fn clock(self: *ManualClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Scoped latency measurement emitted into telemetry by callers.
pub const Stopwatch = struct {
    clock: Clock,
    start_ms: i64,

    /// Starts a stopwatch on the given clock.
    /// @example
    /// var sw = Stopwatch.start(clock);
    pub fn start(c: Clock) Stopwatch {
        return .{ .clock = c, .start_ms = c.nowMs() };
    }

    /// Elapsed milliseconds since `start`, clamped at zero.
    /// @example
    /// const ms = sw.elapsedMs();
    pub fn elapsedMs(self: Stopwatch) u32 {
        const delta = self.clock.nowMs() - self.start_ms;
        if (delta <= 0) return 0;
        return @intCast(@min(delta, std.math.maxInt(u32)));
    }
};

test "clock: manual clock advances deterministically" {
    var mc = ManualClock.init(1_000);
    const c = mc.clock();

    try std.testing.expectEqual(@as(i64, 1_000), c.nowMs());
    c.sleepMs(500);
    try std.testing.expectEqual(@as(i64, 1_500), c.nowMs());
    mc.advance(250);
    try std.testing.expectEqual(@as(i64, 1_750), c.nowMs());
}

test "clock: deadline helpers" {
    var mc = ManualClock.init(0);
    const c = mc.clock();

    const deadline = c.deadlineIn(100);
    try std.testing.expect(!c.isExpired(deadline));
    mc.advance(150);
    try std.testing.expect(c.isExpired(deadline));
    try std.testing.expect(!c.isExpired(null));
}

test "clock: stopwatch measures virtual elapsed time" {
    var mc = ManualClock.init(0);
    const c = mc.clock();

    const sw = Stopwatch.start(c);
    mc.advance(42);
    try std.testing.expectEqual(@as(u32, 42), sw.elapsedMs());
}

test "clock: system clock is monotonic enough for spans" {
    const c = system();
    const a = c.nowMs();
    const b = c.nowMs();
    try std.testing.expect(b >= a);
}
