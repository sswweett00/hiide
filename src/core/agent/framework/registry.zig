/// Runtime agent registry: descriptor-addressed factories with versioning.
///
/// The comptime `types.AgentRegistry` covers statically linked agents; this
/// registry covers the dynamic case — plugin-provided agents (spec §5) and
/// per-tenant overrides that are only known at runtime.
const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("../types.zig");
const agent_mod = @import("agent.zig");

pub const RegistryError = error{
    AgentNotRegistered,
    AgentAlreadyRegistered,
    OutOfMemory,
};

/// Creates agent instances on demand. Stateless agents can be registered as
/// singletons; stateful ones get a fresh instance per task node.
pub const Factory = struct {
    descriptor: agent_mod.AgentDescriptor,
    ctx: *anyopaque,
    /// Owner id ("core" or a plugin id) used for bulk teardown.
    owner: []const u8 = "core",
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, std.mem.Allocator) anyerror!agent_mod.Agent,
        destroy: ?*const fn (*anyopaque, std.mem.Allocator, agent_mod.Agent) void = null,
    };

    /// Instantiates an agent.
    /// @example
    /// const agent = try factory.create(alloc);
    pub fn create(self: Factory, alloc: std.mem.Allocator) anyerror!agent_mod.Agent {
        return self.vtable.create(self.ctx, alloc);
    }

    /// Releases an instance produced by `create`.
    /// @example
    /// factory.destroy(alloc, agent);
    pub fn destroy(self: Factory, alloc: std.mem.Allocator, instance: agent_mod.Agent) void {
        if (self.vtable.destroy) |f| {
            f(self.ctx, alloc, instance);
        } else {
            instance.deinit(alloc);
        }
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    factories: std.ArrayListUnmanaged(Factory) = .empty,

    /// Creates an empty registry.
    /// @example
    /// var agents = Registry.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.factories.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a factory. Descriptor ids are unique.
    /// @example
    /// try agents.register(coder_factory);
    pub fn register(self: *Registry, factory: Factory) RegistryError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.factories.items) |existing| {
            if (std.mem.eql(u8, existing.descriptor.id, factory.descriptor.id)) {
                return RegistryError.AgentAlreadyRegistered;
            }
        }
        try self.factories.append(self.allocator, factory);
    }

    /// Registers a shared, already-constructed agent instance.
    /// The instance must be `concurrency_safe` because every task node that
    /// resolves this descriptor receives the same pointer.
    /// @example
    /// try agents.registerSingleton(&holder, planner_agent);
    pub fn registerSingleton(
        self: *Registry,
        holder: *SingletonHolder,
        instance: agent_mod.Agent,
    ) RegistryError!void {
        holder.* = .{ .instance = instance };
        try self.register(.{
            .descriptor = instance.descriptor,
            .ctx = holder,
            .vtable = &SingletonHolder.vtable,
        });
    }

    /// Removes a factory by descriptor id.
    /// @example
    /// try agents.unregister("core.coder.v1");
    pub fn unregister(self: *Registry, id: []const u8) RegistryError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.factories.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.descriptor.id, id)) {
                _ = self.factories.orderedRemove(i);
                return;
            }
        }
        return RegistryError.AgentNotRegistered;
    }

    /// Removes every factory contributed by `owner` (plugin unload).
    /// @example
    /// const removed = agents.unregisterOwner("acme.agents");
    pub fn unregisterOwner(self: *Registry, owner: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.factories.items.len) {
            if (std.mem.eql(u8, self.factories.items[i].owner, owner)) {
                _ = self.factories.orderedRemove(i);
                removed += 1;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    /// Looks a factory up by descriptor id.
    /// @example
    /// const f = agents.byId("core.coder.v1") orelse return error.AgentNotRegistered;
    pub fn byId(self: *Registry, id: []const u8) ?Factory {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.factories.items) |factory| {
            if (std.mem.eql(u8, factory.descriptor.id, id)) return factory;
        }
        return null;
    }

    /// Resolves the highest-version factory registered for `kind`.
    /// @example
    /// const f = agents.byKind(.reviewer) orelse return error.AgentNotRegistered;
    pub fn byKind(self: *Registry, kind: types.AgentKind) ?Factory {
        self.mutex.lock();
        defer self.mutex.unlock();

        var best: ?Factory = null;
        for (self.factories.items) |factory| {
            if (factory.descriptor.kind != kind) continue;
            if (best == null or factory.descriptor.version > best.?.descriptor.version) {
                best = factory;
            }
        }
        return best;
    }

    /// Creates an instance for `kind`.
    /// @example
    /// const agent = try agents.create(alloc, .coder);
    pub fn create(
        self: *Registry,
        alloc: std.mem.Allocator,
        kind: types.AgentKind,
    ) anyerror!agent_mod.Agent {
        const factory = self.byKind(kind) orelse return RegistryError.AgentNotRegistered;
        return factory.create(alloc);
    }

    /// Creates an instance for a specific descriptor id.
    /// @example
    /// const agent = try agents.createById(alloc, "core.coder.v1");
    pub fn createById(
        self: *Registry,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) anyerror!agent_mod.Agent {
        const factory = self.byId(id) orelse return RegistryError.AgentNotRegistered;
        return factory.create(alloc);
    }

    /// True when at least one factory serves `kind`.
    /// @example
    /// if (!agents.has(.tester)) return error.AgentNotRegistered;
    pub fn has(self: *Registry, kind: types.AgentKind) bool {
        return self.byKind(kind) != null;
    }

    /// Copies every registered descriptor. Caller owns the slice.
    /// @example
    /// const all = try agents.listDescriptors(alloc);
    pub fn listDescriptors(
        self: *Registry,
        alloc: std.mem.Allocator,
    ) ![]agent_mod.AgentDescriptor {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = try alloc.alloc(agent_mod.AgentDescriptor, self.factories.items.len);
        for (self.factories.items, 0..) |factory, i| out[i] = factory.descriptor;
        return out;
    }

    pub fn count(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.factories.items.len;
    }
};

/// Storage for a shared agent instance registered via `registerSingleton`.
pub const SingletonHolder = struct {
    instance: agent_mod.Agent,

    fn create(ptr: *anyopaque, _: std.mem.Allocator) anyerror!agent_mod.Agent {
        const self: *SingletonHolder = @ptrCast(@alignCast(ptr));
        return self.instance;
    }

    fn destroy(_: *anyopaque, _: std.mem.Allocator, _: agent_mod.Agent) void {
        // Singleton lifetime is owned by the caller.
    }

    const vtable = Factory.VTable{ .create = create, .destroy = destroy };
};

/// Builds a factory that constructs `T` per task node.
/// `T` must expose `pub fn run(*T, *AgentContext)` and may expose
/// `pub fn init(alloc) !T` and `pub fn deinit(*T, alloc)`.
/// The descriptor is comptime because the factory carries no storage; use
/// `TypedFactory` when the descriptor is only known at runtime.
/// @example
/// try registry.register(factoryFor(CoderAgent, .{ .id = "core.coder.v1", .kind = .coder }));
pub fn factoryFor(comptime T: type, comptime descriptor: agent_mod.AgentDescriptor) Factory {
    const Shim = struct {
        fn create(_: *anyopaque, alloc: std.mem.Allocator) anyerror!agent_mod.Agent {
            const instance = try alloc.create(T);
            instance.* = if (@hasDecl(T, "init")) try T.init(alloc) else T{};
            return agent_mod.fromImpl(T, instance, descriptor);
        }

        fn destroy(_: *anyopaque, alloc: std.mem.Allocator, instance: agent_mod.Agent) void {
            const typed: *T = @ptrCast(@alignCast(instance.ctx));
            if (@hasDecl(T, "deinit")) T.deinit(typed, alloc);
            alloc.destroy(typed);
        }

        const vtable = Factory.VTable{ .create = create, .destroy = destroy };
    };

    return .{
        .descriptor = descriptor,
        .ctx = @constCast(@ptrCast(&Shim.vtable)),
        .vtable = &Shim.vtable,
    };
}

/// Caller-owned factory for runtime-built descriptors (plugins, tenant
/// overrides). Keep the value alive for as long as it stays registered.
/// @example
/// var tf = TypedFactory(CoderAgent){ .descriptor = descriptor };
/// try registry.register(tf.factory());
pub fn TypedFactory(comptime T: type) type {
    return struct {
        const Self = @This();

        descriptor: agent_mod.AgentDescriptor,
        owner: []const u8 = "core",

        fn create(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!agent_mod.Agent {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const instance = try alloc.create(T);
            instance.* = if (@hasDecl(T, "init")) try T.init(alloc) else T{};
            return agent_mod.fromImpl(T, instance, self.descriptor);
        }

        fn destroy(_: *anyopaque, alloc: std.mem.Allocator, instance: agent_mod.Agent) void {
            const typed: *T = @ptrCast(@alignCast(instance.ctx));
            if (@hasDecl(T, "deinit")) T.deinit(typed, alloc);
            alloc.destroy(typed);
        }

        const vtable = Factory.VTable{ .create = create, .destroy = destroy };

        /// Returns the erased factory handle.
        /// @example
        /// try registry.register(tf.factory());
        pub fn factory(self: *Self) Factory {
            return .{
                .descriptor = self.descriptor,
                .ctx = self,
                .owner = self.owner,
                .vtable = &vtable,
            };
        }
    };
}

// ─── tests ───────────────────────────────────────────────────────────────────

const NoopAgent = struct {
    runs: u32 = 0,

    pub fn init(_: std.mem.Allocator) !NoopAgent {
        return .{};
    }

    pub fn run(self: *NoopAgent, _: *agent_mod.AgentContext) anyerror!agent_mod.AgentOutput {
        self.runs += 1;
        return agent_mod.AgentOutput.fromSummary("noop", 100);
    }
};

test "registry: register, resolve by kind and id, reject duplicates" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = agent_mod.AgentDescriptor{ .id = "core.coder.v1", .kind = .coder };
    try registry.register(factoryFor(NoopAgent, descriptor));
    try std.testing.expectError(
        RegistryError.AgentAlreadyRegistered,
        registry.register(factoryFor(NoopAgent, descriptor)),
    );

    try std.testing.expect(registry.has(.coder));
    try std.testing.expect(!registry.has(.tester));
    try std.testing.expectEqualStrings("core.coder.v1", registry.byId("core.coder.v1").?.descriptor.id);
    try std.testing.expectEqual(@as(?Factory, null), registry.byId("nope"));
}

test "registry: highest version wins for a kind" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(factoryFor(NoopAgent, .{ .id = "core.coder.v1", .kind = .coder, .version = 1 }));
    try registry.register(factoryFor(NoopAgent, .{ .id = "core.coder.v2", .kind = .coder, .version = 2 }));

    try std.testing.expectEqualStrings("core.coder.v2", registry.byKind(.coder).?.descriptor.id);
}

test "registry: factory creates and destroys instances" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const descriptor = agent_mod.AgentDescriptor{ .id = "core.noop.v1", .kind = .researcher };
    try registry.register(factoryFor(NoopAgent, descriptor));

    const instance = try registry.create(std.testing.allocator, .researcher);
    defer registry.byKind(.researcher).?.destroy(std.testing.allocator, instance);

    try std.testing.expectEqualStrings("core.noop.v1", instance.descriptor.id);
}

test "registry: singleton instances are shared" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var impl = NoopAgent{};
    var holder: SingletonHolder = undefined;
    const instance = agent_mod.fromImpl(NoopAgent, &impl, .{ .id = "core.planner.v1", .kind = .planner });
    try registry.registerSingleton(&holder, instance);

    const a = try registry.create(std.testing.allocator, .planner);
    const b = try registry.create(std.testing.allocator, .planner);
    try std.testing.expectEqual(a.ctx, b.ctx);
}

test "registry: owner teardown removes plugin agents" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var core = factoryFor(NoopAgent, .{ .id = "core.coder.v1", .kind = .coder });
    try registry.register(core);

    var plugin_factory = factoryFor(NoopAgent, .{ .id = "acme.linter.v1", .kind = .reviewer });
    plugin_factory.owner = "acme";
    try registry.register(plugin_factory);
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const descriptors = try registry.listDescriptors(std.testing.allocator);
    defer std.testing.allocator.free(descriptors);
    try std.testing.expectEqual(@as(usize, 2), descriptors.len);

    try std.testing.expectEqual(@as(usize, 1), registry.unregisterOwner("acme"));
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectError(RegistryError.AgentNotRegistered, registry.unregister("acme.linter.v1"));
    core = undefined;
}

test "registry: creating an unregistered kind fails" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectError(
        RegistryError.AgentNotRegistered,
        registry.create(std.testing.allocator, .security_auditor),
    );
}
