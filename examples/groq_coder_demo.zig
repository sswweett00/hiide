/// Fast demo of real LLM-based coder agent using Groq.
/// Build/run with: `zig build groq-coder-demo -- "instruction"`
const std = @import("std");
const hiide = @import("hiide");

const framework = hiide.agent.framework;
const GroqCoder = framework.groq_coder.GroqCoder;
const file_tools = framework.file_tools;
const agent_mod = framework.agent;
const registry_mod = framework.registry;
const context_mod = framework.context;
const types = hiide.agent.types;
const journal_mod = hiide.agent.journal;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const out = std.io.getStdOut().writer();

    // Parse instruction from command line
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // exe
    
    const instruction = args.next() orelse "Create a Python file that adds two numbers";
    
    try out.print("Instruction: {s}\n", .{instruction});
    
    // Create a minimal agent context (bypassing full orchestrator for speed)
    var board = framework.blackboard.Blackboard.init(allocator, framework.clock.system());
    defer board.deinit();
    
    var tools = framework.tool.Registry.init(allocator);
    defer tools.deinit();
    
    // Register file tools
    try tools.register(file_tools.readFileTool());
    try tools.register(file_tools.writeFileTool());
    try tools.register(file_tools.listFilesTool());
    
    var journal = journal_mod.SideEffectJournal.init(allocator);
    defer journal.deinit();
    
    var approvals = framework.approval.Gate.init(allocator, framework.clock.system(), .auto_approve);
    defer approvals.deinit();
    
    var services = context_mod.Services{
        .allocator = allocator,
        .clock = framework.clock.system(),
        .board = &board,
        .tools = &tools,
        .journal = &journal,
        .approvals = &approvals,
        .workspace_root = ".",
    };
    
    // Create Groq coder agent
    var coder = try GroqCoder.init(allocator);
    defer coder.deinit(allocator);
    
    const descriptor = agent_mod.AgentDescriptor{
        .id = "groq-coder",
        .kind = .coder,
        .required_capabilities = .{
            .tool_use = true,
            .vision = false,
            .structured_output = false,
            .long_context = false,
            .streaming = false,
        },
    };
    
    var agent = agent_mod.fromImpl(GroqCoder, &coder, descriptor);
    
    // Create a proper task
    const task = types.AgentTask{
        .id = 1,
        .parent_id = null,
        .kind = .coder,
        .mode = .sequential,
        .state = .running,
        .budget = types.TokenBudget.defaultPlanning(),
        .memory = .{ .symbol_snapshot_id = 0, .task_graph_id = 0, .policy_snapshot_id = 0, .artifact_set_id = 0 },
        .prompt_template_id = 0,
        .rollback_journal_id = 0,
        .title = instruction,
    };
    
    var cancel_token = framework.cancel.Token.init(null);
    var budget_meter = framework.budget.Meter.init(task.budget);
    
    // Create minimal context
    var ctx = context_mod.AgentContext{
        .allocator = allocator,
        .services = &services,
        .task = task,
        .agent_id = "groq-coder",
        .kind = .coder,
        .cancel = &cancel_token,
        .budget = &budget_meter,
        .allowed_tools = &.{ "file.read", "file.write", "file.list" },
        .attempt = 0,
    };
    
    try out.print("Running Groq coder agent...\n", .{});
    
    // Run the agent
    const start = std.time.nanoTimestamp();
    const output = agent.run(&ctx) catch |err| {
        try out.print("Agent error: {}\n", .{err});
        return err;
    };
    const end = std.time.nanoTimestamp();
    const elapsed_ms = @divTrunc(end - start, std.time.ns_per_ms);
    
    try out.print("Status: {s}\n", .{@tagName(output.status)});
    try out.print("Summary: {s}\n", .{output.summary});
    try out.print("Confidence: {d}%\n", .{output.confidence});
    try out.print("Tokens: in={d} out={d}\n", .{output.tokens_in, output.tokens_out});
    try out.print("Latency: {d}ms\n", .{elapsed_ms});
    
    if (output.artifact) |handle| {
        try out.print("Artifact: id={d} version={d}\n", .{handle.id, handle.version});
    }
}
