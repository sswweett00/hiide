/// Cross-platform benchmark runner and regression gate per spec §8.
/// Captures p50/p95/p99 latency, peak memory, and CI-gated regression detection.
const std = @import("std");
const compat = @import("../compat.zig");
const linux = std.os.linux;
const builtin = @import("builtin");

pub const BenchmarkKind = enum(u8) {
    cold_start,
    keystroke_latency,
    ai_first_token,
    memory_idle,
    memory_loaded,
    index_query,
    battery_drain,
};

pub const BenchmarkResult = struct {
    kind: BenchmarkKind,
    platform: []const u8,
    p50: f64,
    p95: f64,
    p99: f64,
    peak_memory_bytes: u64,
    build_id: []const u8,
};

pub const BaselineEntry = struct {
    kind: BenchmarkKind,
    platform: []const u8,
    /// Maximum allowed p99 value. 0 means unconstrained.
    max_p99: f64,
    /// Maximum allowed peak memory in bytes. 0 means unconstrained.
    max_memory_bytes: u64,
};

pub const BaselineSet = struct {
    entries: []const BaselineEntry,
};

pub const RegressionViolation = struct {
    kind: BenchmarkKind,
    field: []const u8,
    measured: f64,
    limit: f64,
};

pub const RegressionError = error{
    RegressionDetected,
    OutOfMemory,
};

/// Monotonic timer wrapper for pinned-core benchmark measurements.
pub const Timer = struct {
    start_ns: i64,

    pub fn start() Timer {
        return .{ .start_ns = compat.nanoTimestamp() };
    }

    pub fn elapsedNs(self: Timer) u64 {
        const now = compat.nanoTimestamp();
        if (now <= self.start_ns) return 0;
        return @intCast(now - self.start_ns);
    }

    pub fn elapsedMs(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / 1_000_000.0;
    }

    pub fn elapsedUs(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNs())) / 1_000.0;
    }
};

/// Computes p50/p95/p99 from a sorted sample slice (in-place sort).
pub const Percentiles = struct {
    p50: f64,
    p95: f64,
    p99: f64,

    /// Sorts `samples` in-place and computes percentiles.
    /// @example
    /// const pct = Percentiles.compute(samples);
    pub fn compute(samples: []f64) Percentiles {
        if (samples.len == 0) return .{ .p50 = 0, .p95 = 0, .p99 = 0 };
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));
        return .{
            .p50 = percentileAt(samples, 50),
            .p95 = percentileAt(samples, 95),
            .p99 = percentileAt(samples, 99),
        };
    }

    fn percentileAt(sorted: []const f64, pct: u8) f64 {
        const n = sorted.len;
        if (n == 1) return sorted[0];
        const idx_f = @as(f64, @floatFromInt(pct)) / 100.0 * @as(f64, @floatFromInt(n - 1));
        const lo = @as(usize, @intFromFloat(idx_f));
        const hi = @min(lo + 1, n - 1);
        const frac = idx_f - @as(f64, @floatFromInt(lo));
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
    }
};

/// Benchmark runner that executes a benchmark function N times and produces a result.
/// @example
/// const result = try BenchmarkRunner.run(.keystroke_latency, "linux", "dev", 100, myFn, alloc);
pub const BenchmarkRunner = struct {
    pub fn run(
        kind: BenchmarkKind,
        platform: []const u8,
        build_id: []const u8,
        iterations: usize,
        comptime bench_fn: fn () anyerror!void,
        alloc: std.mem.Allocator,
    ) !BenchmarkResult {
        var samples = try alloc.alloc(f64, iterations);
        defer alloc.free(samples);

        var peak_mem: u64 = 0;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const t = Timer.start();
            try bench_fn();
            samples[i] = t.elapsedMs();
            // Simplified peak memory: use resident set size approximation.
            const rss = currentRss();
            if (rss > peak_mem) peak_mem = rss;
        }

        const pct = Percentiles.compute(samples);
        return BenchmarkResult{
            .kind = kind,
            .platform = platform,
            .p50 = pct.p50,
            .p95 = pct.p95,
            .p99 = pct.p99,
            .peak_memory_bytes = peak_mem,
            .build_id = build_id,
        };
    }

    fn currentRss() u64 {
        // On Linux, read /proc/self/statm for RSS pages.
        // Returns 0 on failure (non-Linux platforms or permission errors).
        if (builtin.os.tag != .linux) return 0;

        const fd = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd) != .SUCCESS) return 0;
        defer _ = linux.close(@intCast(fd));

        var buf: [64]u8 = undefined;
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (n == 0 or n > buf.len) return 0;

        var it = std.mem.splitScalar(u8, buf[0..n], ' ');
        _ = it.next();
        const rss_str = it.next() orelse return 0;
        const pages = std.fmt.parseInt(u64, std.mem.trimRight(u8, rss_str, "\n\r "), 10) catch return 0;
        return pages * 4096;
    }
};

/// CI regression gate that fails when measured results exceed configured baselines.
/// @example
/// const violations = try RegressionGate.check(results, baseline, alloc);
/// if (violations.len > 0) return error.RegressionDetected;
pub const RegressionGate = struct {
    pub fn check(
        results: []const BenchmarkResult,
        baseline: BaselineSet,
        alloc: std.mem.Allocator,
    ) ![]RegressionViolation {
        var violations = std.ArrayListUnmanaged(RegressionViolation).empty;
        errdefer violations.deinit(alloc);

        for (results) |result| {
            for (baseline.entries) |entry| {
                if (entry.kind != result.kind) continue;
                if (!std.mem.eql(u8, entry.platform, result.platform)) continue;

                if (entry.max_p99 > 0 and result.p99 > entry.max_p99) {
                    try violations.append(alloc, .{
                        .kind = result.kind,
                        .field = "p99",
                        .measured = result.p99,
                        .limit = entry.max_p99,
                    });
                }
                if (entry.max_memory_bytes > 0 and result.peak_memory_bytes > entry.max_memory_bytes) {
                    try violations.append(alloc, .{
                        .kind = result.kind,
                        .field = "peak_memory_bytes",
                        .measured = @floatFromInt(result.peak_memory_bytes),
                        .limit = @floatFromInt(entry.max_memory_bytes),
                    });
                }
            }
        }

        return violations.toOwnedSlice(alloc);
    }
};

// ─── Spec-derived performance targets ────────────────────────────────────────
// These baselines are derived directly from §8.7.
pub const SPEC_BASELINES = BaselineSet{
    .entries = &[_]BaselineEntry{
        .{ .kind = .cold_start, .platform = "linux", .max_p99 = 500.0, .max_memory_bytes = 0 },
        .{ .kind = .keystroke_latency, .platform = "linux", .max_p99 = 8.0, .max_memory_bytes = 0 },
        .{ .kind = .ai_first_token, .platform = "linux", .max_p99 = 800.0, .max_memory_bytes = 0 },
        .{ .kind = .memory_idle, .platform = "linux", .max_p99 = 0.0, .max_memory_bytes = 500 * 1024 * 1024 },
        .{ .kind = .memory_loaded, .platform = "linux", .max_p99 = 0.0, .max_memory_bytes = 2 * 1024 * 1024 * 1024 },
        .{ .kind = .index_query, .platform = "linux", .max_p99 = 50.0, .max_memory_bytes = 0 },
    },
};

test "percentiles: basic computation" {
    var samples = [_]f64{ 10.0, 20.0, 30.0, 40.0, 50.0 };
    const pct = Percentiles.compute(&samples);
    try std.testing.expect(pct.p50 >= 25.0 and pct.p50 <= 35.0);
    try std.testing.expect(pct.p99 >= 45.0);
}

test "regression gate: passes within limits" {
    const results = [_]BenchmarkResult{.{
        .kind = .keystroke_latency,
        .platform = "linux",
        .p50 = 2.0,
        .p95 = 5.0,
        .p99 = 7.5, // under 8 ms limit
        .peak_memory_bytes = 0,
        .build_id = "abc",
    }};
    const violations = try RegressionGate.check(&results, SPEC_BASELINES, std.testing.allocator);
    defer std.testing.allocator.free(violations);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "regression gate: fails over p99 limit" {
    const results = [_]BenchmarkResult{.{
        .kind = .keystroke_latency,
        .platform = "linux",
        .p50 = 5.0,
        .p95 = 9.0,
        .p99 = 12.0, // OVER 8 ms limit
        .peak_memory_bytes = 0,
        .build_id = "bad",
    }};
    const violations = try RegressionGate.check(&results, SPEC_BASELINES, std.testing.allocator);
    defer std.testing.allocator.free(violations);
    try std.testing.expectEqual(@as(usize, 1), violations.len);
}
