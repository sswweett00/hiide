/// Intent classifier and TaskEnvelope builder per spec §1.3.
/// Normalizes edit stream, git delta, semantic index signals, and user commands
/// into a structured TaskEnvelope that feeds the Planner agent.
const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("types.zig");

/// Raw signal sources from the IDE event stream.
pub const EditEvent = struct {
    /// URI of the file being edited.
    file_uri: []const u8,
    /// Number of characters changed.
    change_count: u32,
    /// Cursor line position.
    cursor_line: u32,
    /// Cursor column position (UTF-8).
    cursor_col: u32,
    /// Unix millisecond timestamp.
    ts_unix_ms: i64,
};

pub const GitDelta = struct {
    branch: []const u8,
    files_changed: u32,
    insertions: u32,
    deletions: u32,
    commit_sha: [20]u8,
};

pub const UserCommand = struct {
    raw_text: []const u8,
    /// Explicit intent hint from the UI (optional).
    hint: ?IntentClass,
};

/// Intent classes inferred by the classifier.
pub const IntentClass = enum(u8) {
    unknown,
    code_generation,
    code_review,
    refactor,
    test_generation,
    documentation,
    bug_fix,
    security_audit,
    research,
    planning,
};

/// Confidence score 0–100.
pub const Classification = struct {
    class: IntentClass,
    confidence: u8,
};

/// Normalized envelope produced from raw IDE signals.
pub const TaskEnvelope = struct {
    /// Derived intent classification.
    intent: Classification,
    /// Agent kind most appropriate for this intent.
    recommended_kind: types.AgentKind,
    /// Suggested execution mode.
    recommended_mode: types.ExecutionMode,
    /// Human-readable summary for the title field.
    title_buf: [128]u8,
    title_len: u8,
    /// Reference snapshot of open file context.
    file_uri: []const u8,
    ts_unix_ms: i64,

    pub fn title(self: *const TaskEnvelope) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Stateless classifier: maps intent class to recommended agent kind and mode.
/// @example
/// const envelope = IntentClassifier.classify(edit, null, cmd, alloc);
pub const IntentClassifier = struct {
    pub fn classify(
        edit: ?EditEvent,
        git: ?GitDelta,
        cmd: ?UserCommand,
    ) TaskEnvelope {
        _ = git;

        var class = IntentClass.unknown;
        var confidence: u8 = 0;

        // Use explicit hint from UI first.
        if (cmd) |c| {
            if (c.hint) |h| {
                class = h;
                confidence = 90;
            } else {
                class = heuristicFromText(c.raw_text);
                confidence = 60;
            }
        } else if (edit != null) {
            class = .code_generation;
            confidence = 40;
        }

        const kind = kindForIntent(class);
        const mode = modeForIntent(class);

        var env = TaskEnvelope{
            .intent = .{ .class = class, .confidence = confidence },
            .recommended_kind = kind,
            .recommended_mode = mode,
            .title_buf = undefined,
            .title_len = 0,
            .file_uri = if (edit) |e| e.file_uri else "",
            .ts_unix_ms = compat.milliTimestamp(),
        };

        const label = @tagName(class);
        const copy_len = @min(label.len, env.title_buf.len);
        @memcpy(env.title_buf[0..copy_len], label[0..copy_len]);
        env.title_len = @intCast(copy_len);

        return env;
    }

    fn heuristicFromText(text: []const u8) IntentClass {
        const lower_keywords = .{
            .{ "review", IntentClass.code_review },
            .{ "refactor", IntentClass.refactor },
            .{ "test", IntentClass.test_generation },
            .{ "doc", IntentClass.documentation },
            .{ "fix", IntentClass.bug_fix },
            .{ "security", IntentClass.security_audit },
            .{ "audit", IntentClass.security_audit },
            .{ "research", IntentClass.research },
            .{ "plan", IntentClass.planning },
        };
        inline for (lower_keywords) |kw| {
            if (std.mem.containsAtLeast(u8, text, 1, kw[0])) return kw[1];
        }
        return .code_generation;
    }

    fn kindForIntent(class: IntentClass) types.AgentKind {
        return switch (class) {
            .planning, .unknown => .planner,
            .code_generation, .bug_fix => .coder,
            .code_review => .reviewer,
            .test_generation => .tester,
            .research => .researcher,
            .security_audit => .security_auditor,
            .documentation => .documentation_writer,
            .refactor => .refactor_specialist,
        };
    }

    fn modeForIntent(class: IntentClass) types.ExecutionMode {
        return switch (class) {
            .planning => .parallel_fanout,
            .code_review => .debate_consensus,
            .security_audit => .approval_gated,
            else => .sequential,
        };
    }
};

test "intent: classify from text hint" {
    const cmd = UserCommand{ .raw_text = "security audit all deps", .hint = null };
    const env = IntentClassifier.classify(null, null, cmd);
    try std.testing.expectEqual(IntentClass.security_audit, env.intent.class);
    try std.testing.expectEqual(types.AgentKind.security_auditor, env.recommended_kind);
    try std.testing.expectEqual(types.ExecutionMode.approval_gated, env.recommended_mode);
}

test "intent: explicit hint overrides text" {
    const cmd = UserCommand{ .raw_text = "review this", .hint = .planning };
    const env = IntentClassifier.classify(null, null, cmd);
    try std.testing.expectEqual(IntentClass.planning, env.intent.class);
    try std.testing.expectEqual(@as(u8, 90), env.intent.confidence);
}
