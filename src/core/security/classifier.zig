/// Content classification layer per spec §3.
/// Tags content spans for secrets, PII, regulated identifiers, and proprietary code.
/// Deny-by-default: ambiguous matches for regulated tenants return .regulated.
const std = @import("std");

pub const Classification = enum(u8) {
    public,
    internal,
    confidential,
    regulated,
    secret,
};

pub const ClassificationSpan = struct {
    start: u32,
    end: u32,
    class: Classification,
    /// Short label such as "api_key", "pii_email", "ssn", etc.
    label: []const u8,
};

/// Classifier result for a content body.
pub const ClassificationResult = struct {
    /// Highest classification found in the content.
    max_class: Classification,
    /// Individual spans with specific classifications.
    spans: []ClassificationSpan,
};

const Pattern = struct {
    label: []const u8,
    class: Classification,
    /// Needle substring (case-insensitive search used).
    needle: []const u8,
    /// When true the span is extended over the value that follows the needle so
    /// redaction removes the secret itself, not just its label.
    value_bearing: bool = false,
};

/// Built-in detector patterns. Extend with provider-specific patterns at runtime.
const BUILTIN_PATTERNS = [_]Pattern{
    // Secret detectors
    .{ .label = "api_key", .class = .secret, .needle = "api_key", .value_bearing = true },
    .{ .label = "api_key", .class = .secret, .needle = "apikey", .value_bearing = true },
    .{ .label = "private_key", .class = .secret, .needle = "-----BEGIN", .value_bearing = true },
    .{ .label = "aws_access_key", .class = .secret, .needle = "AKIA", .value_bearing = true },
    .{ .label = "token", .class = .secret, .needle = "bearer ", .value_bearing = true },
    .{ .label = "password", .class = .secret, .needle = "password=", .value_bearing = true },
    .{ .label = "secret", .class = .secret, .needle = "secret=", .value_bearing = true },
    // PII detectors
    .{ .label = "pii_email", .class = .confidential, .needle = "@" },
    // Regulated identifiers
    .{ .label = "ssn", .class = .regulated, .needle = "ssn", .value_bearing = true },
    .{ .label = "credit_card", .class = .regulated, .needle = "card_number", .value_bearing = true },
    .{ .label = "hipaa", .class = .regulated, .needle = "patient_id", .value_bearing = true },
};

pub const ContentClassifier = struct {
    /// Classifies a content body and returns all detected spans.
    /// Caller owns the result.spans slice.
    /// @example
    /// const result = try ContentClassifier.classify(content, alloc);
    pub fn classify(content: []const u8, alloc: std.mem.Allocator) !ClassificationResult {
        var spans = std.ArrayListUnmanaged(ClassificationSpan).empty;
        errdefer spans.deinit(alloc);

        var max_class = Classification.public;

        for (BUILTIN_PATTERNS) |pat| {
            var search_start: usize = 0;
            while (true) {
                const idx = indexOfCaseInsensitive(content, pat.needle, search_start) orelse break;
                var end = @min(idx + pat.needle.len, content.len);
                if (pat.value_bearing) end = extendOverValue(content, end);

                try spans.append(alloc, .{
                    .start = @intCast(idx),
                    .end = @intCast(end),
                    .class = pat.class,
                    .label = pat.label,
                });

                if (@intFromEnum(pat.class) > @intFromEnum(max_class)) {
                    max_class = pat.class;
                }
                search_start = end;
            }
        }

        // Entropy-based secret heuristic: look for long base64-ish tokens.
        max_class = @enumFromInt(@max(@intFromEnum(max_class), @intFromEnum(entropyHeuristic(content))));

        return .{
            .max_class = max_class,
            .spans = try spans.toOwnedSlice(alloc),
        };
    }

    /// Returns a redacted copy of content, replacing secret/regulated spans with `[REDACTED]`.
    /// Caller owns the returned slice.
    /// @example
    /// const redacted = try ContentClassifier.redact(content, spans, alloc);
    pub fn redact(content: []const u8, spans: []const ClassificationSpan, alloc: std.mem.Allocator) ![]u8 {
        if (spans.len == 0) return alloc.dupe(u8, content);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(alloc);

        // Sort spans by start offset (simple insertion sort for small span counts).
        var sorted = try alloc.dupe(ClassificationSpan, spans);
        defer alloc.free(sorted);
        for (1..sorted.len) |i| {
            var j = i;
            while (j > 0 and sorted[j - 1].start > sorted[j].start) {
                const tmp = sorted[j - 1];
                sorted[j - 1] = sorted[j];
                sorted[j] = tmp;
                j -= 1;
            }
        }

        var cursor: usize = 0;
        for (sorted) |span| {
            const s = @min(span.start, content.len);
            const e = @min(span.end, content.len);
            if (s > cursor) try out.appendSlice(alloc, content[cursor..s]);
            try out.appendSlice(alloc, "[REDACTED]");
            cursor = e;
        }
        if (cursor < content.len) try out.appendSlice(alloc, content[cursor..]);
        return out.toOwnedSlice(alloc);
    }

    /// Extends a detected span over the secret value that follows the label so
    /// that redaction removes the value itself (e.g. `password=hunter2`).
    fn extendOverValue(content: []const u8, needle_end: usize) usize {
        var i = needle_end;
        // Skip the separator run between the label and the value.
        while (i < content.len and isValueSeparator(content[i])) : (i += 1) {}
        // Consume the value up to the next delimiter.
        while (i < content.len and !isValueDelimiter(content[i])) : (i += 1) {}
        return i;
    }

    fn isValueSeparator(c: u8) bool {
        return switch (c) {
            ':', '=', ' ', '\t', '"', '\'' => true,
            else => false,
        };
    }

    fn isValueDelimiter(c: u8) bool {
        return switch (c) {
            '"', '\'', ',', ';', '}', ')', ']', '\n', '\r', ' ', '\t' => true,
            else => false,
        };
    }

    fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8, start: usize) ?usize {
        if (needle.len == 0 or haystack.len < needle.len) return null;
        const limit = haystack.len - needle.len + 1;
        if (start >= limit) return null;
        var i = start;
        while (i < limit) : (i += 1) {
            var match = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    match = false;
                    break;
                }
            }
            if (match) return i;
        }
        return null;
    }

    /// Estimates Shannon entropy of a substring to detect high-entropy secrets.
    fn entropyHeuristic(content: []const u8) Classification {
        if (content.len < 20) return .public;

        var freq = @as([256]u32, @splat(0));
        for (content) |c| freq[c] += 1;

        var entropy: f64 = 0.0;
        const n: f64 = @floatFromInt(content.len);
        for (freq) |f| {
            if (f == 0) continue;
            const p = @as(f64, @floatFromInt(f)) / n;
            entropy -= p * @log(p) / @log(2.0);
        }
        // Threshold: entropy > 4.5 bits/byte is suspicious.
        if (entropy > 4.5) return .confidential;
        return .public;
    }
};

test "classifier: detects api_key pattern" {
    const alloc = std.testing.allocator;
    const content = "config: { api_key: \"sk-abc123\" }";
    const result = try ContentClassifier.classify(content, alloc);
    defer alloc.free(result.spans);

    try std.testing.expect(result.max_class == .secret);
    try std.testing.expect(result.spans.len > 0);
}

test "classifier: redacts spans" {
    const alloc = std.testing.allocator;
    const content = "password=hunter2";
    const result = try ContentClassifier.classify(content, alloc);
    defer alloc.free(result.spans);

    const redacted = try ContentClassifier.redact(content, result.spans, alloc);
    defer alloc.free(redacted);

    try std.testing.expect(!std.mem.containsAtLeast(u8, redacted, 1, "hunter2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, redacted, 1, "[REDACTED]"));
}

test "classifier: public content stays public" {
    const alloc = std.testing.allocator;
    const content = "fn add(a: i32, b: i32) i32 { return a + b; }";
    const result = try ContentClassifier.classify(content, alloc);
    defer alloc.free(result.spans);

    try std.testing.expectEqual(Classification.public, result.max_class);
}
