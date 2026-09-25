const std = @import("std");
const Editor = @import("../editor/editor.zig").Editor;

pub const EditorHandle = *Editor;
const version_cstr: [*:0]const u8 = "0.1.0-dev";

pub export fn hiide_editor_version() callconv(.c) [*:0]const u8 {
    return version_cstr;
}

pub export fn hiide_editor_create() callconv(.c) ?EditorHandle {
    const allocator = std.heap.c_allocator;
    const editor = allocator.create(Editor) catch return null;
    editor.* = Editor.init(allocator) catch {
        allocator.destroy(editor);
        return null;
    };
    return editor;
}

pub export fn hiide_editor_destroy(handle: ?EditorHandle) callconv(.c) void {
    if (handle) |ed| {
        const allocator = std.heap.c_allocator;
        ed.deinit();
        allocator.destroy(ed);
    }
}

pub export fn hiide_editor_load(handle: ?EditorHandle, text: [*]const u8, len: usize) callconv(.c) void {
    if (handle == null) return;
    handle.?.load(text[0..len]) catch {};
}

pub export fn hiide_editor_size(handle: ?EditorHandle) callconv(.c) usize {
    if (handle == null) return 0;
    return handle.?.size();
}

pub export fn hiide_editor_line_count(handle: ?EditorHandle) callconv(.c) usize {
    if (handle == null) return 0;
    return handle.?.lineCount();
}

pub export fn hiide_editor_cursor_line(handle: ?EditorHandle) callconv(.c) usize {
    if (handle == null) return 0;
    return handle.?.cursorLine();
}

pub export fn hiide_editor_cursor_col(handle: ?EditorHandle) callconv(.c) usize {
    if (handle == null) return 0;
    return handle.?.cursorCol();
}

pub export fn hiide_editor_insert(handle: ?EditorHandle, pos: usize, text: [*]const u8, len: usize) callconv(.c) void {
    if (handle == null) return;
    handle.?.insertText(pos, text[0..len]) catch {};
}

pub export fn hiide_editor_delete(handle: ?EditorHandle, pos: usize, len: usize) callconv(.c) void {
    if (handle == null) return;
    handle.?.deleteRange(pos, len) catch {};
}

pub export fn hiide_editor_undo(handle: ?EditorHandle) callconv(.c) void {
    if (handle == null) return;
    handle.?.undo() catch {};
}

pub export fn hiide_editor_redo(handle: ?EditorHandle) callconv(.c) void {
    if (handle == null) return;
    handle.?.redo() catch {};
}

pub export fn hiide_editor_get_text(handle: ?EditorHandle) callconv(.c) ?[*:0]const u8 {
    if (handle == null) return null;
    const allocator = std.heap.c_allocator;
    const text = handle.?.getText() catch return null;
    if (text.len == 0) {
        allocator.free(text);
        const ptr = allocator.alloc(u8, 1) catch return null;
        ptr[0] = 0;
        return @ptrCast(ptr);
    }
    const ptr = allocator.realloc(text, text.len + 1) catch {
        allocator.free(text);
        return null;
    };
    ptr[text.len] = 0;
    return @ptrCast(ptr);
}

pub export fn hiide_editor_free(ptr: ?[*]u8) callconv(.c) void {
    if (ptr) |p| {
        const slice = std.mem.span(@as([*:0]u8, @ptrCast(p)));
        std.heap.c_allocator.free(slice);
    }
}

pub export fn hiide_editor_highlight(handle: ?EditorHandle, lang: [*]const u8, lang_len: usize) callconv(.c) ?[*:0]const u8 {
    if (handle == null) return null;
    const allocator = std.heap.c_allocator;
    const html = handle.?.getHighlighted(allocator, lang[0..lang_len]) catch return null;
    if (html.len == 0) {
        allocator.free(html);
        return null;
    }
    const ptr = allocator.realloc(html, html.len + 1) catch {
        allocator.free(html);
        return null;
    };
    ptr[html.len] = 0;
    return @ptrCast(ptr);
}

pub const SearchResult = extern struct {
    line: usize,
    col: usize,
    text_len: usize,
};

pub export fn hiide_editor_search(handle: ?EditorHandle, query: [*]const u8, query_len: usize, out: [*]SearchResult, max_results: usize) callconv(.c) usize {
    if (handle == null or max_results == 0) return 0;
    const allocator = std.heap.c_allocator;
    const results = handle.?.search(allocator, query[0..query_len]) catch return 0;
    defer {
        for (results) |r| allocator.free(r.text);
        allocator.free(results);
    }

    const count = @min(results.len, max_results);
    for (results[0..count], 0..) |r, i| {
        out[i] = .{
            .line = r.line,
            .col = r.col,
            .text_len = r.text.len,
        };
    }
    return count;
}
