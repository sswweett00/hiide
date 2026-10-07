const std = @import("std");
const compat = @import("../compat.zig");
const buffer_mod = @import("buffer.zig");
const highlighter_mod = @import("highlighter.zig");
const testing = std.testing;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: buffer_mod.TextBuffer,
    undo_stack: compat.ManagedArrayList(UndoEntry),
    redo_stack: compat.ManagedArrayList(UndoEntry),
    cursor_pos: usize,
    selection_start: usize,
    selection_end: usize,

    pub const UndoEntry = struct {
        kind: enum { insert, delete },
        pos: usize,
        text: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) !Editor {
        return .{
            .allocator = allocator,
            .buffer = try buffer_mod.TextBuffer.init(allocator),
            .undo_stack = compat.ManagedArrayList(UndoEntry).init(allocator),
            .redo_stack = compat.ManagedArrayList(UndoEntry).init(allocator),
            .cursor_pos = 0,
            .selection_start = 0,
            .selection_end = 0,
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.undo_stack.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.undo_stack.deinit();
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.text);
        }
        self.redo_stack.deinit();
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn load(self: *Editor, text: []const u8) !void {
        try self.buffer.insert(0, text);
        self.cursor_pos = self.buffer.size();
        self.selection_start = self.cursor_pos;
        self.selection_end = self.cursor_pos;
    }

    pub fn size(self: *const Editor) usize {
        return self.buffer.size();
    }

    pub fn lineCount(self: *const Editor) usize {
        return self.buffer.lineCount();
    }

    pub fn cursorLine(self: *const Editor) usize {
        var line: usize = 0;
        var i: usize = 0;
        while (i < self.cursor_pos and i < self.buffer.size()) : (i += 1) {
            if (self.buffer.charAt(i) == '\n') line += 1;
        }
        return line;
    }

    pub fn cursorCol(self: *const Editor) usize {
        var col: usize = 0;
        var i = self.cursor_pos;
        while (i > 0) : (i -= 1) {
            if (self.buffer.charAt(i - 1) == '\n') break;
            col += 1;
        }
        return col + 1;
    }

    pub fn insertText(self: *Editor, pos: usize, text: []const u8) !void {
        if (pos > self.buffer.size()) return error.OutOfBounds;
        try self.buffer.insert(pos, text);
        self.cursor_pos = pos + text.len;

        const entry = UndoEntry{
            .kind = .delete,
            .pos = pos,
            .text = try self.allocator.dupe(u8, text),
        };
        try self.undo_stack.append(entry);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn deleteRange(self: *Editor, pos: usize, len_: usize) !void {
        if (pos > self.buffer.size() or len_ > self.buffer.size() - pos) return error.OutOfBounds;
        if (len_ == 0) return;

        const deleted = try self.buffer.slice(pos, pos + len_);
        defer self.allocator.free(deleted);

        try self.buffer.delete(pos, len_);
        self.cursor_pos = pos;

        // The undo entry must own its own copy: `deleted` is freed by the
        // defer above, and `deinit` frees every entry text again — aliasing
        // would double-free.
        const entry = UndoEntry{
            .kind = .insert,
            .pos = pos,
            .text = try self.allocator.dupe(u8, deleted),
        };
        try self.undo_stack.append(entry);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop();
        switch (entry.kind) {
            .insert => {
                try self.buffer.insert(entry.pos, entry.text);
                self.cursor_pos = entry.pos + entry.text.len;
                const redo_entry = UndoEntry{
                    .kind = .delete,
                    .pos = entry.pos,
                    .text = try self.allocator.dupe(u8, entry.text),
                };
                try self.redo_stack.append(redo_entry);
            },
            .delete => {
                try self.buffer.delete(entry.pos, entry.text.len);
                self.cursor_pos = entry.pos;
                const redo_entry = UndoEntry{
                    .kind = .insert,
                    .pos = entry.pos,
                    .text = try self.allocator.dupe(u8, entry.text),
                };
                try self.redo_stack.append(redo_entry);
            },
        }
        self.allocator.free(entry.text);
    }

    pub fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;
        const entry = self.redo_stack.pop();
        switch (entry.kind) {
            .insert => {
                try self.buffer.insert(entry.pos, entry.text);
                self.cursor_pos = entry.pos + entry.text.len;
                const undo_entry = UndoEntry{
                    .kind = .delete,
                    .pos = entry.pos,
                    .text = try self.allocator.dupe(u8, entry.text),
                };
                try self.undo_stack.append(undo_entry);
            },
            .delete => {
                try self.buffer.delete(entry.pos, entry.text.len);
                self.cursor_pos = entry.pos;
                const undo_entry = UndoEntry{
                    .kind = .insert,
                    .pos = entry.pos,
                    .text = try self.allocator.dupe(u8, entry.text),
                };
                try self.undo_stack.append(undo_entry);
            },
        }
        self.allocator.free(entry.text);
    }

    pub fn getText(self: *const Editor) ![]u8 {
        return try self.buffer.slice(0, self.buffer.size());
    }

    pub fn getLine(self: *const Editor, line: usize) ![]u8 {
        const start = self.buffer.lineStart(line);
        const len = self.buffer.lineLength(line);
        return try self.buffer.slice(start, start + len);
    }

    pub fn getHighlighted(self: *Editor, allocator: std.mem.Allocator, lang: []const u8) ![]u8 {
        return try highlighter_mod.highlight(allocator, &self.buffer, lang);
    }

    pub fn search(self: *const Editor, allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
        if (query.len == 0) return try allocator.alloc(SearchResult, 0);
        var results = compat.ManagedArrayList(SearchResult).init(allocator);
        errdefer results.deinit();

        const text = try self.buffer.slice(0, self.buffer.size());
        defer allocator.free(text);

        // Use the standard substring search primitive instead of testing
        // every byte with startsWith. This keeps the search loop linear in the
        // input size for typical workloads while preserving non-overlapping
        // match semantics and incremental line/column tracking.
        var line: usize = 1;
        var col: usize = 1;
        var search_pos: usize = 0;
        while (search_pos < text.len) {
            const match_pos = std.mem.indexOfPos(u8, text, search_pos, query) orelse break;

            // Advance the line/column cursor only to the next match rather than
            // rescanning from the beginning for every result.
            var cursor = search_pos;
            while (cursor < match_pos) : (cursor += 1) {
                if (text[cursor] == '\\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }

            try results.append(.{
                .line = line,
                .col = col,
                .text = try allocator.dupe(u8, text[match_pos..][0..query.len]),
            });

            // Match positions remain non-overlapping, matching the previous
            // startsWith-based implementation.
            for (text[match_pos .. match_pos + query.len]) |c| {
                if (c == '\\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }
            search_pos = match_pos + query.len;
        }
        return results.toOwnedSlice();
    }

    pub const SearchResult = struct {
        line: usize,
        col: usize,
        text: []u8,
    };
};

test "editor: empty search is a safe zero-result operation" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.load("hello world");
    const results = try ed.search(std.testing.allocator, "");
    defer std.testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "editor: search preserves line and column across non-overlapping matches" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.load("alpha\\nneedle x needle\\nomega");
    const results = try ed.search(std.testing.allocator, "needle");
    defer {
        for (results) |result| std.testing.allocator.free(result.text);
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(usize, 2), results[0].line);
    try std.testing.expectEqual(@as(usize, 1), results[0].col);
    try std.testing.expectEqual(@as(usize, 2), results[1].line);
    try std.testing.expectEqual(@as(usize, 10), results[1].col);
}

test "editor: insert/delete/undo/redo lifecycle does not double-free" {
    var ed = try Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.load("hello world");
    try ed.insertText(5, " XYZ");
    try ed.deleteRange(5, 4); // pushes a delete entry whose text must be owned
    try ed.undo(); // restores "hello XYZ world"
    try ed.redo(); // back to "hello world"

    const text = try ed.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}
