const std = @import("std");

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    gap_start: usize,
    gap_end: usize,
    len: usize,
    newline_count: usize,

    const DefaultCapacity = 4096;
    const GapRatio = 0.25;

    pub fn init(allocator: std.mem.Allocator) !TextBuffer {
        const cap = DefaultCapacity;
        const buf = try allocator.alloc(u8, cap);
        @memset(buf, 0);
        return .{
            .allocator = allocator,
            .buf = buf,
            .gap_start = 0,
            .gap_end = cap,
            .len = 0,
            .newline_count = 0,
        };
    }

    pub fn deinit(self: *TextBuffer) void {
        self.allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn size(self: *const TextBuffer) usize {
        return self.len;
    }

    pub fn capacity(self: *const TextBuffer) usize {
        return self.buf.len;
    }

    fn gapSize(self: *const TextBuffer) usize {
        return self.gap_end - self.gap_start;
    }

    fn ensureGap(self: *TextBuffer, needed: usize) !void {
        const gap = self.gapSize();
        if (gap >= needed) return;

        const doubled = if (self.buf.len == 0)
            DefaultCapacity
        else
            std.math.mul(usize, self.buf.len, 2) catch std.math.maxInt(usize);
        const required = std.math.add(usize, self.len, needed) catch return error.OutOfMemory;
        const new_cap = @max(doubled, required);
        const new_buf = try self.allocator.alloc(u8, new_cap);

        @memcpy(new_buf[0..self.gap_start], self.buf[0..self.gap_start]);
        const new_gap_end = new_cap - (self.buf.len - self.gap_end);
        @memcpy(new_buf[new_gap_end..], self.buf[self.gap_end..]);

        self.allocator.free(self.buf);
        self.buf = new_buf;
        self.gap_end = new_gap_end;
    }

    fn moveGapTo(self: *TextBuffer, pos: usize) void {
        if (pos == self.gap_start) return;
        const gap = self.gapSize();

        var dist: usize = 0;
        if (pos < self.gap_start) {
            dist = self.gap_start - pos;
            @memcpy(self.buf[pos + gap .. self.gap_start + gap], self.buf[pos..self.gap_start]);
        } else {
            dist = pos - self.gap_start;
            @memcpy(self.buf[self.gap_start .. self.gap_start + dist], self.buf[self.gap_end .. self.gap_end + dist]);
        }
        if (pos < self.gap_start) {
            self.gap_end -= dist;
        } else {
            self.gap_end += dist;
        }
        self.gap_start = pos;
    }

    /// Counts newlines in a contiguous byte slice without gap indirection.
    fn countNewlines(data: []const u8) usize {
        var count: usize = 0;
        for (data) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    pub fn insert(self: *TextBuffer, pos: usize, bytes: []const u8) !void {
        if (pos > self.len) return error.OutOfBounds;
        if (bytes.len == 0) return;

        try self.ensureGap(bytes.len);
        self.moveGapTo(pos);

        @memcpy(self.buf[self.gap_start..][0..bytes.len], bytes);
        self.newline_count += countNewlines(bytes);
        self.gap_start += bytes.len;
        self.len += bytes.len;
    }

    pub fn delete(self: *TextBuffer, pos: usize, len_: usize) !void {
        if (pos > self.len or len_ > self.len - pos) return error.OutOfBounds;
        if (len_ == 0) return;

        // Count newlines in the region to be deleted BEFORE moving the gap,
        // because moveGapTo rearranges bytes and the original content would
        // no longer be accessible at [pos..pos+len_].
        //
        // Instead of calling charAt (which has per-byte gap indirection),
        // count directly against the contiguous memory regions of the buffer.
        // Logical positions [0..gap_start) map to buf[0..gap_start], and
        // positions [gap_start..len) map to buf[gap_end..gap_end + remaining].
        const del_end = pos + len_;
        const before_gap_end = @min(del_end, self.gap_start);
        if (pos < before_gap_end) {
            self.newline_count -= countNewlines(self.buf[pos..before_gap_end]);
        }
        if (del_end > self.gap_start) {
            const after_start = self.gap_end + (if (pos > self.gap_start) pos - self.gap_start else 0);
            const after_end = self.gap_end + (del_end - self.gap_start);
            self.newline_count -= countNewlines(self.buf[after_start..after_end]);
        }

        self.moveGapTo(pos);
        self.gap_end += len_;
        self.len -= len_;
    }

    pub fn charAt(self: *const TextBuffer, pos: usize) u8 {
        if (pos >= self.len) return 0;
        if (pos < self.gap_start) return self.buf[pos];
        return self.buf[pos + self.gapSize()];
    }

    pub fn slice(self: *const TextBuffer, start: usize, end: usize) ![]u8 {
        if (start > end or end > self.len) return error.OutOfBounds;
        const gap = self.gapSize();
        const out = try self.allocator.alloc(u8, end - start);
        if (end <= self.gap_start) {
            @memcpy(out, self.buf[start..end]);
        } else if (start >= self.gap_start) {
            @memcpy(out, self.buf[start + gap .. end + gap]);
        } else {
            const left = self.gap_start - start;
            const right = end - self.gap_start;
            @memcpy(out[0..left], self.buf[start..self.gap_start]);
            @memcpy(out[left..], self.buf[self.gap_end..self.gap_end + right]);
        }
        return out;
    }

    pub fn lineCount(self: *const TextBuffer) usize {
        if (self.len == 0) return 0;
        return self.newline_count + 1;
    }

    pub fn lineStart(self: *const TextBuffer, line: usize) usize {
        if (line == 0) return 0;
        var current_line: usize = 0;
        // Scan the region before the gap (logical 0..gap_start → raw 0..gap_start).
        var i: usize = 0;
        while (i < self.gap_start and i < self.len) : (i += 1) {
            if (self.buf[i] == '\n') {
                current_line += 1;
                if (current_line == line) return i + 1;
            }
        }
        // Continue past the gap (logical gap_start..len → raw gap_end..gap_end+remaining).
        var raw = self.gap_end;
        const raw_end = self.gap_end + (self.len - self.gap_start);
        var log_pos = self.gap_start;
        while (raw < raw_end) : (raw += 1) {
            if (self.buf[raw] == '\n') {
                current_line += 1;
                if (current_line == line) return log_pos + 1;
            }
            log_pos += 1;
        }
        return self.len;
    }

    pub fn lineLength(self: *const TextBuffer, line: usize) usize {
        const start = self.lineStart(line);
        var len: usize = 0;
        // Scan before gap.
        if (start < self.gap_start) {
            var i = start;
            while (i < self.gap_start and self.buf[i] != '\n') : (i += 1) {
                len += 1;
            }
            if (i < self.gap_start) return len; // found newline before gap
        }
        // Continue after gap.
        const raw_start = if (start >= self.gap_start) self.gap_end + (start - self.gap_start) else self.gap_end;
        var raw = raw_start;
        const raw_end = self.gap_end + (self.len - self.gap_start);
        while (raw < raw_end and self.buf[raw] != '\n') : (raw += 1) {
            len += 1;
        }
        return len;
    }

    pub fn utf8Slice(self: *const TextBuffer, start: usize, end: usize) ![]const u8 {
        return try self.slice(start, end);
    }

    pub fn utf8Len(self: *const TextBuffer) usize {
        return self.len;
    }
};


test "buffer: large insert grows beyond a single doubling" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    const payload = try std.testing.allocator.alloc(u8, TextBuffer.DefaultCapacity * 5 + 123);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try buffer.insert(0, payload);
    try std.testing.expectEqual(payload.len, buffer.size());
    try std.testing.expectEqual(@as(u8, 'x'), buffer.charAt(payload.len - 1));
}

test "buffer: growth preserves both sides of the gap" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insert(0, "prefix-");
    try buffer.insert(buffer.size(), "suffix");
    try buffer.insert(7, "middle-");

    const text = try buffer.slice(0, buffer.size());
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("prefix-middle-suffix", text);
}
