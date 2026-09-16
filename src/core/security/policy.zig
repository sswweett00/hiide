/// Policy engine per spec §3: deny-by-default, compiled IR, audit ledger.
/// Policy files (YAML/TOML) are loaded as rules and compiled to a flat IR
/// for deterministic evaluation. The audit ledger is hash-chained and
/// tamper-evident.
const std = @import("std");
const classifier = @import("classifier.zig");

pub const Decision = enum(u8) { allow, deny, redact, require_approval };

pub const PolicyInput = struct {
    user_id: []const u8,
    action: []const u8,
    provider_id: []const u8,
    model_id: []const u8,
    classifications: []const classifier.Classification,
    workspace_id: []const u8,
};

pub const PolicyDecision = struct {
    decision: Decision,
    rule_id: []const u8,
    redaction_profile_id: ?[]const u8,
    reason: []const u8,
};

pub const AuditRecord = struct {
    ts_unix_ms: i64,
    user_id_hash: [32]u8,
    prompt_hash: [32]u8,
    response_hash: [32]u8,
    provider_id: []const u8,
    model_id: []const u8,
    latency_ms: u32,
    input_tokens: u32,
    output_tokens: u32,
    decision: Decision,
};

pub const PolicyRule = struct {
    id: []const u8,
    min_classification: classifier.Classification,
    action_pattern: []const u8,
    decision: Decision,
    redaction_profile_id: ?[]const u8,
    reason: []const u8,
};

pub const PolicyError = error{ NoPolicyLoaded, OutOfMemory, InvalidRule };

fn decisionPrecedence(decision: Decision) u8 {
    return switch (decision) {
        .allow => 0,
        .redact => 1,
        .require_approval => 2,
        .deny => 3,
    };
}

pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayListUnmanaged(PolicyRule),

    pub fn init(alloc: std.mem.Allocator) PolicyEngine {
        return .{ .allocator = alloc, .rules = .empty };
    }

    pub fn deinit(self: *PolicyEngine) void {
        self.rules.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadDefaults(self: *PolicyEngine) !void {
        try self.rules.append(self.allocator, .{ .id = "allow-public", .min_classification = .public, .action_pattern = "*", .decision = .allow, .redaction_profile_id = null, .reason = "public content is unrestricted" });
        try self.rules.append(self.allocator, .{ .id = "redact-confidential", .min_classification = .confidential, .action_pattern = "provider_send", .decision = .redact, .redaction_profile_id = "default", .reason = "confidential content must be redacted before provider egress" });
        try self.rules.append(self.allocator, .{ .id = "deny-secret-egress", .min_classification = .regulated, .action_pattern = "provider_send", .decision = .deny, .redaction_profile_id = null, .reason = "regulated/secret content may not be sent to external providers" });
        try self.rules.append(self.allocator, .{ .id = "approve-fs-outside-workspace", .min_classification = .public, .action_pattern = "file_write_external", .decision = .require_approval, .redaction_profile_id = null, .reason = "filesystem writes outside workspace root require human approval" });
    }

    pub fn loadRule(self: *PolicyEngine, rule: PolicyRule) !void {
        if (rule.id.len == 0 or rule.action_pattern.len == 0 or rule.reason.len == 0) return PolicyError.InvalidRule;
        try self.rules.append(self.allocator, rule);
    }

    /// Evaluates all matching rules and chooses the most restrictive decision.
    /// Unmatched actions remain denied.
    pub fn evaluate(self: *const PolicyEngine, input: PolicyInput) PolicyError!PolicyDecision {
        if (self.rules.items.len == 0) return PolicyError.NoPolicyLoaded;

        var max_class = classifier.Classification.public;
        for (input.classifications) |c| {
            if (@intFromEnum(c) > @intFromEnum(max_class)) max_class = c;
        }

        var verdict = PolicyDecision{ .decision = .deny, .rule_id = "default-deny", .redaction_profile_id = null, .reason = "no matching allow rule; policy is deny-by-default" };
        var matched = false;

        for (self.rules.items) |rule| {
            if (@intFromEnum(max_class) < @intFromEnum(rule.min_classification)) continue;
            const action_match = std.mem.eql(u8, rule.action_pattern, "*") or std.mem.eql(u8, rule.action_pattern, input.action);
            if (!action_match) continue;

            if (!matched or decisionPrecedence(rule.decision) > decisionPrecedence(verdict.decision)) {
                verdict = .{ .decision = rule.decision, .rule_id = rule.id, .redaction_profile_id = rule.redaction_profile_id, .reason = rule.reason };
                matched = true;
            }
        }

        return verdict;
    }
};

pub const AuditLedger = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(LedgerEntry),
    prev_hash: [32]u8,

    pub const LedgerEntry = struct { record: AuditRecord, record_hash: [32]u8, chain_hash: [32]u8 };

    pub fn init(alloc: std.mem.Allocator) AuditLedger {
        return .{ .allocator = alloc, .entries = .empty, .prev_hash = @as([32]u8, @splat(0)) };
    }

    pub fn deinit(self: *AuditLedger) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn hashRecord(record: AuditRecord) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&record.ts_unix_ms));
        hasher.update(&record.user_id_hash);
        hasher.update(&record.prompt_hash);
        hasher.update(&record.response_hash);
        hasher.update(record.provider_id);
        hasher.update(&[_]u8{0});
        hasher.update(record.model_id);
        hasher.update(&[_]u8{0});
        hasher.update(std.mem.asBytes(&record.latency_ms));
        hasher.update(std.mem.asBytes(&record.input_tokens));
        hasher.update(std.mem.asBytes(&record.output_tokens));
        hasher.update(&[_]u8{@intFromEnum(record.decision)});
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    fn hashChain(record_hash: [32]u8, prev_hash: [32]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&record_hash);
        hasher.update(&prev_hash);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    pub fn append(self: *AuditLedger, record: AuditRecord) !void {
        const record_hash = hashRecord(record);
        const chain_hash = hashChain(record_hash, self.prev_hash);
        try self.entries.append(self.allocator, .{ .record = record, .record_hash = record_hash, .chain_hash = chain_hash });
        self.prev_hash = chain_hash;
    }

    pub fn verifyChain(self: *const AuditLedger) bool {
        var prev: [32]u8 = @as([32]u8, @splat(0));
        for (self.entries.items) |entry| {
            const expected_record = hashRecord(entry.record);
            if (!std.mem.eql(u8, &expected_record, &entry.record_hash)) return false;
            const expected_chain = hashChain(expected_record, prev);
            if (!std.mem.eql(u8, &expected_chain, &entry.chain_hash)) return false;
            prev = entry.chain_hash;
        }
        return true;
    }

    pub fn len(self: *const AuditLedger) usize { return self.entries.items.len; }
};

test "policy: default rules evaluate correctly" {
    var engine = PolicyEngine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.loadDefaults();

    const public_verdict = try engine.evaluate(.{ .user_id = "u1", .action = "provider_send", .provider_id = "openai", .model_id = "gpt-4o", .classifications = &[_]classifier.Classification{.public}, .workspace_id = "ws1" });
    try std.testing.expectEqual(Decision.allow, public_verdict.decision);

    const secret_verdict = try engine.evaluate(.{ .user_id = "u1", .action = "provider_send", .provider_id = "openai", .model_id = "gpt-4o", .classifications = &[_]classifier.Classification{.secret}, .workspace_id = "ws1" });
    try std.testing.expectEqual(Decision.deny, secret_verdict.decision);
}

test "policy: restrictive rule wins regardless of declaration order" {
    var engine = PolicyEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.loadRule(.{ .id = "deny-secret", .min_classification = .secret, .action_pattern = "provider_send", .decision = .deny, .redaction_profile_id = null, .reason = "secrets never leave the workspace" });
    try engine.loadRule(.{ .id = "late-allow", .min_classification = .public, .action_pattern = "provider_send", .decision = .allow, .redaction_profile_id = null, .reason = "broad public rule" });

    const verdict = try engine.evaluate(.{ .user_id = "u1", .action = "provider_send", .provider_id = "provider", .model_id = "model", .classifications = &[_]classifier.Classification{.secret}, .workspace_id = "ws1" });
    try std.testing.expectEqual(Decision.deny, verdict.decision);
    try std.testing.expectEqualStrings("deny-secret", verdict.rule_id);
}

test "audit ledger: chain integrity and record tamper detection" {
    var ledger = AuditLedger.init(std.testing.allocator);
    defer ledger.deinit();

    const rec = AuditRecord{ .ts_unix_ms = 1000, .user_id_hash = @as([32]u8, @splat(0)), .prompt_hash = @as([32]u8, @splat(1)), .response_hash = @as([32]u8, @splat(2)), .provider_id = "local", .model_id = "llama", .latency_ms = 50, .input_tokens = 100, .output_tokens = 200, .decision = .allow };
    try ledger.append(rec);
    try ledger.append(rec);
    try std.testing.expect(ledger.verifyChain());
    try std.testing.expectEqual(@as(usize, 2), ledger.len());

    ledger.entries.items[0].record.model_id = "tampered";
    try std.testing.expect(!ledger.verifyChain());
}
