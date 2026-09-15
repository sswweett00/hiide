/// Observability and cross-cutting interception pipeline.
///
/// Middleware sees every agent run and every tool call as a structured event.
/// Hooks receive value types (not the live context) so instrumentation cannot
/// mutate execution state, and so this module stays free of import cycles.
const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("../types.zig");
const telemetry_mod = @import("../../telemetry/collector.zig");
const tool_mod = @import("tool.zig");

pub const AgentPhase = enum(u8) { start, finish };

pub const AgentEvent = struct {
    phase: AgentPhase,
    task_id: u128,
    agent_id: []const u8,
    kind: types.AgentKind,
    mode: types.ExecutionMode,
    attempt: u16,
    /// Populated on `finish` only.
    status_code: u8 = 0,
    latency_ms: u32 = 0,
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    tool_calls: u32 = 0,
    err: ?anyerror = null,
};

pub const ToolEvent = struct {
    phase: AgentPhase,
    task_id: u128,
    agent_id: []const u8,
    tool_id: []const u8,
    side_effect: tool_mod.SideEffectClass,
    attempt: u16,
    input_bytes: u32 = 0,
    output_bytes: u32 = 0,
    ok: bool = false,
    approved: bool = false,
    redacted: bool = false,
    latency_ms: u32 = 0,
    err: ?anyerror = null,
};

/// Erased interceptor.
pub const Middleware = struct {
    name: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        on_agent: ?*const fn (*anyopaque, AgentEvent) void = null,
        on_tool: ?*const fn (*anyopaque, ToolEvent) void = null,
    };
};

/// Ordered chain of middleware. Notification is best-effort: a hook must never
/// fail the run, so hooks return void and exceptions are impossible by design.
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    chain: std.ArrayListUnmanaged(Middleware) = .empty,

    /// Creates an empty pipeline.
    /// @example
    /// var pipeline = Pipeline.init(allocator);
    pub fn init(allocator: std.mem.Allocator) Pipeline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pipeline) void {
        self.chain.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends an interceptor to the end of the chain.
    /// @example
    /// try pipeline.use(telemetry_mw.middleware());
    pub fn use(self: *Pipeline, mw: Middleware) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.chain.append(self.allocator, mw);
    }

    /// Broadcasts an agent lifecycle event.
    /// @example
    /// pipeline.notifyAgent(.{ .phase = .start, ... });
    pub fn notifyAgent(self: *Pipeline, evt: AgentEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.chain.items) |mw| {
            if (mw.vtable.on_agent) |f| f(mw.ctx, evt);
        }
    }

    /// Broadcasts a tool lifecycle event.
    /// @example
    /// pipeline.notifyTool(.{ .phase = .finish, ... });
    pub fn notifyTool(self: *Pipeline, evt: ToolEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.chain.items) |mw| {
            if (mw.vtable.on_tool) |f| f(mw.ctx, evt);
        }
    }

    pub fn count(self: *Pipeline) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.chain.items.len;
    }
};

/// Forwards framework events into the §6 telemetry sink, respecting its
/// privacy tier (the sink hashes names and drops events at level `none`).
pub const TelemetryMiddleware = struct {
    sink: *telemetry_mod.TelemetrySink,
    mutex: compat.Mutex = .init,
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Binds a telemetry sink as middleware.
    /// @example
    /// var tm = TelemetryMiddleware.init(&sink);
    /// try pipeline.use(tm.middleware());
    pub fn init(sink: *telemetry_mod.TelemetrySink) TelemetryMiddleware {
        return .{ .sink = sink };
    }

    fn onAgent(ptr: *anyopaque, evt: AgentEvent) void {
        const self: *TelemetryMiddleware = @ptrCast(@alignCast(ptr));
        if (evt.phase != .finish) return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.sink.record(.{
            .name = "agent.latency_ms",
            .ts_unix_ms = compat.milliTimestamp(),
            .attrs = &.{},
            .value = .{ .u64 = evt.latency_ms },
        }) catch {
            _ = self.dropped.fetchAdd(1, .acq_rel);
            return;
        };
        self.sink.record(.{
            .name = "agent.tokens_total",
            .ts_unix_ms = compat.milliTimestamp(),
            .attrs = &.{},
            .value = .{ .u64 = @as(u64, evt.tokens_in) + @as(u64, evt.tokens_out) },
        }) catch {
            _ = self.dropped.fetchAdd(1, .acq_rel);
        };
    }

    fn onTool(ptr: *anyopaque, evt: ToolEvent) void {
        const self: *TelemetryMiddleware = @ptrCast(@alignCast(ptr));
        if (evt.phase != .finish) return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.sink.record(.{
            .name = "tool.latency_ms",
            .ts_unix_ms = compat.milliTimestamp(),
            .attrs = &.{},
            .value = .{ .u64 = evt.latency_ms },
        }) catch {
            _ = self.dropped.fetchAdd(1, .acq_rel);
        };
    }

    const vtable = Middleware.VTable{ .on_agent = onAgent, .on_tool = onTool };

    /// Returns the erased middleware handle.
    /// @example
    /// try pipeline.use(tm.middleware());
    pub fn middleware(self: *TelemetryMiddleware) Middleware {
        return .{ .name = "telemetry", .ctx = self, .vtable = &vtable };
    }
};

/// In-memory span recorder used by tests, the trace viewer, and replay tooling.
pub const TracingMiddleware = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    agent_events: std.ArrayListUnmanaged(AgentEvent) = .empty,
    tool_events: std.ArrayListUnmanaged(ToolEvent) = .empty,
    max_events: usize = 100_000,

    /// Creates an empty recorder.
    /// @example
    /// var tracer = TracingMiddleware.init(allocator);
    pub fn init(allocator: std.mem.Allocator) TracingMiddleware {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TracingMiddleware) void {
        self.agent_events.deinit(self.allocator);
        self.tool_events.deinit(self.allocator);
        self.* = undefined;
    }

    fn onAgent(ptr: *anyopaque, evt: AgentEvent) void {
        const self: *TracingMiddleware = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.agent_events.items.len >= self.max_events) return;
        self.agent_events.append(self.allocator, evt) catch {};
    }

    fn onTool(ptr: *anyopaque, evt: ToolEvent) void {
        const self: *TracingMiddleware = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tool_events.items.len >= self.max_events) return;
        self.tool_events.append(self.allocator, evt) catch {};
    }

    const vtable = Middleware.VTable{ .on_agent = onAgent, .on_tool = onTool };

    /// Returns the erased middleware handle.
    /// @example
    /// try pipeline.use(tracer.middleware());
    pub fn middleware(self: *TracingMiddleware) Middleware {
        return .{ .name = "tracing", .ctx = self, .vtable = &vtable };
    }

    /// Number of recorded agent events matching `phase`.
    /// @example
    /// const starts = tracer.countAgent(.start);
    pub fn countAgent(self: *TracingMiddleware, phase: AgentPhase) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.agent_events.items) |e| {
            if (e.phase == phase) n += 1;
        }
        return n;
    }

    /// Number of recorded tool events matching `phase`.
    /// @example
    /// const calls = tracer.countTool(.finish);
    pub fn countTool(self: *TracingMiddleware, phase: AgentPhase) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.tool_events.items) |e| {
            if (e.phase == phase) n += 1;
        }
        return n;
    }

    /// True when any tool event carries `err`.
    /// @example
    /// if (tracer.sawToolError(error.PolicyDenied)) ...
    pub fn sawToolError(self: *TracingMiddleware, err: anyerror) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tool_events.items) |e| {
            if (e.err) |got| {
                if (got == err) return true;
            }
        }
        return false;
    }
};

test "middleware: pipeline fans events out in registration order" {
    var pipeline = Pipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    var tracer = TracingMiddleware.init(std.testing.allocator);
    defer tracer.deinit();
    try pipeline.use(tracer.middleware());
    try std.testing.expectEqual(@as(usize, 1), pipeline.count());

    pipeline.notifyAgent(.{
        .phase = .start,
        .task_id = 1,
        .agent_id = "core.coder.v1",
        .kind = .coder,
        .mode = .sequential,
        .attempt = 0,
    });
    pipeline.notifyAgent(.{
        .phase = .finish,
        .task_id = 1,
        .agent_id = "core.coder.v1",
        .kind = .coder,
        .mode = .sequential,
        .attempt = 0,
        .latency_ms = 12,
    });
    pipeline.notifyTool(.{
        .phase = .finish,
        .task_id = 1,
        .agent_id = "core.coder.v1",
        .tool_id = "workspace.read_file",
        .side_effect = .workspace_read,
        .attempt = 0,
        .ok = true,
    });

    try std.testing.expectEqual(@as(usize, 1), tracer.countAgent(.start));
    try std.testing.expectEqual(@as(usize, 1), tracer.countAgent(.finish));
    try std.testing.expectEqual(@as(usize, 1), tracer.countTool(.finish));
}

test "middleware: telemetry bridge records finish events only" {
    var sink = telemetry_mod.TelemetrySink.init(std.testing.allocator, .basic);
    defer sink.deinit();

    var pipeline = Pipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    var tm = TelemetryMiddleware.init(&sink);
    try pipeline.use(tm.middleware());

    pipeline.notifyAgent(.{ .phase = .start, .task_id = 1, .agent_id = "a", .kind = .coder, .mode = .sequential, .attempt = 0 });
    try std.testing.expectEqual(@as(usize, 0), sink.storedCount());

    pipeline.notifyAgent(.{ .phase = .finish, .task_id = 1, .agent_id = "a", .kind = .coder, .mode = .sequential, .attempt = 0, .latency_ms = 5, .tokens_in = 10, .tokens_out = 20 });
    try std.testing.expectEqual(@as(usize, 2), sink.storedCount());
}

test "middleware: tracer surfaces tool errors" {
    var pipeline = Pipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    var tracer = TracingMiddleware.init(std.testing.allocator);
    defer tracer.deinit();
    try pipeline.use(tracer.middleware());

    pipeline.notifyTool(.{
        .phase = .finish,
        .task_id = 3,
        .agent_id = "a",
        .tool_id = "net.fetch",
        .side_effect = .network_egress,
        .attempt = 0,
        .ok = false,
        .err = error.PolicyDenied,
    });

    try std.testing.expect(tracer.sawToolError(error.PolicyDenied));
    try std.testing.expect(!tracer.sawToolError(error.ToolTimeout));
}

test "middleware: concurrent notification is serialized" {
    var pipeline = Pipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    var tracer = TracingMiddleware.init(std.testing.allocator);
    defer tracer.deinit();
    try pipeline.use(tracer.middleware());

    const Worker = struct {
        fn run(p: *Pipeline) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                p.notifyAgent(.{ .phase = .finish, .task_id = 1, .agent_id = "a", .kind = .tester, .mode = .parallel_fanout, .attempt = 0 });
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&pipeline});
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(usize, 400), tracer.countAgent(.finish));
}
