/// Consensus policies for `debate_consensus` execution mode.
///
/// Spec §1.5 requires divergent reviewer/coder outputs to either reach a
/// consensus or escalate to the approval gate. Replicas vote by output digest;
/// confidence-weighted policies break ties without a model round-trip.
const std = @import("std");
const agent_mod = @import("agent.zig");

pub const ConsensusError = error{
    InsufficientVoters,
    NoQuorum,
    DivergentOutputs,
    OutOfMemory,
};

pub const Policy = enum(u8) {
    /// Every replica must produce the same digest.
    unanimous,
    /// Strictly more than half must agree.
    majority,
    /// At least `quorum` replicas must agree.
    quorum,
    /// No agreement needed; the highest-confidence usable output wins.
    best_confidence,
    /// The first usable output wins (latency-optimised).
    first_usable,
};

pub const Outcome = enum(u8) {
    /// All voters agreed.
    unanimous,
    /// The winning answer met the policy threshold.
    threshold_met,
    /// A winner was selected without agreement (confidence policies).
    selected,
    /// No answer met the threshold.
    divergent,
};

pub const Config = struct {
    policy: Policy = .majority,
    /// Required agreeing voters for `.quorum`.
    quorum: u16 = 2,
    /// Outputs below this confidence never win.
    min_confidence: u8 = 0,
    /// Route divergence to the human approval gate instead of failing.
    escalate_on_divergence: bool = true,
};

pub const Result = struct {
    outcome: Outcome,
    /// Index into the input slice of the winning output.
    winner_index: usize,
    /// Number of voters that agreed with the winner.
    agreeing: u16,
    /// Total usable voters considered.
    voters: u16,
    /// Distinct digests observed.
    distinct: u16,
    /// True when the caller must open an approval gate before applying.
    requires_escalation: bool,

    /// Share of voters that agreed with the winner, 0.0–1.0.
    /// @example
    /// const ratio = result.agreementRatio();
    pub fn agreementRatio(self: Result) f32 {
        if (self.voters == 0) return 0.0;
        return @as(f32, @floatFromInt(self.agreeing)) / @as(f32, @floatFromInt(self.voters));
    }
};

/// Evaluates `outputs` under `cfg`.
/// Only outputs whose status `isUsable()` and whose confidence meets
/// `min_confidence` participate in the vote.
/// @example
/// const result = try evaluate(outputs, .{ .policy = .majority });
pub fn evaluate(outputs: []const agent_mod.AgentOutput, cfg: Config) ConsensusError!Result {
    if (outputs.len == 0) return ConsensusError.InsufficientVoters;

    // Collect eligible voters.
    var voters: u16 = 0;
    for (outputs) |o| {
        if (o.status.isUsable() and o.confidence >= cfg.min_confidence) voters += 1;
    }
    if (voters == 0) return ConsensusError.InsufficientVoters;

    // Tally votes per digest; the vote count is O(n²) which is fine because a
    // debate fan-out is bounded to single-digit replicas by the planner.
    var best_index: usize = 0;
    var best_votes: u16 = 0;
    var best_confidence: u32 = 0;
    var distinct: u16 = 0;

    for (outputs, 0..) |candidate, i| {
        if (!candidate.status.isUsable() or candidate.confidence < cfg.min_confidence) continue;

        // Count this digest only once (first occurrence defines the group).
        var first_occurrence = true;
        for (outputs[0..i]) |earlier| {
            if (!earlier.status.isUsable() or earlier.confidence < cfg.min_confidence) continue;
            if (earlier.agreesWith(candidate)) {
                first_occurrence = false;
                break;
            }
        }
        if (!first_occurrence) continue;
        distinct += 1;

        var votes: u16 = 0;
        var confidence_sum: u32 = 0;
        for (outputs) |other| {
            if (!other.status.isUsable() or other.confidence < cfg.min_confidence) continue;
            if (other.agreesWith(candidate)) {
                votes += 1;
                confidence_sum += other.confidence;
            }
        }

        const better = votes > best_votes or
            (votes == best_votes and confidence_sum > best_confidence);
        if (better) {
            best_votes = votes;
            best_confidence = confidence_sum;
            best_index = i;
        }
    }

    return switch (cfg.policy) {
        .unanimous => blk: {
            if (best_votes == voters) {
                break :blk Result{
                    .outcome = .unanimous,
                    .winner_index = best_index,
                    .agreeing = best_votes,
                    .voters = voters,
                    .distinct = distinct,
                    .requires_escalation = false,
                };
            }
            break :blk divergence(cfg, best_index, best_votes, voters, distinct);
        },
        .majority => blk: {
            if (@as(u32, best_votes) * 2 > @as(u32, voters)) {
                break :blk Result{
                    .outcome = if (best_votes == voters) .unanimous else .threshold_met,
                    .winner_index = best_index,
                    .agreeing = best_votes,
                    .voters = voters,
                    .distinct = distinct,
                    .requires_escalation = false,
                };
            }
            break :blk divergence(cfg, best_index, best_votes, voters, distinct);
        },
        .quorum => blk: {
            if (best_votes >= cfg.quorum) {
                break :blk Result{
                    .outcome = if (best_votes == voters) .unanimous else .threshold_met,
                    .winner_index = best_index,
                    .agreeing = best_votes,
                    .voters = voters,
                    .distinct = distinct,
                    .requires_escalation = false,
                };
            }
            break :blk divergence(cfg, best_index, best_votes, voters, distinct);
        },
        .best_confidence => blk: {
            var winner: usize = 0;
            var top: i32 = -1;
            for (outputs, 0..) |o, i| {
                if (!o.status.isUsable() or o.confidence < cfg.min_confidence) continue;
                if (@as(i32, o.confidence) > top) {
                    top = o.confidence;
                    winner = i;
                }
            }
            break :blk Result{
                .outcome = if (distinct == 1) .unanimous else .selected,
                .winner_index = winner,
                .agreeing = if (distinct == 1) voters else 1,
                .voters = voters,
                .distinct = distinct,
                .requires_escalation = false,
            };
        },
        .first_usable => blk: {
            var winner: usize = 0;
            for (outputs, 0..) |o, i| {
                if (o.status.isUsable() and o.confidence >= cfg.min_confidence) {
                    winner = i;
                    break;
                }
            }
            break :blk Result{
                .outcome = if (distinct == 1) .unanimous else .selected,
                .winner_index = winner,
                .agreeing = if (distinct == 1) voters else 1,
                .voters = voters,
                .distinct = distinct,
                .requires_escalation = false,
            };
        },
    };
}

fn divergence(cfg: Config, index: usize, votes: u16, voters: u16, distinct: u16) Result {
    return .{
        .outcome = .divergent,
        .winner_index = index,
        .agreeing = votes,
        .voters = voters,
        .distinct = distinct,
        .requires_escalation = cfg.escalate_on_divergence,
    };
}

/// Convenience wrapper that turns divergence into an error when escalation is
/// disabled, so callers can `try` in strict pipelines.
/// @example
/// const winner = try requireConsensus(outputs, .{ .policy = .unanimous, .escalate_on_divergence = false });
pub fn requireConsensus(
    outputs: []const agent_mod.AgentOutput,
    cfg: Config,
) ConsensusError!Result {
    const result = try evaluate(outputs, cfg);
    if (result.outcome == .divergent and !cfg.escalate_on_divergence) {
        return ConsensusError.DivergentOutputs;
    }
    return result;
}

test "consensus: unanimous agreement" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("patch A", 80),
        agent_mod.AgentOutput.fromSummary("patch A", 70),
        agent_mod.AgentOutput.fromSummary("patch A", 90),
    };

    const result = try evaluate(&outputs, .{ .policy = .unanimous });
    try std.testing.expectEqual(Outcome.unanimous, result.outcome);
    try std.testing.expectEqual(@as(u16, 3), result.agreeing);
    try std.testing.expectEqual(@as(u16, 1), result.distinct);
    try std.testing.expect(result.agreementRatio() > 0.99);
}

test "consensus: majority wins with a dissenter" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("patch A", 60),
        agent_mod.AgentOutput.fromSummary("patch B", 95),
        agent_mod.AgentOutput.fromSummary("patch A", 55),
    };

    const result = try evaluate(&outputs, .{ .policy = .majority });
    try std.testing.expectEqual(Outcome.threshold_met, result.outcome);
    try std.testing.expectEqual(@as(usize, 0), result.winner_index);
    try std.testing.expectEqual(@as(u16, 2), result.agreeing);
    try std.testing.expectEqual(@as(u16, 2), result.distinct);
    try std.testing.expect(!result.requires_escalation);
}

test "consensus: three-way split escalates" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("A", 50),
        agent_mod.AgentOutput.fromSummary("B", 50),
        agent_mod.AgentOutput.fromSummary("C", 50),
    };

    const result = try evaluate(&outputs, .{ .policy = .majority });
    try std.testing.expectEqual(Outcome.divergent, result.outcome);
    try std.testing.expect(result.requires_escalation);

    try std.testing.expectError(
        ConsensusError.DivergentOutputs,
        requireConsensus(&outputs, .{ .policy = .majority, .escalate_on_divergence = false }),
    );
}

test "consensus: unanimous policy rejects any dissent" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("A", 90),
        agent_mod.AgentOutput.fromSummary("A", 90),
        agent_mod.AgentOutput.fromSummary("B", 10),
    };
    const result = try evaluate(&outputs, .{ .policy = .unanimous });
    try std.testing.expectEqual(Outcome.divergent, result.outcome);
}

test "consensus: quorum threshold" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("A", 70),
        agent_mod.AgentOutput.fromSummary("A", 70),
        agent_mod.AgentOutput.fromSummary("B", 99),
        agent_mod.AgentOutput.fromSummary("C", 99),
    };

    try std.testing.expectEqual(
        Outcome.threshold_met,
        (try evaluate(&outputs, .{ .policy = .quorum, .quorum = 2 })).outcome,
    );
    try std.testing.expectEqual(
        Outcome.divergent,
        (try evaluate(&outputs, .{ .policy = .quorum, .quorum = 3 })).outcome,
    );
}

test "consensus: best-confidence picks the strongest answer" {
    const outputs = [_]agent_mod.AgentOutput{
        agent_mod.AgentOutput.fromSummary("A", 40),
        agent_mod.AgentOutput.fromSummary("B", 95),
        agent_mod.AgentOutput.fromSummary("C", 60),
    };

    const result = try evaluate(&outputs, .{ .policy = .best_confidence });
    try std.testing.expectEqual(@as(usize, 1), result.winner_index);
    try std.testing.expectEqual(Outcome.selected, result.outcome);
}

test "consensus: failed and low-confidence replicas do not vote" {
    var failed = agent_mod.AgentOutput.fromSummary("A", 100);
    failed.status = .failed;

    const outputs = [_]agent_mod.AgentOutput{
        failed,
        agent_mod.AgentOutput.fromSummary("B", 80),
        agent_mod.AgentOutput.fromSummary("B", 20),
    };

    const result = try evaluate(&outputs, .{ .policy = .majority, .min_confidence = 50 });
    try std.testing.expectEqual(@as(u16, 1), result.voters);
    try std.testing.expectEqual(@as(usize, 1), result.winner_index);

    const all_failed = [_]agent_mod.AgentOutput{failed};
    try std.testing.expectError(ConsensusError.InsufficientVoters, evaluate(&all_failed, .{}));
    try std.testing.expectError(ConsensusError.InsufficientVoters, evaluate(&.{}, .{}));
}

test "consensus: first-usable is latency optimised" {
    var canceled = agent_mod.AgentOutput.fromSummary("X", 100);
    canceled.status = .canceled;

    const outputs = [_]agent_mod.AgentOutput{
        canceled,
        agent_mod.AgentOutput.fromSummary("Y", 10),
        agent_mod.AgentOutput.fromSummary("Z", 99),
    };

    const result = try evaluate(&outputs, .{ .policy = .first_usable });
    try std.testing.expectEqual(@as(usize, 1), result.winner_index);
}
