/// Hierarchical token and spend accounting.
///
/// Spec §1.5 requires that budget exhaustion mid-pipeline downgrades the model,
/// compresses context, or truncates low-priority branches instead of hard
/// failing. The meter therefore reports a graded verdict rather than a boolean:
/// `ok` → `downgrade` (soft limit) → `exhausted` (hard limit).
const std = @import("std");
const types = @import("../types.zig");

pub const BudgetError = error{
    BudgetExhausted,
    SpendLimitExceeded,
};

pub const Verdict = enum(u8) {
    /// Within the soft limit; continue on the primary model.
    ok,
    /// Soft limit crossed; switch to `downgrade_model_id` and compress context.
    downgrade,
    /// Hard limit crossed; the branch must stop.
    exhausted,
};

pub const Charge = struct {
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    microunits: u64 = 0,

    pub fn total(self: Charge) u64 {
        return @as(u64, self.tokens_in) + @as(u64, self.tokens_out);
    }
};

pub const Snapshot = struct {
    tokens_in: u64,
    tokens_out: u64,
    spend_microunits: u64,
    soft_limit: u32,
    hard_limit: u32,
    verdict: Verdict,

    pub fn totalTokens(self: Snapshot) u64 {
        return self.tokens_in + self.tokens_out;
    }

    /// Fraction of the hard limit consumed, in the range 0.0–1.0+.
    /// @example
    /// const pct = snapshot.utilization();
    pub fn utilization(self: Snapshot) f32 {
        if (self.hard_limit == 0) return 0.0;
        return @as(f32, @floatFromInt(self.totalTokens())) / @as(f32, @floatFromInt(self.hard_limit));
    }
};

/// Thread-safe budget meter. Child meters roll their charges up to the parent so
/// a fan-out of speculative branches cannot exceed the plan-level ceiling.
pub const Meter = struct {
    limits: types.TokenBudget,
    tokens_in: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tokens_out: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    spend: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parent: ?*Meter = null,

    /// Creates a root meter for a plan or session.
    /// @example
    /// var meter = Meter.init(types.TokenBudget.defaultPlanning());
    pub fn init(limits: types.TokenBudget) Meter {
        return .{ .limits = limits };
    }

    /// Creates a child meter that also charges `parent`.
    /// @example
    /// var task_meter = Meter.child(&plan_meter, task.budget);
    pub fn child(parent: *Meter, limits: types.TokenBudget) Meter {
        return .{ .limits = limits, .parent = parent };
    }

    /// Applies a charge and returns the strictest verdict across the chain.
    /// The charge is always recorded, even when it crosses the hard limit, so
    /// audit trails reflect true consumption.
    /// @example
    /// const verdict = try meter.charge(.{ .tokens_in = 1200, .tokens_out = 350 });
    pub fn charge(self: *Meter, c: Charge) BudgetError!Verdict {
        _ = self.tokens_in.fetchAdd(c.tokens_in, .acq_rel);
        _ = self.tokens_out.fetchAdd(c.tokens_out, .acq_rel);
        const new_spend = self.spend.fetchAdd(c.microunits, .acq_rel) + c.microunits;

        var verdict = self.localVerdict();

        if (self.limits.spend_limit_microunits > 0 and new_spend > self.limits.spend_limit_microunits) {
            if (self.parent) |p| _ = p.charge(c) catch {};
            return BudgetError.SpendLimitExceeded;
        }

        if (self.parent) |p| {
            const parent_verdict = p.charge(c) catch |err| return err;
            if (@intFromEnum(parent_verdict) > @intFromEnum(verdict)) verdict = parent_verdict;
        }

        if (verdict == .exhausted) return BudgetError.BudgetExhausted;
        return verdict;
    }

    /// Non-mutating check used before issuing a provider call.
    /// @example
    /// if (meter.wouldExceed(estimate)) try downgrade();
    pub fn wouldExceed(self: *const Meter, c: Charge) bool {
        const projected = self.totalTokens() + c.total();
        if (self.limits.hard_limit > 0 and projected > self.limits.hard_limit) return true;
        if (self.parent) |p| return p.wouldExceed(c);
        return false;
    }

    /// Current verdict without applying a charge.
    /// @example
    /// const v = meter.currentVerdict();
    pub fn currentVerdict(self: *const Meter) Verdict {
        var verdict = self.localVerdict();
        if (self.parent) |p| {
            const pv = p.currentVerdict();
            if (@intFromEnum(pv) > @intFromEnum(verdict)) verdict = pv;
        }
        return verdict;
    }

    fn localVerdict(self: *const Meter) Verdict {
        const total = self.totalTokens();
        if (self.limits.hard_limit > 0 and total >= self.limits.hard_limit) return .exhausted;
        if (self.limits.soft_limit > 0 and total >= self.limits.soft_limit) return .downgrade;
        return .ok;
    }

    /// Total tokens consumed at this level.
    pub fn totalTokens(self: *const Meter) u64 {
        return self.tokens_in.load(.acquire) + self.tokens_out.load(.acquire);
    }

    /// Tokens left before the hard limit; 0 when exhausted or unlimited.
    /// @example
    /// const left = meter.remainingTokens();
    pub fn remainingTokens(self: *const Meter) u64 {
        if (self.limits.hard_limit == 0) return std.math.maxInt(u64);
        const total = self.totalTokens();
        if (total >= self.limits.hard_limit) return 0;
        return self.limits.hard_limit - total;
    }

    /// Model id to use given the current verdict.
    /// @example
    /// const model = meter.effectiveModel("gpt-4o");
    pub fn effectiveModel(self: *const Meter, preferred_model_id: []const u8) []const u8 {
        return switch (self.currentVerdict()) {
            .ok => preferred_model_id,
            .downgrade, .exhausted => self.limits.downgrade_model_id,
        };
    }

    /// Immutable view for telemetry and UI surfaces.
    /// @example
    /// const snap = meter.snapshot();
    pub fn snapshot(self: *const Meter) Snapshot {
        return .{
            .tokens_in = self.tokens_in.load(.acquire),
            .tokens_out = self.tokens_out.load(.acquire),
            .spend_microunits = self.spend.load(.acquire),
            .soft_limit = self.limits.soft_limit,
            .hard_limit = self.limits.hard_limit,
            .verdict = self.currentVerdict(),
        };
    }

    /// Clears local counters (used when replaying a task after rollback).
    /// @example
    /// meter.reset();
    pub fn reset(self: *Meter) void {
        self.tokens_in.store(0, .release);
        self.tokens_out.store(0, .release);
        self.spend.store(0, .release);
    }
};

test "budget: soft limit triggers downgrade, hard limit exhausts" {
    var meter = Meter.init(.{
        .soft_limit = 100,
        .hard_limit = 200,
        .downgrade_model_id = "local-fallback",
        .spend_limit_microunits = 0,
    });

    try std.testing.expectEqual(Verdict.ok, try meter.charge(.{ .tokens_in = 50 }));
    try std.testing.expectEqual(Verdict.downgrade, try meter.charge(.{ .tokens_in = 60 }));
    try std.testing.expectEqualStrings("local-fallback", meter.effectiveModel("gpt-4o"));
    try std.testing.expectError(BudgetError.BudgetExhausted, meter.charge(.{ .tokens_out = 100 }));
}

test "budget: child charges roll up to the parent ceiling" {
    var plan = Meter.init(.{
        .soft_limit = 0,
        .hard_limit = 150,
        .downgrade_model_id = "cheap",
        .spend_limit_microunits = 0,
    });
    var a = Meter.child(&plan, .{ .soft_limit = 0, .hard_limit = 1_000, .downgrade_model_id = "cheap", .spend_limit_microunits = 0 });
    var b = Meter.child(&plan, .{ .soft_limit = 0, .hard_limit = 1_000, .downgrade_model_id = "cheap", .spend_limit_microunits = 0 });

    _ = try a.charge(.{ .tokens_in = 100 });
    // Branch b is under its own limit but the shared plan ceiling is hit.
    try std.testing.expectError(BudgetError.BudgetExhausted, b.charge(.{ .tokens_in = 100 }));
    try std.testing.expectEqual(@as(u64, 200), plan.totalTokens());
}

test "budget: spend limit is enforced independently of tokens" {
    var meter = Meter.init(.{
        .soft_limit = 0,
        .hard_limit = 0,
        .downgrade_model_id = "cheap",
        .spend_limit_microunits = 1_000,
    });
    _ = try meter.charge(.{ .microunits = 900 });
    try std.testing.expectError(BudgetError.SpendLimitExceeded, meter.charge(.{ .microunits = 200 }));
}

test "budget: projection and remaining tokens" {
    var meter = Meter.init(.{ .soft_limit = 80, .hard_limit = 100, .downgrade_model_id = "x", .spend_limit_microunits = 0 });
    _ = try meter.charge(.{ .tokens_in = 40 });

    try std.testing.expectEqual(@as(u64, 60), meter.remainingTokens());
    try std.testing.expect(!meter.wouldExceed(.{ .tokens_in = 50 }));
    try std.testing.expect(meter.wouldExceed(.{ .tokens_in = 70 }));

    const snap = meter.snapshot();
    try std.testing.expectEqual(@as(u64, 40), snap.totalTokens());
    try std.testing.expect(snap.utilization() > 0.39 and snap.utilization() < 0.41);
}

test "budget: concurrent charges are accounted exactly" {
    var meter = Meter.init(.{ .soft_limit = 0, .hard_limit = 0, .downgrade_model_id = "x", .spend_limit_microunits = 0 });

    const Worker = struct {
        fn run(m: *Meter) void {
            var i: usize = 0;
            while (i < 1_000) : (i += 1) {
                _ = m.charge(.{ .tokens_in = 1, .tokens_out = 1 }) catch {};
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&meter});
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(u64, 8_000), meter.totalTokens());
}
