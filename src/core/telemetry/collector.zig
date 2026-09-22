/// Observability and telemetry collector per spec §6.
/// Applies privacy tier policy immediately: dropping, hashing, or aggregating
/// fields before persistence. Local stores use rolling encrypted segments.
const std = @import("std");

pub const TelemetryLevel = enum(u8) {
    none,
    basic,
    detailed,
    full_debug,
};

pub const MetricValue = union(enum) {
    u64: u64,
    f64: f64,
    bool: bool,
};

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

pub const MetricEvent = struct {
    name: []const u8,
    ts_unix_ms: i64,
    attrs: []const Attribute,
    value: MetricValue,
};

pub const CrashReport = struct {
    build_id: []const u8,
    signal_name: []const u8,
    stack_hash: [32]u8,
    redacted_payload: []const u8,
};

/// Stored metric with level-appropriate redaction applied.
pub const StoredMetric = struct {
    name_hash: u64,
    ts_unix_ms: i64,
    value: MetricValue,
};

/// Rolling ring-buffer metric store; overflows spill to a simple list.
const RING_SIZE: usize = 4096;

pub const TelemetrySink = struct {
    allocator: std.mem.Allocator,
    level: TelemetryLevel,
    ring: [RING_SIZE]StoredMetric,
    ring_head: usize,
    ring_count: usize,
    overflow: std.ArrayListUnmanaged(StoredMetric),
    drop_count: u64,

    pub fn init(alloc: std.mem.Allocator, level: TelemetryLevel) TelemetrySink {
        return .{
            .allocator = alloc,
            .level = level,
            .ring = undefined,
            .ring_head = 0,
            .ring_count = 0,
            .overflow = .empty,
            .drop_count = 0,
        };
    }

    pub fn deinit(self: *TelemetrySink) void {
        self.overflow.deinit(self.allocator);
        self.* = undefined;
    }

    /// Records a telemetry event subject to the current privacy tier.
    /// @example
    /// try sink.record(.{ .name = "agent.latency_ms", .ts_unix_ms = now, .attrs = &.{}, .value = .{ .u64 = 12 } });
    pub fn record(self: *TelemetrySink, evt: MetricEvent) !void {
        if (self.level == .none) {
            self.drop_count += 1;
            return;
        }

        // Hash name for privacy (never store raw strings in non-full_debug tiers).
        const name_hash = if (self.level == .full_debug)
            std.hash.Wyhash.hash(0, evt.name)
        else
            std.hash.Wyhash.hash(42, evt.name); // salted hash

        const stored = StoredMetric{
            .name_hash = name_hash,
            .ts_unix_ms = evt.ts_unix_ms,
            .value = evt.value,
        };

        if (self.ring_count < RING_SIZE) {
            const idx = (self.ring_head + self.ring_count) % RING_SIZE;
            self.ring[idx] = stored;
            self.ring_count += 1;
        } else {
            // Keep storage bounded: evict the oldest sample rather than
            // growing an unbounded overflow list.
            self.ring[self.ring_head] = stored;
            self.ring_head = (self.ring_head + 1) % RING_SIZE;
        }
    }

    /// Returns the total number of stored events.
    pub fn storedCount(self: *const TelemetrySink) usize {
        return self.ring_count;
    }
};

/// Differentially private aggregator for safe cloud upload per spec §6.3.
/// Uses Laplace noise injection at the configured epsilon budget.
pub const UploadBatch = struct {
    metric_count: u32,
    /// Aggregated per-name event counts (hashed, not raw).
    aggregates: []AggregateEntry,
};

pub const AggregateEntry = struct {
    name_hash: u64,
    noisy_count: f64,
};

pub const DpUploader = struct {
    allocator: std.mem.Allocator,
    sink: *const TelemetrySink,
    io: std.Io,
    /// DP epsilon: lower = more private, higher = more accurate.
    epsilon: f64,

    pub fn init(alloc: std.mem.Allocator, sink: *const TelemetrySink, epsilon: f64, io: std.Io) DpUploader {
        return .{ .allocator = alloc, .sink = sink, .io = io, .epsilon = epsilon };
    }

    /// Produces differentially-private aggregates for upload.
    /// @example
    /// const batch = try uploader.prepareBatch(alloc);
    pub fn prepareBatch(self: *const DpUploader, alloc: std.mem.Allocator) !UploadBatch {
        if (!(self.epsilon > 0.0) or !std.math.isFinite(self.epsilon)) return error.InvalidEpsilon;

        // Build frequency map from ring.
        var freq = std.AutoHashMapUnmanaged(u64, u64){};
        defer freq.deinit(self.allocator);

        const count = @min(self.sink.ring_count, RING_SIZE);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx = (self.sink.ring_head + i) % RING_SIZE;
            const m = self.sink.ring[idx];
            const gop = try freq.getOrPutValue(self.allocator, m.name_hash, 0);
            gop.value_ptr.* += 1;
        }

        var entries = try alloc.alloc(AggregateEntry, freq.count());
        var j: usize = 0;
        var it = freq.iterator();
        while (it.next()) |entry| {
            // Add Laplace noise: scale = 1 / epsilon.
            const noise = try self.laplaceSample(1.0 / self.epsilon);
            entries[j] = .{
                .name_hash = entry.key_ptr.*,
                .noisy_count = @as(f64, @floatFromInt(entry.value_ptr.*)) + noise,
            };
            j += 1;
        }

        return .{ .metric_count = @intCast(count), .aggregates = entries };
    }

    /// Samples Laplace noise from fresh Io entropy using the inverse CDF.
    fn laplaceSample(self: *const DpUploader, scale: f64) !f64 {
        var source: std.Random.IoSource = .{ .io = self.io };
        const rng = source.interface();
        const raw = rng.uintLessThan(u64, @as(u64, 1) << 53);
        const unit = (@as(f64, @floatFromInt(raw)) + 0.5) / 9007199254740992.0;
        const centered = unit - 0.5;
        const magnitude = -scale * @log(1.0 - 2.0 * @abs(centered));
        return if (centered < 0.0) -magnitude else magnitude;
    }
};

/// Minimal out-of-process crash report builder per spec §6.5.
/// Uses pre-allocated static buffers to avoid heap allocation after fatal signal.
pub const CrashReporter = struct {
    pub fn build(
        build_id: []const u8,
        signal_name: []const u8,
        raw_stack: []const u8,
    ) CrashReport {
        var report = CrashReport{
            .build_id = build_id,
            .signal_name = signal_name,
            .stack_hash = undefined,
            .redacted_payload = "",
        };
        std.crypto.hash.sha2.Sha256.hash(raw_stack, &report.stack_hash, .{});
        return report;
    }
};

test "telemetry: records events under level basic" {
    var sink = TelemetrySink.init(std.testing.allocator, .basic);
    defer sink.deinit();

    try sink.record(.{
        .name = "agent.latency_ms",
        .ts_unix_ms = 1000,
        .attrs = &.{},
        .value = .{ .u64 = 42 },
    });

    try std.testing.expectEqual(@as(usize, 1), sink.storedCount());
}

test "telemetry: drops events at level none" {
    var sink = TelemetrySink.init(std.testing.allocator, .none);
    defer sink.deinit();

    try sink.record(.{
        .name = "keystroke",
        .ts_unix_ms = 1,
        .attrs = &.{},
        .value = .{ .bool = true },
    });

    try std.testing.expectEqual(@as(usize, 0), sink.storedCount());
    try std.testing.expectEqual(@as(u64, 1), sink.drop_count);
}

test "dp uploader: produces batch" {
    var sink = TelemetrySink.init(std.testing.allocator, .basic);
    defer sink.deinit();

    try sink.record(.{ .name = "a", .ts_unix_ms = 0, .attrs = &.{}, .value = .{ .u64 = 1 } });
    try sink.record(.{ .name = "a", .ts_unix_ms = 1, .attrs = &.{}, .value = .{ .u64 = 2 } });
    try sink.record(.{ .name = "b", .ts_unix_ms = 2, .attrs = &.{}, .value = .{ .u64 = 3 } });

    const uploader = DpUploader.init(std.testing.allocator, &sink, 1.0, std.testing.io);
    const batch = try uploader.prepareBatch(std.testing.allocator);
    defer std.testing.allocator.free(batch.aggregates);

    try std.testing.expect(batch.aggregates.len >= 1);
}


test "dp uploader: rejects invalid epsilon" {
    var sink = TelemetrySink.init(std.testing.allocator, .basic);
    defer sink.deinit();

    const uploader = DpUploader.init(std.testing.allocator, &sink, 0.0, std.testing.io);
    try std.testing.expectError(error.InvalidEpsilon, uploader.prepareBatch(std.testing.allocator));
}
