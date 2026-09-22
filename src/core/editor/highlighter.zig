const std = @import("std");
const compat = @import("../compat.zig");
const TextBuffer = @import("buffer.zig").TextBuffer;

pub const TokenType = enum(u8) {
    comment,
    string,
    number,
    keyword,
    builtin,
    function,
    type_,
    variable,
    operator,
    delimiter,
    heading,
    link,
    tag,
    attr_name,
    attr_value,
    selector,
    property,
    value,
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
};

pub const HighlightResult = struct {
    html: []u8,
};

const keywords = "const|var|fn|pub|return|if|else|while|for|switch|try|catch|defer|errdefer|comptime|inline|struct|enum|union|error|anyerror|anytype|void|bool|u8|u16|u32|u64|u128|i8|i16|i32|i64|i128|f16|f32|f64|f128|usize|isize|noreturn|type|null|undefined|unreachable|test|packed|extern|export|async|await|suspend|resume|break|continue|and|or|orelse|usingnamespace|nosuspend|noinline|linksection|callconv|volatile|allowzero";
const builtins = "@import|@This|@typeInfo|@field|@intCast|@floatCast|@ptrCast|@alignCast|@as|@sizeOf|@alignOf|@compileError|@compileLog|@memcpy|@memset|@min|@max|@truncate|@divExact|@divFloor|@divTrunc|@mod|@cImport|@embedFile|@hasField|@splat|@reduce|@shuffle|@bitCast|@byteSwap|@bitReverse|@clz|@ctz|@popCount|@bytesToSlice|@sliceToBytes|@enumToInt|@intToEnum|@unionToUnion|@unionToEnum|@enumToUnion";

/// Writes the opening `<span class="...">` tag for [t] directly into [out]
/// without any intermediate allocation.
fn writeSpanOpen(out: *compat.ManagedArrayList(u8), t: TokenType) !void {
    try out.appendSlice("<span class=\"");
    try out.appendSlice(switch (t) {
        .comment => "tok-comment",
        .string => "tok-string",
        .number => "tok-number",
        .keyword => "tok-keyword",
        .builtin => "tok-builtin",
        .function => "tok-function",
        .type_ => "tok-type",
        .variable => "tok-variable",
        .operator => "tok-operator",
        .delimiter => "tok-delimiter",
        .heading => "tok-heading",
        .link => "tok-link",
        .tag => "tok-tag",
        .attr_name => "tok-attrName",
        .attr_value => "tok-attrValue",
        .selector => "tok-selector",
        .property => "tok-property",
        .value => "tok-value",
    });
    try out.appendSlice("\">");
}

/// Writes escaped HTML for [text] directly into [out] (no heap allocation).
fn writeEscaped(out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice("&amp;"),
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            '"' => try out.appendSlice("&quot;"),
            else => try out.append(c),
        }
    }
}

/// Writes a complete highlighted token (span-wrapped, HTML-escaped) directly
/// into [out], avoiding the per-token heap allocation that `wrapToken` imposed.
fn writeToken(out: *compat.ManagedArrayList(u8), t: TokenType, text: []const u8) !void {
    try writeSpanOpen(out, t);
    try writeEscaped(out, text);
    try out.appendSlice("</span>");
}

pub fn highlightZig(allocator: std.mem.Allocator, buf: *TextBuffer) ![]u8 {
    const buf_len = buf.utf8Len();

    var out = compat.ManagedArrayList(u8).init(allocator);
    defer out.deinit();

    // Read chunks from the buffer directly — avoids the O(n) full-text
    // allocation that utf8Slice() imposed on every highlight call.
    var i: usize = 0;
    while (i < buf_len) {
        const remaining_len = buf_len - i;
        var chunk_buf: [4096]u8 = undefined;
        const chunk_len = @min(remaining_len, chunk_buf.len);
        var k: usize = 0;
        while (k < chunk_len) : (k += 1) {
            chunk_buf[k] = buf.charAt(i + k);
        }
        const remaining = chunk_buf[0..chunk_len];

        if (std.mem.startsWith(u8, remaining, "//")) {
            const end = std.mem.indexOfScalarPos(u8, remaining, 1, '\n') orelse remaining.len;
            try writeToken(&out, .comment, remaining[0..end]);
            i += end;
            continue;
        }

        if (std.mem.startsWith(u8, remaining, "\"") or std.mem.startsWith(u8, remaining, "\\\\")) {
            var j: usize = 1;
            while (j < remaining.len) : (j += 1) {
                if (remaining[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (remaining[j] == '"') {
                    j += 1;
                    break;
                }
            }
            try writeToken(&out, .string, remaining[0..j]);
            i += j;
            continue;
        }

        if (remaining.len >= 2 and remaining[0] == '0' and (remaining[1] == 'x' or remaining[1] == 'X')) {
            var j: usize = 2;
            while (j < remaining.len and (std.ascii.isHex(remaining[j]) or remaining[j] == '_')) : (j += 1) {}
            try writeToken(&out, .number, remaining[0..j]);
            i += j;
            continue;
        }

        if (std.ascii.isDigit(remaining[0])) {
            var j: usize = 0;
            while (j < remaining.len and (std.ascii.isDigit(remaining[j]) or remaining[j] == '.' or remaining[j] == '_' or remaining[j] == 'e' or remaining[j] == 'E' or remaining[j] == '+' or remaining[j] == '-')) : (j += 1) {}
            try writeToken(&out, .number, remaining[0..j]);
            i += j;
            continue;
        }

        if (remaining[0] == '@') {
            var j: usize = 1;
            while (j < remaining.len and (std.ascii.isAlphanumeric(remaining[j]) or remaining[j] == '_')) : (j += 1) {}
            const word = remaining[0..j];
            if (std.mem.indexOf(u8, builtins, word) != null) {
                try writeToken(&out, .builtin, word);
            } else {
                try writeEscaped(&out, word);
            }
            i += j;
            continue;
        }

        if (std.ascii.isAlphabetic(remaining[0]) or remaining[0] == '_') {
            var j: usize = 0;
            while (j < remaining.len and (std.ascii.isAlphanumeric(remaining[j]) or remaining[j] == '_')) : (j += 1) {}
            const word = remaining[0..j];

            if (std.mem.indexOf(u8, keywords, word) != null) {
                try writeToken(&out, .keyword, word);
            } else if (word.len > 0 and std.ascii.isUpper(word[0])) {
                try writeToken(&out, .type_, word);
            } else if (j < remaining.len and remaining[j] == '(') {
                try writeToken(&out, .function, word);
            } else {
                try writeToken(&out, .variable, word);
            }
            i += j;
            continue;
        }

        switch (remaining[0]) {
            '{', '}', '(', ')', '[', ']', ';', ',' => {
                try writeToken(&out, .delimiter, remaining[0..1]);
                i += 1;
            },
            '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?', ':' => {
                var j: usize = 1;
                while (j < remaining.len and std.mem.indexOf(u8, "+-*/%=!<>&|^~?:", remaining[j..][0..1]) != null) : (j += 1) {}
                try writeToken(&out, .operator, remaining[0..j]);
                i += j;
            },
            '\n' => {
                try out.append('\n');
                i += 1;
            },
            else => {
                try writeEscaped(&out, remaining[0..1]);
                i += 1;
            },
        }
    }

    return out.toOwnedSlice();
}

pub fn highlight(allocator: std.mem.Allocator, buf: *TextBuffer, lang: []const u8) ![]u8 {
    _ = lang;
    return try highlightZig(allocator, buf);
}
