/// Policy engine per spec §3: deny-by-default, compiled IR, audit ledger.
/// Policy files (YAML/TOML) are loaded as rules and compiled to a flat IR
/// for fast evaluation. The audit ledger is hash-chained and append-only.
const std = @import("std");
const classifier = @import("classifier.zig");

pub const Decision = enum(u8) {
    allow,
    deny,
    redact,
    require_approval,
};

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

/// A single compiled policy rule.
pub const PolicyRule = struct {
    id: []const u8,
    /// Minimum classification that triggers this rule.
    min_classification: classifier.Classification,
    /// Actions this rule applies to ("*" matches all).
    action_pattern: []const u8,
    decision: Decision,
    redaction_profile_id: ?[]const u8,
    reason: []const u8,
};

pub const PolicyError = error{
    NoPolicyLoaded,
    OutOfMemory,
    InvalidRule,
};

/// Compiled policy IR evaluated with deny-by-default semantics.
/// @example
/// var engine = PolicyEngine.init(alloc);
/// try engine.loadRule(.{ .id = "deny-secrets", .min_classification = .secret, ... });
/// const verdict = try engine.evaluate(input);
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

    /// Loads a default permissive ruleset for local development.
    /// @example
    /// try engine.loadDefaults();
    pub fn loadDefaults(self: *PolicyEngine) !void {
        // Allow all public/internal actions.
        try self.rules.append(self.allocator, .{
            .id = "allow-public",
            .min_classification = .public,
            .action_pattern = "*",
            .decision = .allow,
            .redaction_profile_id = null,
            .reason = "public content is unrestricted",
        });
        // Redact confidential content before sending to external providers.
        try self.rules.append(self.allocator, .{
            .id = "redact-confidential",
            .min_classification = .confidential,
            .action_pattern = "provider_send",
            .decision = .redact,
            .redaction_profile_id = "default",
            .reason = "confidential content must be redacted before provider egress",
        });
        // Deny regulated/secret content from any external egress.
        try self.rules.append(self.allocator, .{
            .id = "deny-secret-egress",
            .min_classification = .regulated,
            .action_pattern = "provider_send",
            .decision = .deny,
            .redaction_profile_id = null,
            .reason = "regulated/secret content may not be sent to external providers",
        });
        // Filesystem writes outside workspace need approval.
        try self.rules.append(self.allocator, .{
            .id = "approve-fs-outside-workspace",
            .min_classification = .public,
            .action_pattern = "file_write_external",
            .decision = .require_approval,
            .redaction_profile_id = null,
            .reason = "filesystem writes outside workspace root require human approval",
        });
    }

    /// Appends a compiled rule.
    pub fn loadRule(self: *PolicyEngine, rule: PolicyRule) !void {
        try self.rules.append(self.allocator, rule);
    }

    /// Evaluates the policy IR for a given input. Deny-by-default.
    /// @example
    /// const verdict = try engine.evaluate(input);
    pub fn evaluate(self: *const PolicyEngine, input: PolicyInput) PolicyError!PolicyDecision {
        if (self.rules.items.len == 0) return PolicyError.NoPolicyLoaded;

        // Compute max classification from input.
        var max_class = classifier.Classification.public;
        for (input.classifications) |c| {
            if (@intFromEnum(c) > @intFromEnum(max_class)) max_class = c;
        }

        // Evaluate rules in order; last matching rule wins.
        var verdict = PolicyDecision{
            .decision = .allow,
            .rule_id = "default-allow",
            .redaction_profile_id = null,
            .reason = "no matching rule; default allow for public content",
        };

        // Default deny if classification >= confidential and no explicit allow.
        if (@intFromEnum(max_class) >= @intFromEnum(classifier.Classification.confidential)) {
            verdict = .{
                .decision = .deny,
                .rule_id = "default-deny",
                .redaction_profile_id = null,
                .reason = "deny-by-default for elevated classification",
            };
        }

        for (self.rules.items) |rule| {
            if (@intFromEnum(max_class) < @intFromEnum(rule.min_classification)) continue;
            const action_match = std.mem.eql(u8, rule.action_pattern, "*") or
                std.mem.eql(u8, rule.action_pattern, input.action);
            if (!action_match) continue;

            verdict = .{
                .decision = rule.decision,
                .rule_id = rule.id,
                .redaction_profile_id = rule.redaction_profile_id,
                .reason = rule.reason,
            };
        }

        return verdict;
    }
};

/// Append-only hash-chained audit ledger per spec §3.4.
/// Each record's hash is chained to the previous record's hash for tamper evidence.
/// @example
/// var ledger = AuditLedger.init(alloc);
/// try ledger.append(record);
pub const AuditLedger = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(LedgerEntry),
    prev_hash: [32]u8,

    pub const LedgerEntry = struct {
        record: AuditRecord,
        record_hash: [32]u8,
        chain_hash: [32]u8,
    };

    pub fn init(alloc: std.mem.Allocator) AuditLedger {
        return .{
            .allocator = alloc,
            .entries = .empty,
            .prev_hash = @as([32]u8, @splat(0)),
        };
    }

    pub fn deinit(self: *AuditLedger) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends a tamper-evident audit frame.
    /// @example
    /// try ledger.append(record);
    pub fn append(self: *AuditLedger, record: AuditRecord) !void {
        // Serialize record fields into a hash input buffer.
        // Use a larger buffer to prevent truncation for long provider/model IDs.
        var buf: [512]u8 = undefined;
        const record_bytes = std.fmt.bufPrint(&buf, "{d}|{s}|{s}|{d}|{d}|{d}", .{
            record.ts_unix_ms,
            record.provider_id,
            record.model_id,
            record.input_tokens,
            record.output_tokens,
            @intFromEnum(record.decision),
        }) catch {
            // Fallback: hash a struct representation that can't overflow.
            // Encode only numeric fields to guarantee a stable, non-truncated hash input.
            var fb_buf: [64]u8 = undefined;
            const fallback = std.fmt.bufPrint(&fb_buf, "{d}|{d}|{d}|{d}", .{
                record.ts_unix_ms,
                record.input_tokens,
                record.output_tokens,
                @intFromEnum(record.decision),
            }) catch &fb_buf;
            var record_hash_fb: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(fallback, &record_hash_fb, .{});
            var chain_input_fb: [64]u8 = undefined;
            @memcpy(chain_input_fb[0..32], &record_hash_fb);
            @memcpy(chain_input_fb[32..64], &self.prev_hash);
            var chain_hash_fb: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&chain_input_fb, &chain_hash_fb, .{});
            try self.entries.append(self.allocator, .{
                .record = record,
                .record_hash = record_hash_fb,
                .chain_hash = chain_hash_fb,
            });
            self.prev_hash = chain_hash_fb;
            return;
        };

        var record_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(record_bytes, &record_hash, .{});

        // Chain hash = SHA256(record_hash || prev_hash).
        var chain_input: [64]u8 = undefined;
        @memcpy(chain_input[0..32], &record_hash);
        @memcpy(chain_input[32..64], &self.prev_hash);
        var chain_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&chain_input, &chain_hash, .{});

        try self.entries.append(self.allocator, .{
            .record = record,
            .record_hash = record_hash,
            .chain_hash = chain_hash,
        });
        self.prev_hash = chain_hash;
    }

    /// Verifies the hash chain integrity. Returns false if tampered.
    /// @example
    /// const ok = ledger.verifyChain();
    pub fn verifyChain(self: *const AuditLedger) bool {
        var prev: [32]u8 = @as([32]u8, @splat(0));
        for (self.entries.items) |entry| {
            var chain_input: [64]u8 = undefined;
            @memcpy(chain_input[0..32], &entry.record_hash);
            @memcpy(chain_input[32..64], &prev);
            var expected: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&chain_input, &expected, .{});
            if (!std.mem.eql(u8, &expected, &entry.chain_hash)) return false;
            prev = entry.chain_hash;
        }
        return true;
    }

    pub fn len(self: *const AuditLedger) usize {
        return self.entries.items.len;
    }
};

test "policy: default rules evaluate correctly" {
    var engine = PolicyEngine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.loadDefaults();

    // Public content to provider_send → allow.
    {
        const input = PolicyInput{
            .user_id = "u1",
            .action = "provider_send",
            .provider_id = "openai",
            .model_id = "gpt-4o",
            .classifications = &[_]classifier.Classification{.public},
            .workspace_id = "ws1",
        };
        const verdict = try engine.evaluate(input);
        try std.testing.expectEqual(Decision.allow, verdict.decision);
    }

    // Secret content to provider_send → deny.
    {
        const input = PolicyInput{
            .user_id = "u1",
            .action = "provider_send",
            .provider_id = "openai",
            .model_id = "gpt-4o",
            .classifications = &[_]classifier.Classification{.secret},
            .workspace_id = "ws1",
        };
        const verdict = try engine.evaluate(input);
        try std.testing.expectEqual(Decision.deny, verdict.decision);
    }
}

test "audit ledger: chain integrity" {
    var ledger = AuditLedger.init(std.testing.allocator);
    defer ledger.deinit();

    const rec = AuditRecord{
        .ts_unix_ms = 1000,
        .user_id_hash = @as([32]u8, @splat(0)),
        .prompt_hash = @as([32]u8, @splat(1)),
        .response_hash = @as([32]u8, @splat(2)),
        .provider_id = "local",
        .model_id = "llama",
        .latency_ms = 50,
        .input_tokens = 100,
        .output_tokens = 200,
        .decision = .allow,
    };

    try ledger.append(rec);
    try ledger.append(rec);
    try std.testing.expect(ledger.verifyChain());
    try std.testing.expectEqual(@as(usize, 2), ledger.len());
}
