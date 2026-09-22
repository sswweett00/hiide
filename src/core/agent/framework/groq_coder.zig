/// Real LLM-based coder agent using Groq provider.
const std = @import("std");
const compat = @import("../../compat.zig");
const agent_mod = @import("agent.zig");
const context_mod = @import("context.zig");
const provider_mod = @import("../../provider/router.zig");
const groq_mod = @import("../../provider/groq.zig");

pub const GroqCoder = struct {
    allocator: std.mem.Allocator,
    model: []const u8 = groq_mod.default_model,
    temperature: f32 = 0.3,
    max_tokens: u32 = 4096,
    io: std.Io,
    
    /// System prompt for the coder agent
    const system_prompt = 
        \\You are an expert software engineer. You write clean, efficient code.
        \\When asked to create files, respond with the file path and content in this exact JSON format:
        \\{"path": "filename.ext", "content": "file content here"}
        \\When asked to read files, use the file.read tool.
        \\When asked to list files, use the file.list tool.
        \\Always respond with JSON when file operations are needed.
        \\Be concise and focus on the task at hand.
    ;
    
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !GroqCoder {
        return .{ .allocator = allocator, .io = io };
    }
    
    pub fn deinit(self: *GroqCoder, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
    
    pub fn run(self: *GroqCoder, ctx: *agent_mod.AgentContext) anyerror!agent_mod.AgentOutput {
        // Get the user's instruction from task title
        const instruction = ctx.task.title;
        
        // Create Groq client
        var client = try groq_mod.Client.init(self.allocator, self.io);
        defer client.deinit();
        
        // Build messages with system prompt and user instruction
        var messages = compat.ManagedArrayList(groq_mod.Message).init(self.allocator);
        defer messages.deinit();
        
        try messages.append(.{ .role = .system, .content = system_prompt });
        try messages.append(.{ .role = .user, .content = instruction });
        
        // Call Groq API
        var resp = client.complete(.{
            .model = self.model,
            .messages = messages.items,
            .temperature = self.temperature,
            .max_tokens = self.max_tokens,
        }) catch |err| {
            // If Groq API fails, return a simple error summary
            return agent_mod.AgentOutput.fromSummary(
                try std.fmt.allocPrint(self.allocator, "Groq API error: {}", .{err}),
                0
            );
        };
        defer resp.deinit();
        
        // Try to parse tool calls from the response
        const content = resp.content;
        
        // Simple pattern matching for tool calls (production would use proper JSON parsing)
        if (std.mem.indexOf(u8, content, "path")) |_| {
            // Extract JSON from markdown code blocks if present
            const json_start = std.mem.indexOf(u8, content, "{") orelse content.len;
            const json_end = std.mem.lastIndexOf(u8, content, "}") orelse content.len;
            
            if (json_end > json_start) {
                const json_content = content[json_start..(json_end + 1)];
                
                // Try to parse as file.write call
                var parsed = std.json.parseFromSlice(struct {
                    path: ?[]const u8 = null,
                    content: ?[]const u8 = null,
                }, self.allocator, json_content, .{ .ignore_unknown_fields = true }) catch {
                    // If parsing fails, just return the raw response
                    return agent_mod.AgentOutput.fromSummary(content, 80);
                };
                defer parsed.deinit();
                
                if (parsed.value.path) |path| {
                    if (parsed.value.content) |file_content| {
                        // Build the tool input JSON using the parsed values
                        const WriteInput = struct {
                            path: []const u8,
                            content: []const u8,
                        };
                        
                        const write_input = WriteInput{ .path = path, .content = file_content };
                        var output_json = compat.ManagedArrayList(u8).init(self.allocator);
                        defer output_json.deinit();
                        
                        const bytes = try compat.jsonStringifyAlloc(self.allocator, write_input, .{});
                        defer self.allocator.free(bytes);
                        try output_json.appendSlice(bytes);
                        const tool_input = try output_json.toOwnedSlice();
                        defer self.allocator.free(tool_input);
                        
                        _ = try ctx.invokeTool("file.write", tool_input);
                        
                        return agent_mod.AgentOutput.fromSummary(
                            try std.fmt.allocPrint(self.allocator, "Created file: {s}", .{path}),
                            90
                        );
                    }
                }
            }
        }
        
        // If no tool call detected, return the raw response
        return agent_mod.AgentOutput.fromSummary(content, 80);
    }
};
