/// C ABI for Groq chat — used by Tauri / host shells.
const std = @import("std");
const compat = @import("../compat.zig");
const groq = @import("groq.zig");

/// One-shot chat completion.
///
/// `model` and `user_message` are UTF-8 C strings.
/// Returns a heap-allocated null-terminated assistant reply (free with hiide_string_free),
/// or null on failure.
pub export fn hiide_groq_chat(
    model: [*:0]const u8,
    user_message: [*:0]const u8,
) callconv(.C) ?[*:0]const u8 {
    const allocator = std.heap.c_allocator;

    var client = groq.Client.init(allocator) catch return null;
    defer client.deinit();

    const model_s = std.mem.span(model);
    const user_s = std.mem.span(user_message);
    if (user_s.len == 0) return null;

    const chosen = if (model_s.len > 0) model_s else groq.default_model;

    var resp = client.complete(.{
        .model = chosen,
        .messages = &[_]groq.Message{
            .{ .role = .system, .content = groq.system_prompt },
            .{ .role = .user, .content = user_s },
        },
        .temperature = 0.4,
        .max_tokens = 2048,
    }) catch return null;
    defer resp.deinit();

    const out = allocator.alloc(u8, resp.content.len + 1) catch return null;
    @memcpy(out[0..resp.content.len], resp.content);
    out[resp.content.len] = 0;
    return @ptrCast(out);
}

/// Returns a JSON array of curated models (null-terminated). Free with hiide_string_free.
pub export fn hiide_groq_models_json() callconv(.C) ?[*:0]const u8 {
    const allocator = std.heap.c_allocator;
    var list = compat.ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();
    const w = list.writer();
    w.writeAll("[") catch return null;
    for (groq.curated_models, 0..) |m, i| {
        if (i > 0) w.writeAll(",") catch return null;
        w.print(
            "{{\"id\":\"{s}\",\"label\":\"{s}\",\"ctx\":{d},\"instant\":{s}}}",
            .{
                m.id,
                m.label,
                m.context_window,
                if (m.instant) "true" else "false",
            },
        ) catch return null;
    }
    w.writeAll("]") catch return null;
    const slice = list.toOwnedSlice() catch return null;
    const out = allocator.alloc(u8, slice.len + 1) catch {
        allocator.free(slice);
        return null;
    };
    @memcpy(out[0..slice.len], slice);
    out[slice.len] = 0;
    allocator.free(slice);
    return @ptrCast(out);
}
