/// Simple fast demo of Groq-based coder agent.
/// Build/run with: `zig build simple-groq-coder -- "instruction"`
const std = @import("std");
const hiide = @import("hiide");

const groq_mod = hiide.provider.groq;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const out = std.io.getStdOut().writer();

    // Parse instruction from command line
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // exe
    
    const instruction = args.next() orelse "Create a Python file that adds two numbers";
    
    try out.print("Instruction: {s}\n", .{instruction});
    
    // Create Groq client
    var client = try groq_mod.Client.init(allocator);
    defer client.deinit();
    
    // System prompt for the coder
    const system_prompt = 
        \\You are an expert software engineer. When asked to create files, 
        \\respond with the file path and content in this exact JSON format:
        \\{"path": "filename.ext", "content": "file content here"}
        \\Be concise and focus on the task at hand.
    ;
    
    // Build messages
    var messages = std.ArrayList(groq_mod.Message).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = .system, .content = system_prompt });
    try messages.append(.{ .role = .user, .content = instruction });
    
    try out.print("Calling Groq API...\n", .{});
    
    // Call Groq API
    const start = std.time.nanoTimestamp();
    var resp = try client.complete(.{
        .model = groq_mod.default_model,
        .messages = messages.items,
        .temperature = 0.3,
        .max_tokens = 4096,
    });
    defer resp.deinit();
    const end = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end - start, std.time.ns_per_ms);
    
    try out.print("Model: {s}\n", .{resp.model});
    try out.print("Tokens: {d}\n", .{resp.total_tokens});
    try out.print("Latency: {d}ms\n", .{elapsed_ms});
    try out.print("Response:\n{s}\n", .{resp.content});
    
    // Try to parse file creation from response
    if (std.mem.indexOf(u8, resp.content, "path")) |_| {
        const json_start = std.mem.indexOf(u8, resp.content, "{") orelse resp.content.len;
        const json_end = std.mem.lastIndexOf(u8, resp.content, "}") orelse resp.content.len;
        
        if (json_end > json_start) {
            const json_content = resp.content[json_start..(json_end + 1)];
            
            var parsed = std.json.parseFromSlice(struct {
                path: ?[]const u8 = null,
                content: ?[]const u8 = null,
            }, allocator, json_content, .{ .ignore_unknown_fields = true }) catch {
                try out.print("Could not parse JSON response\n", .{});
                return;
            };
            defer parsed.deinit();
            
            if (parsed.value.path) |path| {
                if (parsed.value.content) |file_content| {
                    try out.print("\nCreating file: {s}\n", .{path});
                    
                    var file = try std.fs.cwd().createFile(path, .{});
                    defer file.close();
                    try file.writeAll(file_content);
                    
                    try out.print("File created successfully!\n", .{});
                }
            }
        }
    }
}
