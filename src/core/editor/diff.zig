//! Native line-level diff for the editor gutter.
//!
//! Compares the open buffer's text against the on-disk reference and returns
//! sparse change regions (modified / added / deleted) with 0-based buffer line
//! numbers, so the UI can paint gutter markers without shipping both texts
//! over IPC twice. Uses Myers' O((N+M)D) algorithm with a bounded trace:
//! when the edit distance or input size exceeds the budget it falls back to a
//! coarse single-region result (common prefix/suffix trimmed), which is
//! exactly what a gutter needs for wholesale rewrites anyway.
const std = @import("std");
const compat = @import("../compat.zig");

pub const ChangeKind = enum { modified, added, deleted };

pub const Region = struct {
    /// 0-based buffer line where the region starts. For `deleted` this is the
    /// buffer line at the deletion boundary (== buffer line count when the
    /// deletion sits at the end of the file).
    line: usize,
    kind: ChangeKind,
    /// Number of affected buffer lines (`deleted`: number of removed disk
    /// lines, since the buffer has no line to mark).
    count: usize,
};

const Kind = enum { equal, deleted, inserted };

const Op = struct { kind: Kind, count: usize };

/// Above this edit distance (or line count) the trace would blow up; fall back
/// to a coarse region instead.
const max_d_cap: usize = 1000;
const max_lines: usize = 60_000;

/// Maps a signed diagonal `k` to the offset v-array index. `k` is guaranteed
/// to lie within [-max_d, max_d] wherever this is used, so the cast is safe.
inline fn vIdx(v0: usize, k: isize) usize {
    return @intCast(@as(isize, @intCast(v0)) + k);
}

/// Splits `text` into lines (slices borrowing from `text`). A trailing '\n'
/// is treated as a terminator, not a phantom empty line.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = compat.ManagedArrayList([]const u8).init(allocator);
    errdefer lines.deinit();
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
        try lines.append(text[start..nl]);
        start = nl + 1;
    }
    if (start < text.len) try lines.append(text[start..]);
    return lines.toOwnedSlice();
}

/// Computes change regions between `old_text` (the on-disk reference) and
/// `new_text` (the current buffer). Returns an empty slice when equal.
pub fn computeRegions(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
) ![]Region {
    const a = try splitLines(allocator, old_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, new_text);
    defer allocator.free(b);
    return computeRegionsLines(allocator, a, b);
}

pub fn computeRegionsLines(
    allocator: std.mem.Allocator,
    a: []const []const u8, // old (disk)
    b: []const []const u8, // new (buffer)
) ![]Region {
    var regions = compat.ManagedArrayList(Region).init(allocator);
    errdefer regions.deinit();

    // Trim the common prefix and suffix — the cheap 99% case for small edits.
    var prefix: usize = 0;
    const max_prefix = @min(a.len, b.len);
    while (prefix < max_prefix and std.mem.eql(u8, a[prefix], b[prefix])) prefix += 1;

    var a_suf = a.len;
    var b_suf = b.len;
    while (a_suf > prefix and b_suf > prefix and std.mem.eql(u8, a[a_suf - 1], b[b_suf - 1])) {
        a_suf -= 1;
        b_suf -= 1;
    }

    const mid_a = a[prefix..a_suf];
    const mid_b = b[prefix..b_suf];

    if (mid_a.len == 0 and mid_b.len == 0) return regions.toOwnedSlice();

    // Pure insertion / pure deletion (or inputs too big to diff precisely).
    if (mid_a.len == 0 or mid_b.len == 0 or mid_a.len + mid_b.len > max_lines) {
        try regions.append(.{
            .line = prefix,
            .kind = if (mid_b.len == 0) .deleted else .added,
            .count = if (mid_b.len == 0) mid_a.len else mid_b.len,
        });
        return regions.toOwnedSlice();
    }

    const ops = myers(allocator, mid_a, mid_b, max_d_cap) catch {
        // Budget exceeded: one coarse region over the whole middle.
        try regions.append(.{ .line = prefix, .kind = .modified, .count = mid_b.len });
        return regions.toOwnedSlice();
    };
    defer allocator.free(ops);

    // Walk the ops, grouping runs of non-equal edits into regions. The buffer
    // cursor tracks consumed `b` lines so region line numbers are exact.
    var buffer_cursor = prefix;
    var i: usize = 0;
    while (i < ops.len) {
        if (ops[i].kind == .equal) {
            buffer_cursor += ops[i].count;
            i += 1;
            continue;
        }
        var buf_delta: usize = 0;
        var disk_delta: usize = 0;
        while (i < ops.len and ops[i].kind != .equal) : (i += 1) {
            switch (ops[i].kind) {
                .inserted => buf_delta += ops[i].count,
                .deleted => disk_delta += ops[i].count,
                .equal => unreachable,
            }
        }
        const kind: ChangeKind = if (buf_delta > 0 and disk_delta > 0)
            .modified
        else if (buf_delta > 0)
            .added
        else
            .deleted;
        try regions.append(.{
            .line = buffer_cursor,
            .kind = kind,
            .count = if (kind == .deleted) disk_delta else buf_delta,
        });
        buffer_cursor += buf_delta;
    }

    return regions.toOwnedSlice();
}

/// Myers O((N+M)D) diff between two line arrays, returning the edit script as
/// coalesced ops. Returns `error.DiffTooLarge` when D exceeds `max_d`.
fn myers(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
    max_d: usize,
) ![]Op {
    const n = a.len;
    const m = b.len;

    // v[k] = furthest x reachable on diagonal k. Indexed with an offset so
    // negative k works: v[v0 + k].
    const v_len = 2 * max_d + 1;
    const v0: usize = max_d;
    const v = try allocator.alloc(isize, v_len);
    defer allocator.free(v);
    @memset(v, -1);
    v[v0 + 1] = 0;

    // Trace: v snapshot before each depth, used to backtrack the solution.
    var trace = compat.ManagedArrayList([]isize).init(allocator);
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit();
    }

    var found: ?usize = null;
    var d: usize = 0;
    while (d <= max_d) : (d += 1) {
        const snap = try allocator.dupe(isize, v);
        try trace.append(snap);
        const di: isize = @intCast(d);
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            var x: isize = undefined;
            if (k == -di or (k != di and v[vIdx(v0, k - 1)] < v[vIdx(v0, k + 1)])) {
                x = v[vIdx(v0, k + 1)];
            } else {
                x = v[vIdx(v0, k - 1)] + 1;
            }
            var y = x - k;
            const n_i: isize = @intCast(n);
            const m_i: isize = @intCast(m);
            while (x < n_i and y < m_i and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[vIdx(v0, k)] = x;
            if (x >= n_i and y >= m_i) {
                found = d;
                break;
            }
        }
        if (found != null) break;
    }

    const d_found = found orelse return error.DiffTooLarge;

    // Backtrack from (n, m), emitting ops in reverse.
    var ops = compat.ManagedArrayList(Op).init(allocator);
    defer ops.deinit();

    var x: isize = @intCast(n);
    var y: isize = @intCast(m);
    var dd: usize = d_found;
    while (dd > 0) : (dd -= 1) {
        const snap = trace.items[dd];
        const k = x - y;
        const di: isize = @intCast(dd);
        var prev_k: isize = undefined;
        if (k == -di or (k != di and snap[vIdx(v0, k - 1)] < snap[vIdx(v0, k + 1)])) {
            prev_k = k + 1;
        } else {
            prev_k = k - 1;
        }
        const prev_x = snap[vIdx(v0, prev_k)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            try ops.append(.{ .kind = .equal, .count = 1 });
            x -= 1;
            y -= 1;
        }
        if (x == prev_x) {
            try ops.append(.{ .kind = .inserted, .count = 1 });
            y -= 1;
        } else {
            try ops.append(.{ .kind = .deleted, .count = 1 });
            x -= 1;
        }
    }
    // Safety net for any untouched head (inputs are pre-trimmed, so this is
    // normally empty).
    while (x > 0 or y > 0) {
        if (x > 0 and y > 0) {
            try ops.append(.{ .kind = .equal, .count = 1 });
            x -= 1;
            y -= 1;
        } else if (x > 0) {
            try ops.append(.{ .kind = .deleted, .count = 1 });
            x -= 1;
        } else {
            try ops.append(.{ .kind = .inserted, .count = 1 });
            y -= 1;
        }
    }

    std.mem.reverse(Op, ops.items);

    // Coalesce adjacent same-kind ops.
    var merged = compat.ManagedArrayList(Op).init(allocator);
    errdefer merged.deinit();
    for (ops.items) |op| {
        if (merged.items.len > 0 and merged.items[merged.items.len - 1].kind == op.kind) {
            merged.items[merged.items.len - 1].count += op.count;
        } else {
            try merged.append(op);
        }
    }
    return merged.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectRegions(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8, expected: []const Region) !void {
    const regions = try computeRegions(allocator, old_text, new_text);
    defer allocator.free(regions);
    try testing.expectEqual(expected.len, regions.len);
    for (expected, 0..) |want, i| {
        try testing.expectEqual(want.line, regions[i].line);
        try testing.expectEqual(want.kind, regions[i].kind);
        try testing.expectEqual(want.count, regions[i].count);
    }
}

test "diff: identical texts produce no regions" {
    try expectRegions(testing.allocator, "alpha\nbeta\ngamma\n", "alpha\nbeta\ngamma\n", &.{});
    try expectRegions(testing.allocator, "", "", &.{});
    try expectRegions(testing.allocator, "single", "single", &.{});
}

test "diff: appended lines are added at the end" {
    try expectRegions(testing.allocator, "a\nb\n", "a\nb\nc\nd\n", &.{
        .{ .line = 2, .kind = .added, .count = 2 },
    });
}

test "diff: removed trailing lines are deleted at the boundary" {
    // Buffer has 3 lines; disk had 4 — the deletion boundary is buffer line 3.
    try expectRegions(testing.allocator, "alpha\nbeta\ngamma\ndelta\n", "alpha\nbeta\ngamma\n", &.{
        .{ .line = 3, .kind = .deleted, .count = 1 },
    });
}

test "diff: a middle edit is a modified region" {
    try expectRegions(testing.allocator, "alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n", &.{
        .{ .line = 1, .kind = .modified, .count = 1 },
    });
}

test "diff: line count change in the middle is a modified region" {
    // One disk line replaced by two buffer lines.
    try expectRegions(testing.allocator, "a\nb\nc\n", "a\nx\ny\nc\n", &.{
        .{ .line = 1, .kind = .modified, .count = 2 },
    });
}

test "diff: multiple regions keep exact line numbers" {
    // Disk:   line0, one,   two,   three, end
    // Buffer: line0, ONE,   two,   end,   tail
    // Myers keeps `end` as a common line: one→ONE (modified), three removed
    // (deleted, boundary at buffer line 3), tail appended (added at line 4).
    try expectRegions(
        testing.allocator,
        "line0\none\ntwo\nthree\nend\n",
        "line0\nONE\ntwo\nend\ntail\n",
        &.{
            .{ .line = 1, .kind = .modified, .count = 1 },
            .{ .line = 3, .kind = .deleted, .count = 1 },
            .{ .line = 4, .kind = .added, .count = 1 },
        },
    );
}

test "diff: empty buffer is all deletions" {
    try expectRegions(testing.allocator, "a\nb\nc\n", "", &.{
        .{ .line = 0, .kind = .deleted, .count = 3 },
    });
}

test "diff: empty disk is all additions" {
    try expectRegions(testing.allocator, "", "a\nb\nc\n", &.{
        .{ .line = 0, .kind = .added, .count = 3 },
    });
}

test "diff: trailing newline is a terminator, not a phantom line" {
    // "x\n" and "x" are the same single line.
    try expectRegions(testing.allocator, "x\n", "x", &.{});
    try expectRegions(testing.allocator, "x\n", "x\ny\n", &.{
        .{ .line = 1, .kind = .added, .count = 1 },
    });
}

test "diff: splitLines handles empty and trailing newline" {
    const a = try splitLines(testing.allocator, "");
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);

    const b = try splitLines(testing.allocator, "one\ntwo\n");
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqualStrings("one", b[0]);
    try testing.expectEqualStrings("two", b[1]);
}
