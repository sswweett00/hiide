/// Tool contract, registry, and workspace sandbox.
///
/// Every externally observable action an agent can take is a `Tool`. Tools are
/// declarative about their side-effect class so the invoker (see `context.zig`)
/// can mediate them through the policy engine, the approval gate, and the
/// side-effect journal *before* execution, per spec §1.4.
///
/// This module deliberately does not import `context.zig`: tools receive a
/// narrow `ToolContext` so the dependency graph stays acyclic and tools remain
/// unit-testable in isolation.
const std = @import("std");
const compat = @import("../../compat.zig");
const journal_mod = @import("../journal.zig");
const plugin_mod = @import("../../plugin/manager.zig");
const cancel_mod = @import("cancel.zig");
const clock_mod = @import("clock.zig");

pub const ToolError = error{
    ToolNotFound,
    ToolAlreadyRegistered,
    ToolTimeout,
    ToolFailed,
    ToolInputInvalid,
    PathEscapesWorkspace,
    OutOfMemory,
};

/// Side-effect taxonomy. The ordering is significant: higher values are more
/// dangerous and drive default approval requirements.
pub const SideEffectClass = enum(u8) {
    /// No observable effect outside the task arena.
    pure = 0,
    /// Reads workspace files or the semantic index.
    workspace_read = 1,
    /// Writes inside the workspace root.
    workspace_write = 2,
    /// Sends content to a model provider (egress of workspace content).
    provider_send = 3,
    /// Writes outside the workspace root.
    external_write = 4,
    /// Arbitrary network egress.
    network_egress = 5,
    /// Executes a subprocess.
    process_exec = 6,
    /// Mutates version control state.
    vcs_mutation = 7,
    /// Installs packages / modifies the dependency graph.
    package_install = 8,
    /// Reads credentials from the vault.
    secret_access = 9,

    /// Human-in-the-loop is mandatory for these classes (spec §1.4).
    /// @example
    /// if (spec.side_effect.requiresApprovalByDefault()) try gate.request(...);
    pub fn requiresApprovalByDefault(self: SideEffectClass) bool {
        return switch (self) {
            .pure, .workspace_read, .workspace_write, .provider_send => false,
            .external_write, .network_egress, .process_exec, .vcs_mutation, .package_install, .secret_access => true,
        };
    }

    /// True when the effect must be journalled for idempotent commit/rollback.
    /// @example
    /// if (spec.side_effect.isMutating()) _ = try journal.record(...);
    pub fn isMutating(self: SideEffectClass) bool {
        return switch (self) {
            .pure, .workspace_read, .provider_send => false,
            else => true,
        };
    }

    /// Policy action name evaluated by the §3 policy engine.
    /// @example
    /// const action = side_effect.policyAction();
    pub fn policyAction(self: SideEffectClass) []const u8 {
        return switch (self) {
            .pure => "compute",
            .workspace_read => "file_read",
            .workspace_write => "file_write",
            .provider_send => "provider_send",
            .external_write => "file_write_external",
            .network_egress => "network_egress",
            .process_exec => "process_exec",
            .vcs_mutation => "vcs_mutation",
            .package_install => "package_install",
            .secret_access => "secret_access",
        };
    }

    /// Journal entry kind, or null when the effect is not journalled.
    /// @example
    /// const kind = side_effect.journalKind() orelse return;
    pub fn journalKind(self: SideEffectClass) ?journal_mod.JournalEntryKind {
        return switch (self) {
            .pure, .workspace_read, .provider_send => null,
            .workspace_write, .external_write => .file_write,
            .network_egress => .network_request,
            .process_exec => .process_exec,
            .vcs_mutation => .vcs_commit,
            .package_install => .package_install,
            .secret_access => .secret_access,
        };
    }

    /// Plugin capability a third-party tool must declare to use this class.
    /// @example
    /// const cap = side_effect.requiredCapability();
    pub fn requiredCapability(self: SideEffectClass) ?plugin_mod.Capability {
        return switch (self) {
            .pure => null,
            .workspace_read => .read_workspace,
            .workspace_write, .external_write => .write_workspace,
            .provider_send, .network_egress => .network_egress,
            .process_exec, .vcs_mutation, .package_install, .secret_access => .write_workspace,
        };
    }
};

/// Declarative tool metadata. Schemas are JSON-Schema strings so the same
/// descriptor can be shipped to providers that support structured tool use.
pub const ToolSpec = struct {
    id: []const u8,
    description: []const u8,
    side_effect: SideEffectClass,
    input_schema: []const u8 = "{\"type\":\"object\"}",
    output_schema: []const u8 = "{\"type\":\"object\"}",
    /// Wall-clock ceiling for a single invocation.
    timeout_ms: u32 = 30_000,
    /// Safe to retry after a transient failure.
    idempotent: bool = true,
    max_input_bytes: u32 = 1 << 20,
    /// Forces approval even when the side-effect class would not.
    force_approval: bool = false,
    /// Owning plugin id, or "core" for built-ins.
    owner: []const u8 = "core",

    /// Effective approval requirement for this tool.
    /// @example
    /// if (spec.needsApproval()) try gate.requestAndWait(...);
    pub fn needsApproval(self: ToolSpec) bool {
        return self.force_approval or self.side_effect.requiresApprovalByDefault();
    }
};

pub const ToolResult = struct {
    ok: bool,
    /// Payload owned by the caller-provided arena.
    output: []const u8,
    error_message: []const u8 = "",
    /// Provider tokens consumed by this tool call, if any.
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    /// Cost in microunits attributable to this call.
    microunits: u64 = 0,
    latency_ms: u32 = 0,

    /// Convenience constructor for a successful call.
    /// @example
    /// return ToolResult.success("{\"applied\":true}");
    pub fn success(output: []const u8) ToolResult {
        return .{ .ok = true, .output = output };
    }

    /// Convenience constructor for a failed call.
    /// @example
    /// return ToolResult.failure("file not found");
    pub fn failure(message: []const u8) ToolResult {
        return .{ .ok = false, .output = "", .error_message = message };
    }
};

/// Narrow execution context handed to a tool implementation.
pub const ToolContext = struct {
    /// Per-invocation arena; freed by the executor when the task node completes.
    allocator: std.mem.Allocator,
    task_id: u128,
    agent_id: []const u8,
    cancel: *cancel_mod.Token,
    clock: clock_mod.Clock,
    workspace_root: []const u8,
    /// 0 for the first attempt, incremented by the retry policy.
    attempt: u16 = 0,
    /// Journal entry reserved for this call, when the effect is mutating.
    journal_entry_id: ?u64 = null,

    /// Await-point check that tools must call in long loops.
    /// @example
    /// try ctx.checkCancel();
    pub fn checkCancel(self: *const ToolContext) cancel_mod.CancelError!void {
        return @constCast(self).cancel.check(self.clock);
    }

    /// Resolves `relative_path` inside the workspace sandbox.
    /// Caller owns the returned buffer.
    /// @example
    /// const path = try ctx.resolveWorkspacePath("src/main.zig");
    pub fn resolveWorkspacePath(self: *const ToolContext, relative_path: []const u8) ToolError![]u8 {
        return resolveInWorkspace(self.allocator, self.workspace_root, relative_path);
    }
};

/// Erased tool implementation.
pub const Tool = struct {
    spec: ToolSpec,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        invoke: *const fn (*anyopaque, *ToolContext, []const u8) anyerror!ToolResult,
        /// Optional cheap validation executed before policy mediation.
        validate: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    };

    /// Executes the tool body. Mediation happens in the caller, never here.
    /// @example
    /// const result = try tool.invoke(&tool_ctx, input);
    pub fn invoke(self: Tool, tool_ctx: *ToolContext, input: []const u8) anyerror!ToolResult {
        if (input.len > self.spec.max_input_bytes) return ToolError.ToolInputInvalid;
        if (self.vtable.validate) |validate_fn| try validate_fn(self.ctx, input);
        return self.vtable.invoke(self.ctx, tool_ctx, input);
    }
};

/// Registry of tools available to the engine, with per-agent allowlists.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    tools: std.ArrayListUnmanaged(Tool) = .empty,

    /// Creates an empty tool registry.
    /// @example
    /// var tools = Registry.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a tool; ids are unique across the process.
    /// @example
    /// try tools.register(echo_tool);
    pub fn register(self: *Registry, tool: Tool) ToolError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tools.items) |existing| {
            if (std.mem.eql(u8, existing.spec.id, tool.spec.id)) return ToolError.ToolAlreadyRegistered;
        }
        try self.tools.append(self.allocator, tool);
    }

    /// Removes a tool by id, e.g. when its owning plugin is unloaded.
    /// @example
    /// try tools.unregister("workspace.read_file");
    pub fn unregister(self: *Registry, id: []const u8) ToolError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tools.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.spec.id, id)) {
                _ = self.tools.orderedRemove(i);
                return;
            }
        }
        return ToolError.ToolNotFound;
    }

    /// Removes every tool owned by `owner` (plugin teardown).
    /// @example
    /// const removed = tools.unregisterOwner("acme.linter");
    pub fn unregisterOwner(self: *Registry, owner: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.tools.items.len) {
            if (std.mem.eql(u8, self.tools.items[i].spec.owner, owner)) {
                _ = self.tools.orderedRemove(i);
                removed += 1;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    /// Looks a tool up by id.
    /// @example
    /// const tool = tools.get("workspace.read_file") orelse return error.ToolNotFound;
    pub fn get(self: *Registry, id: []const u8) ?Tool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.spec.id, id)) return tool;
        }
        return null;
    }

    /// Copies the specs of all registered tools. Caller owns the slice.
    /// Used to advertise tool schemas to providers.
    /// @example
    /// const specs = try tools.listSpecs(alloc);
    pub fn listSpecs(self: *Registry, alloc: std.mem.Allocator) ![]ToolSpec {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = try alloc.alloc(ToolSpec, self.tools.items.len);
        for (self.tools.items, 0..) |tool, i| out[i] = tool.spec;
        return out;
    }

    pub fn count(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tools.items.len;
    }
};

/// Returns true when `id` is permitted by `allowlist`.
/// An empty allowlist means "no restriction" (the agent descriptor opts in).
/// @example
/// if (!isAllowed(descriptor.allowed_tools, "vcs.commit")) return error.CapabilityViolation;
pub fn isAllowed(allowlist: []const []const u8, id: []const u8) bool {
    if (allowlist.len == 0) return true;
    for (allowlist) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.mem.eql(u8, allowed, id)) return true;
        // Prefix wildcard: "workspace.*".
        if (std.mem.endsWith(u8, allowed, ".*")) {
            const prefix = allowed[0 .. allowed.len - 1];
            if (std.mem.startsWith(u8, id, prefix)) return true;
        }
    }
    return false;
}

/// Joins `relative_path` onto `root` and rejects any path that escapes it.
/// Absolute paths and `..` traversal are refused, matching the workspace
/// sandbox requirement in spec §1.4.
/// Caller owns the returned buffer.
/// @example
/// const path = try resolveInWorkspace(alloc, "/repo", "src/main.zig");
pub fn resolveInWorkspace(
    alloc: std.mem.Allocator,
    root: []const u8,
    relative_path: []const u8,
) ToolError![]u8 {
    if (relative_path.len == 0) return ToolError.ToolInputInvalid;
    if (std.fs.path.isAbsolute(relative_path)) return ToolError.PathEscapesWorkspace;
    if (std.mem.indexOfScalar(u8, relative_path, 0) != null) return ToolError.ToolInputInvalid;

    // Reject Windows drive-relative and UNC forms defensively on every host.
    if (relative_path.len >= 2 and relative_path[1] == ':') return ToolError.PathEscapesWorkspace;
    if (std.mem.startsWith(u8, relative_path, "\\\\")) return ToolError.PathEscapesWorkspace;

    var depth: isize = 0;
    var it = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            depth -= 1;
            if (depth < 0) return ToolError.PathEscapesWorkspace;
            continue;
        }
        depth += 1;
    }

    return std.fs.path.join(alloc, &.{ root, relative_path }) catch ToolError.OutOfMemory;
}

/// Binds a plain function to the `Tool` interface.
/// The function receives the tool context and raw input and returns a result.
/// @example
/// const tool = fromFn(.{ .id = "echo", .description = "echo", .side_effect = .pure }, echoFn);
pub fn fromFn(
    spec: ToolSpec,
    comptime invoke_fn: fn (*ToolContext, []const u8) anyerror!ToolResult,
) Tool {
    const Shim = struct {
        fn invoke(_: *anyopaque, tool_ctx: *ToolContext, input: []const u8) anyerror!ToolResult {
            return invoke_fn(tool_ctx, input);
        }
        const vtable = Tool.VTable{ .invoke = invoke };
    };
    return .{
        .spec = spec,
        .ctx = @constCast(@ptrCast(&Shim.vtable)),
        .vtable = &Shim.vtable,
    };
}

test "tool: side-effect taxonomy maps to policy, journal, and approval" {
    try std.testing.expect(!SideEffectClass.workspace_write.requiresApprovalByDefault());
    try std.testing.expect(SideEffectClass.external_write.requiresApprovalByDefault());
    try std.testing.expect(SideEffectClass.package_install.requiresApprovalByDefault());

    try std.testing.expect(SideEffectClass.vcs_mutation.isMutating());
    try std.testing.expect(!SideEffectClass.workspace_read.isMutating());

    try std.testing.expectEqualStrings("provider_send", SideEffectClass.provider_send.policyAction());
    try std.testing.expectEqual(journal_mod.JournalEntryKind.package_install, SideEffectClass.package_install.journalKind().?);
    try std.testing.expectEqual(@as(?journal_mod.JournalEntryKind, null), SideEffectClass.pure.journalKind());
    try std.testing.expectEqual(plugin_mod.Capability.read_workspace, SideEffectClass.workspace_read.requiredCapability().?);
}

test "tool: allowlist supports exact ids and prefix wildcards" {
    try std.testing.expect(isAllowed(&.{}, "anything"));
    try std.testing.expect(isAllowed(&.{"*"}, "vcs.commit"));
    try std.testing.expect(isAllowed(&.{"workspace.read_file"}, "workspace.read_file"));
    try std.testing.expect(isAllowed(&.{"workspace.*"}, "workspace.write_file"));
    try std.testing.expect(!isAllowed(&.{"workspace.*"}, "vcs.commit"));
}

test "tool: workspace sandbox rejects traversal and absolute paths" {
    const alloc = std.testing.allocator;

    const ok = try resolveInWorkspace(alloc, "/repo", "src/main.zig");
    defer alloc.free(ok);
    try std.testing.expect(std.mem.endsWith(u8, ok, "src/main.zig"));

    const nested = try resolveInWorkspace(alloc, "/repo", "src/../src/main.zig");
    defer alloc.free(nested);

    try std.testing.expectError(ToolError.PathEscapesWorkspace, resolveInWorkspace(alloc, "/repo", "../etc/passwd"));
    try std.testing.expectError(ToolError.PathEscapesWorkspace, resolveInWorkspace(alloc, "/repo", "src/../../etc/passwd"));
    try std.testing.expectError(ToolError.PathEscapesWorkspace, resolveInWorkspace(alloc, "/repo", "/etc/passwd"));
    try std.testing.expectError(ToolError.PathEscapesWorkspace, resolveInWorkspace(alloc, "/repo", "C:\\Windows"));
    try std.testing.expectError(ToolError.ToolInputInvalid, resolveInWorkspace(alloc, "/repo", ""));
}

test "tool: registry register, lookup, and owner teardown" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const Echo = struct {
        fn invoke(tool_ctx: *ToolContext, input: []const u8) anyerror!ToolResult {
            return ToolResult.success(try tool_ctx.allocator.dupe(u8, input));
        }
    };

    var spec = ToolSpec{ .id = "echo", .description = "echoes input", .side_effect = .pure };
    try registry.register(fromFn(spec, Echo.invoke));
    try std.testing.expectError(ToolError.ToolAlreadyRegistered, registry.register(fromFn(spec, Echo.invoke)));

    spec.id = "plugin.echo";
    spec.owner = "acme";
    try registry.register(fromFn(spec, Echo.invoke));
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const specs = try registry.listSpecs(std.testing.allocator);
    defer std.testing.allocator.free(specs);
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    try std.testing.expectEqual(@as(usize, 1), registry.unregisterOwner("acme"));
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectError(ToolError.ToolNotFound, registry.unregister("plugin.echo"));
}

test "tool: invocation enforces the input size ceiling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Echo = struct {
        fn invoke(tool_ctx: *ToolContext, input: []const u8) anyerror!ToolResult {
            return ToolResult.success(try tool_ctx.allocator.dupe(u8, input));
        }
    };
    const tool = fromFn(.{
        .id = "echo",
        .description = "echo",
        .side_effect = .pure,
        .max_input_bytes = 4,
    }, Echo.invoke);

    var token = cancel_mod.Token.init(null);
    var tool_ctx = ToolContext{
        .allocator = arena.allocator(),
        .task_id = 1,
        .agent_id = "test",
        .cancel = &token,
        .clock = clock_mod.system(),
        .workspace_root = ".",
    };

    const ok = try tool.invoke(&tool_ctx, "abcd");
    try std.testing.expectEqualStrings("abcd", ok.output);
    try std.testing.expectError(ToolError.ToolInputInvalid, tool.invoke(&tool_ctx, "abcde"));
}
