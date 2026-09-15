/// Versioned prompt template registry with deterministic rendering.
///
/// Prompt text is treated as governed configuration, not inline literals:
/// every template has a stable id (matching `AgentTask.prompt_template_id`), a
/// version, and a content digest that is written into the audit ledger so a
/// completed run can be reproduced byte-for-byte.
const std = @import("std");
const agent_types = @import("../types.zig");

pub const PromptError = error{
    TemplateNotFound,
    TemplateMalformed,
    MissingPromptVariable,
    TemplateTooLarge,
    DuplicateTemplate,
    OutOfMemory,
};

pub const Var = struct {
    key: []const u8,
    value: []const u8,
};

pub const Template = struct {
    id: u32,
    name: []const u8,
    version: u16,
    /// Agent kind this template is authored for; null for shared fragments.
    kind: ?agent_types.AgentKind,
    text: []const u8,

    /// SHA-256 digest of the template body, used for audit reproducibility.
    /// @example
    /// const digest = template.digest();
    pub fn digest(self: Template) [32]u8 {
        var out: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(self.name);
        hasher.update(std.mem.asBytes(&self.version));
        hasher.update(self.text);
        hasher.final(&out);
        return out;
    }
};

/// Upper bound on a rendered prompt so a runaway substitution cannot exhaust
/// the task arena.
pub const MAX_RENDER_BYTES: usize = 1 << 20;

/// Renders `text`, substituting `{{key}}` placeholders from `vars`.
/// Unknown placeholders fail loudly instead of silently emitting empty strings.
/// Caller owns the returned buffer.
/// @example
/// const out = try renderText(alloc, "Fix {{file}}", &.{.{ .key = "file", .value = "main.zig" }});
pub fn renderText(
    alloc: std.mem.Allocator,
    text: []const u8,
    vars: []const Var,
) PromptError![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "}}") orelse
                return PromptError.TemplateMalformed;
            const key = std.mem.trim(u8, text[i + 2 .. close], " \t");
            if (key.len == 0) return PromptError.TemplateMalformed;

            const value = lookup(vars, key) orelse return PromptError.MissingPromptVariable;
            if (out.items.len + value.len > MAX_RENDER_BYTES) return PromptError.TemplateTooLarge;
            try out.appendSlice(alloc, value);
            i = close + 2;
            continue;
        }
        if (out.items.len + 1 > MAX_RENDER_BYTES) return PromptError.TemplateTooLarge;
        try out.append(alloc, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn lookup(vars: []const Var, key: []const u8) ?[]const u8 {
    for (vars) |v| {
        if (std.mem.eql(u8, v.key, key)) return v.value;
    }
    return null;
}

/// Registry of templates addressable by id or name.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    templates: std.ArrayListUnmanaged(Template) = .empty,

    /// Creates an empty registry.
    /// @example
    /// var prompts = Registry.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.templates.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a template; ids must be unique.
    /// @example
    /// try prompts.register(.{ .id = 100, .name = "coder.patch", .version = 1, .kind = .coder, .text = body });
    pub fn register(self: *Registry, template: Template) PromptError!void {
        for (self.templates.items) |existing| {
            if (existing.id == template.id) return PromptError.DuplicateTemplate;
        }
        try self.templates.append(self.allocator, template);
    }

    /// Loads the built-in template set covering all eight agent kinds.
    /// @example
    /// try prompts.loadBuiltins();
    pub fn loadBuiltins(self: *Registry) PromptError!void {
        for (BUILTINS) |t| {
            self.register(t) catch |err| switch (err) {
                PromptError.DuplicateTemplate => {},
                else => return err,
            };
        }
    }

    /// Returns the template with `id`, or null.
    /// @example
    /// const t = prompts.get(builtin_id.coder) orelse return error.TemplateNotFound;
    pub fn get(self: *const Registry, id: u32) ?Template {
        for (self.templates.items) |t| {
            if (t.id == id) return t;
        }
        return null;
    }

    /// Returns the highest-version template registered for `name`.
    /// @example
    /// const t = prompts.getByName("coder.patch");
    pub fn getByName(self: *const Registry, name: []const u8) ?Template {
        var best: ?Template = null;
        for (self.templates.items) |t| {
            if (!std.mem.eql(u8, t.name, name)) continue;
            if (best == null or t.version > best.?.version) best = t;
        }
        return best;
    }

    /// Returns the default template for an agent kind.
    /// @example
    /// const t = prompts.forKind(.reviewer);
    pub fn forKind(self: *const Registry, kind: agent_types.AgentKind) ?Template {
        var best: ?Template = null;
        for (self.templates.items) |t| {
            if (t.kind != kind) continue;
            if (best == null or t.version > best.?.version) best = t;
        }
        return best;
    }

    /// Renders template `id` with `vars`. Caller owns the returned buffer.
    /// @example
    /// const prompt = try prompts.render(alloc, 100, vars);
    pub fn render(
        self: *const Registry,
        alloc: std.mem.Allocator,
        id: u32,
        vars: []const Var,
    ) PromptError![]u8 {
        const template = self.get(id) orelse return PromptError.TemplateNotFound;
        return renderText(alloc, template.text, vars);
    }

    /// Digest of template `id` for the audit ledger.
    /// @example
    /// const d = try prompts.digestOf(100);
    pub fn digestOf(self: *const Registry, id: u32) PromptError![32]u8 {
        const template = self.get(id) orelse return PromptError.TemplateNotFound;
        return template.digest();
    }

    pub fn count(self: *const Registry) usize {
        return self.templates.items.len;
    }
};

/// Stable ids for the built-in templates.
pub const builtin_id = struct {
    pub const planner: u32 = 1;
    pub const coder: u32 = 2;
    pub const reviewer: u32 = 3;
    pub const tester: u32 = 4;
    pub const researcher: u32 = 5;
    pub const security_auditor: u32 = 6;
    pub const documentation_writer: u32 = 7;
    pub const refactor_specialist: u32 = 8;
};

/// Built-in prompts deliberately reference structured working-memory handles
/// rather than chat transcripts, matching the data-flow contract in spec §1.3.
pub const BUILTINS = [_]Template{
    .{
        .id = builtin_id.planner,
        .name = "planner.decompose",
        .version = 1,
        .kind = .planner,
        .text =
        \\ROLE: Planner agent for the hiide engine.
        \\OBJECTIVE: {{objective}}
        \\WORKSPACE: {{workspace}}
        \\SYMBOL_SNAPSHOT: {{symbol_snapshot}}
        \\TOKEN_BUDGET: soft={{soft_limit}} hard={{hard_limit}}
        \\
        \\Emit a dependency-ordered task graph. Every node must declare its agent
        \\kind, execution mode, side-effect class, and approval requirement.
        \\Never emit a cycle. Prefer the smallest plan that satisfies the objective.
        ,
    },
    .{
        .id = builtin_id.coder,
        .name = "coder.patch",
        .version = 1,
        .kind = .coder,
        .text =
        \\ROLE: Coder agent.
        \\TASK: {{task}}
        \\TARGET_FILE: {{file}}
        \\DIAGNOSTICS: {{diagnostics}}
        \\CONSTRAINTS: {{constraints}}
        \\
        \\Produce a minimal patch candidate as a unified diff. Do not touch files
        \\outside the declared target set. Reference symbols by id, not by prose.
        ,
    },
    .{
        .id = builtin_id.reviewer,
        .name = "reviewer.critique",
        .version = 1,
        .kind = .reviewer,
        .text =
        \\ROLE: Reviewer agent.
        \\PATCH: {{patch}}
        \\STANDARDS: {{standards}}
        \\
        \\Return a verdict of accept, revise, or reject with a confidence score and
        \\a machine-checkable list of findings keyed by file and line.
        ,
    },
    .{
        .id = builtin_id.tester,
        .name = "tester.verify",
        .version = 1,
        .kind = .tester,
        .text =
        \\ROLE: Tester agent.
        \\PATCH: {{patch}}
        \\TEST_COMMAND: {{test_command}}
        \\
        \\Generate or select the smallest test set that proves the change and
        \\report a structured test artifact, never free-form prose.
        ,
    },
    .{
        .id = builtin_id.researcher,
        .name = "researcher.gather",
        .version = 1,
        .kind = .researcher,
        .text =
        \\ROLE: Researcher agent.
        \\QUESTION: {{question}}
        \\INDEX_SCOPE: {{scope}}
        \\
        \\Answer strictly from the semantic index and cite symbol ids. If the index
        \\lacks the answer, say so instead of speculating.
        ,
    },
    .{
        .id = builtin_id.security_auditor,
        .name = "security.audit",
        .version = 1,
        .kind = .security_auditor,
        .text =
        \\ROLE: Security auditor agent.
        \\CHANGE_SET: {{change_set}}
        \\POLICY_SNAPSHOT: {{policy_snapshot}}
        \\
        \\Flag secret exposure, unsafe egress, dependency risk, and privilege
        \\escalation. Every finding requires a severity and a policy rule id.
        ,
    },
    .{
        .id = builtin_id.documentation_writer,
        .name = "docs.write",
        .version = 1,
        .kind = .documentation_writer,
        .text =
        \\ROLE: Documentation writer agent.
        \\CHANGE_SET: {{change_set}}
        \\AUDIENCE: {{audience}}
        \\
        \\Document observable behaviour only. Never invent APIs that are absent
        \\from the symbol snapshot.
        ,
    },
    .{
        .id = builtin_id.refactor_specialist,
        .name = "refactor.plan",
        .version = 1,
        .kind = .refactor_specialist,
        .text =
        \\ROLE: Refactor specialist agent.
        \\SCOPE: {{scope}}
        \\INVARIANTS: {{invariants}}
        \\
        \\Preserve behaviour. Emit mechanical, reviewable steps with the call graph
        \\edges that each step invalidates.
        ,
    },
};

test "prompt: renders placeholders" {
    const out = try renderText(std.testing.allocator, "fix {{file}} at {{line}}", &.{
        .{ .key = "file", .value = "main.zig" },
        .{ .key = "line", .value = "42" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fix main.zig at 42", out);
}

test "prompt: missing variable and malformed template fail loudly" {
    try std.testing.expectError(
        PromptError.MissingPromptVariable,
        renderText(std.testing.allocator, "hello {{name}}", &.{}),
    );
    try std.testing.expectError(
        PromptError.TemplateMalformed,
        renderText(std.testing.allocator, "hello {{name", &.{}),
    );
    try std.testing.expectError(
        PromptError.TemplateMalformed,
        renderText(std.testing.allocator, "hello {{}}", &.{}),
    );
}

test "prompt: whitespace inside placeholders is tolerated" {
    const out = try renderText(std.testing.allocator, "{{ file }}", &.{
        .{ .key = "file", .value = "a.zig" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a.zig", out);
}

test "prompt: registry resolves builtins by id, name, and kind" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadBuiltins();

    try std.testing.expectEqual(BUILTINS.len, registry.count());
    try std.testing.expect(registry.get(builtin_id.coder) != null);
    try std.testing.expectEqualStrings("coder.patch", registry.getByName("coder.patch").?.name);
    try std.testing.expectEqual(builtin_id.security_auditor, registry.forKind(.security_auditor).?.id);
    try std.testing.expectError(PromptError.TemplateNotFound, registry.render(std.testing.allocator, 9999, &.{}));
}

test "prompt: duplicate ids are rejected and loadBuiltins is idempotent" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadBuiltins();
    try registry.loadBuiltins();
    try std.testing.expectEqual(BUILTINS.len, registry.count());

    try std.testing.expectError(PromptError.DuplicateTemplate, registry.register(BUILTINS[0]));
}

test "prompt: digest is stable and version-sensitive" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadBuiltins();

    const a = try registry.digestOf(builtin_id.planner);
    const b = try registry.digestOf(builtin_id.planner);
    try std.testing.expectEqualSlices(u8, &a, &b);

    var bumped = BUILTINS[0];
    bumped.version = 2;
    try std.testing.expect(!std.mem.eql(u8, &a, &bumped.digest()));
}

test "prompt: rendering a builtin produces a complete prompt" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadBuiltins();

    const out = try registry.render(std.testing.allocator, builtin_id.planner, &.{
        .{ .key = "objective", .value = "add rate limiting" },
        .{ .key = "workspace", .value = "/repo" },
        .{ .key = "symbol_snapshot", .value = "42" },
        .{ .key = "soft_limit", .value = "16000" },
        .{ .key = "hard_limit", .value = "24000" },
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "add rate limiting"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "{{"));
}
