/// CLI: zig build groq-chat -- [model] "your question"
/// Fast smoke-test harness for the Groq provider.
const std = @import("std");
const hiide = @import("hiide");
const compat = hiide.compat;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next(); // exe

    var model: []const u8 = hiide.provider.groq.default_model;
    var prompt: []const u8 = "Reply with exactly: hiide-ok";

    if (args.next()) |a1| {
        if (args.next()) |a2| {
            model = a1;
            prompt = a2;
        } else if (hiide.provider.groq.findModel(a1) != null) {
            model = a1;
        } else {
            prompt = a1;
        }
    }

    var client = try hiide.provider.groq.Client.init(allocator, init.io);
    defer client.deinit();

    const t0 = compat.milliTimestamp();
    var resp = try client.complete(.{
        .model = model,
        .messages = &[_]hiide.provider.groq.Message{
            .{ .role = .system, .content = hiide.provider.groq.system_prompt },
            .{ .role = .user, .content = prompt },
        },
        .temperature = 0.3,
        .max_tokens = 512,
    });
    defer resp.deinit();
    const t1 = compat.milliTimestamp();
    const ms = t1 - t0;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};
    try out.print("model={s} tokens={d} latency_ms={d}\n", .{ resp.model, resp.total_tokens, ms });
    try out.print("{s}\n", .{resp.content});
}
