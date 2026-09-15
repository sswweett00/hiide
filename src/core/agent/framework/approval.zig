/// Human-in-the-loop approval gate.
///
/// Spec §1.4 makes approval mandatory for filesystem writes outside the
/// workspace root, package installs, secret access, network egress, and VCS
/// mutation. The gate is the single rendezvous point between the executor and
/// the UI: agents block on `waitFor`, the desktop shell resolves requests over
/// IPC, and every decision is timestamped for the audit ledger.
const std = @import("std");
const compat = @import("../../compat.zig");
const cancel_mod = @import("cancel.zig");
const clock_mod = @import("clock.zig");
const tool_mod = @import("tool.zig");

pub const ApprovalError = error{
    ApprovalRejected,
    ApprovalTimeout,
    RequestNotFound,
    AlreadyDecided,
    Canceled,
    OutOfMemory,
};

pub const Decision = enum(u8) {
    pending,
    approved,
    rejected,
    expired,
};

/// Gate behaviour. `manual` is the production default; the auto modes exist for
/// headless CI runs and deterministic tests.
pub const Mode = enum(u8) {
    manual,
    auto_approve,
    auto_reject,
};

pub const Request = struct {
    id: u64,
    task_id: u128,
    agent_id: []const u8,
    tool_id: []const u8,
    side_effect: tool_mod.SideEffectClass,
    /// Short human-readable summary rendered in the approval UI.
    summary: []const u8,
    /// Machine-readable detail (path, URL, package name, diff digest).
    detail: []const u8,
    decision: Decision,
    requested_ms: i64,
    decided_ms: i64,
    decided_by: []const u8,
    expires_ms: i64,
};

pub const RequestInit = struct {
    task_id: u128,
    agent_id: []const u8,
    tool_id: []const u8,
    side_effect: tool_mod.SideEffectClass,
    summary: []const u8,
    detail: []const u8,
    /// 0 means "use the gate default".
    timeout_ms: u32 = 0,
};

pub const Stats = struct {
    requested: u64 = 0,
    approved: u64 = 0,
    rejected: u64 = 0,
    expired: u64 = 0,
};

/// Poll interval used while parked on the condition variable. Keeping it short
/// lets a virtual-clock timeout be observed without a real-time sleep.
const POLL_NS: u64 = std.time.ns_per_ms;

pub const Gate = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .init,
    cond: compat.Condition = .init,
    requests: std.ArrayListUnmanaged(Request) = .empty,
    next_id: u64 = 1,
    mode: Mode = .manual,
    default_timeout_ms: u32 = 300_000,
    clock: clock_mod.Clock,
    stats: Stats = .{},

    /// Creates a gate. Strings passed to `request` are duplicated by the gate.
    /// @example
    /// var gate = Gate.init(allocator, clock_mod.system(), .manual);
    pub fn init(allocator: std.mem.Allocator, c: clock_mod.Clock, mode: Mode) Gate {
        return .{ .allocator = allocator, .clock = c, .mode = mode };
    }

    pub fn deinit(self: *Gate) void {
        for (self.requests.items) |req| {
            self.allocator.free(req.agent_id);
            self.allocator.free(req.tool_id);
            self.allocator.free(req.summary);
            self.allocator.free(req.detail);
            self.allocator.free(req.decided_by);
        }
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    /// Files an approval request and returns its id.
    /// In auto modes the request is decided immediately.
    /// @example
    /// const id = try gate.request(.{ .task_id = t, .agent_id = "coder", .tool_id = "vcs.commit", .side_effect = .vcs_mutation, .summary = "commit", .detail = "3 files" });
    pub fn request(self: *Gate, init_req: RequestInit) ApprovalError!u64 {
        const now = self.clock.nowMs();
        const timeout: u32 = if (init_req.timeout_ms == 0) self.default_timeout_ms else init_req.timeout_ms;

        const agent_id = try self.allocator.dupe(u8, init_req.agent_id);
        errdefer self.allocator.free(agent_id);
        const tool_id = try self.allocator.dupe(u8, init_req.tool_id);
        errdefer self.allocator.free(tool_id);
        const summary = try self.allocator.dupe(u8, init_req.summary);
        errdefer self.allocator.free(summary);
        const detail = try self.allocator.dupe(u8, init_req.detail);
        errdefer self.allocator.free(detail);
        const decided_by = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(decided_by);

        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        const auto: Decision = switch (self.mode) {
            .manual => .pending,
            .auto_approve => .approved,
            .auto_reject => .rejected,
        };

        try self.requests.append(self.allocator, .{
            .id = id,
            .task_id = init_req.task_id,
            .agent_id = agent_id,
            .tool_id = tool_id,
            .side_effect = init_req.side_effect,
            .summary = summary,
            .detail = detail,
            .decision = auto,
            .requested_ms = now,
            .decided_ms = if (auto == .pending) 0 else now,
            .decided_by = decided_by,
            .expires_ms = now +| @as(i64, @intCast(timeout)),
        });

        self.stats.requested += 1;
        switch (auto) {
            .approved => self.stats.approved += 1,
            .rejected => self.stats.rejected += 1,
            else => {},
        }

        self.cond.broadcast();
        return id;
    }

    /// Resolves a pending request (called by the UI/IPC layer).
    /// @example
    /// try gate.resolve(id, .approved, "alice@corp");
    pub fn resolve(self: *Gate, id: u64, decision: Decision, by: []const u8) ApprovalError!void {
        const owned_by = try self.allocator.dupe(u8, by);
        errdefer self.allocator.free(owned_by);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.requests.items) |*req| {
            if (req.id != id) continue;
            if (req.decision != .pending) return ApprovalError.AlreadyDecided;
            req.decision = decision;
            req.decided_ms = self.clock.nowMs();
            self.allocator.free(req.decided_by);
            req.decided_by = owned_by;

            switch (decision) {
                .approved => self.stats.approved += 1,
                .rejected => self.stats.rejected += 1,
                .expired => self.stats.expired += 1,
                .pending => {},
            }
            self.cond.broadcast();
            return;
        }
        return ApprovalError.RequestNotFound;
    }

    /// Blocks until the request is decided, expires, or the token is cancelled.
    /// @example
    /// const decision = try gate.waitFor(id, &token);
    pub fn waitFor(self: *Gate, id: u64, token: ?*cancel_mod.Token) ApprovalError!Decision {
        while (true) {
            self.mutex.lock();

            const req = self.findLocked(id) orelse {
                self.mutex.unlock();
                return ApprovalError.RequestNotFound;
            };

            if (req.decision != .pending) {
                const decision = req.decision;
                self.mutex.unlock();
                return switch (decision) {
                    .approved => .approved,
                    .rejected => ApprovalError.ApprovalRejected,
                    .expired => ApprovalError.ApprovalTimeout,
                    .pending => unreachable,
                };
            }

            if (self.clock.nowMs() >= req.expires_ms) {
                req.decision = .expired;
                req.decided_ms = self.clock.nowMs();
                self.stats.expired += 1;
                self.mutex.unlock();
                return ApprovalError.ApprovalTimeout;
            }

            self.cond.timedWait(&self.mutex, POLL_NS);
            self.mutex.unlock();

            if (token) |t| {
                if (t.isCanceled()) return ApprovalError.Canceled;
            }
        }
    }

    /// Files a request and waits for its outcome.
    /// @example
    /// _ = try gate.requestAndWait(req_init, &token);
    pub fn requestAndWait(
        self: *Gate,
        init_req: RequestInit,
        token: ?*cancel_mod.Token,
    ) ApprovalError!Decision {
        const id = try self.request(init_req);
        return self.waitFor(id, token);
    }

    /// Snapshot of currently pending requests for the approval UI.
    /// Caller owns the slice; string fields point into gate-owned memory.
    /// @example
    /// const queue = try gate.pending(alloc);
    pub fn pending(self: *Gate, alloc: std.mem.Allocator) ![]Request {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = std.ArrayListUnmanaged(Request).empty;
        errdefer out.deinit(alloc);
        for (self.requests.items) |req| {
            if (req.decision == .pending) try out.append(alloc, req);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Expires every pending request whose deadline has passed.
    /// Returns how many were expired. Called by the executor's housekeeping tick.
    /// @example
    /// _ = gate.sweepExpired();
    pub fn sweepExpired(self: *Gate) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = self.clock.nowMs();
        var n: usize = 0;
        for (self.requests.items) |*req| {
            if (req.decision == .pending and now >= req.expires_ms) {
                req.decision = .expired;
                req.decided_ms = now;
                self.stats.expired += 1;
                n += 1;
            }
        }
        if (n > 0) self.cond.broadcast();
        return n;
    }

    /// Rejects every pending request, e.g. when a plan subtree is cancelled.
    /// @example
    /// _ = gate.rejectPendingForTask(task_id, "canceled");
    pub fn rejectPendingForTask(self: *Gate, task_id: u128) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        for (self.requests.items) |*req| {
            if (req.task_id == task_id and req.decision == .pending) {
                req.decision = .rejected;
                req.decided_ms = self.clock.nowMs();
                self.stats.rejected += 1;
                n += 1;
            }
        }
        if (n > 0) self.cond.broadcast();
        return n;
    }

    /// Returns a copy of the request record.
    /// @example
    /// const req = gate.find(id) orelse return;
    pub fn find(self: *Gate, id: u64) ?Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        const req = self.findLocked(id) orelse return null;
        return req.*;
    }

    /// Switches the gate mode at runtime (headless CI toggles this).
    /// @example
    /// gate.setMode(.auto_approve);
    pub fn setMode(self: *Gate, mode: Mode) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.mode = mode;
    }

    /// Aggregate counters for telemetry.
    /// @example
    /// const s = gate.snapshotStats();
    pub fn snapshotStats(self: *Gate) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    fn findLocked(self: *Gate, id: u64) ?*Request {
        for (self.requests.items) |*req| {
            if (req.id == id) return req;
        }
        return null;
    }
};

test "approval: auto-approve mode resolves immediately" {
    var gate = Gate.init(std.testing.allocator, clock_mod.system(), .auto_approve);
    defer gate.deinit();

    const decision = try gate.requestAndWait(.{
        .task_id = 1,
        .agent_id = "coder",
        .tool_id = "vcs.commit",
        .side_effect = .vcs_mutation,
        .summary = "commit patch",
        .detail = "3 files",
    }, null);

    try std.testing.expectEqual(Decision.approved, decision);
    try std.testing.expectEqual(@as(u64, 1), gate.snapshotStats().approved);
}

test "approval: auto-reject surfaces a governance error" {
    var gate = Gate.init(std.testing.allocator, clock_mod.system(), .auto_reject);
    defer gate.deinit();

    const result = gate.requestAndWait(.{
        .task_id = 1,
        .agent_id = "coder",
        .tool_id = "pkg.install",
        .side_effect = .package_install,
        .summary = "install left-pad",
        .detail = "left-pad@1.0.0",
    }, null);

    try std.testing.expectError(ApprovalError.ApprovalRejected, result);
}

test "approval: manual mode blocks until a reviewer resolves" {
    var gate = Gate.init(std.testing.allocator, clock_mod.system(), .manual);
    defer gate.deinit();

    const id = try gate.request(.{
        .task_id = 7,
        .agent_id = "security_auditor",
        .tool_id = "net.fetch",
        .side_effect = .network_egress,
        .summary = "fetch advisory db",
        .detail = "https://example.invalid/db",
    });

    const queue = try gate.pending(std.testing.allocator);
    defer std.testing.allocator.free(queue);
    try std.testing.expectEqual(@as(usize, 1), queue.len);

    const Reviewer = struct {
        fn run(g: *Gate, request_id: u64) void {
            compat.sleep(2);
            g.resolve(request_id, .approved, "alice") catch {};
        }
    };
    var t = try std.Thread.spawn(.{}, Reviewer.run, .{ &gate, id });
    defer t.join();

    try std.testing.expectEqual(Decision.approved, try gate.waitFor(id, null));
    try std.testing.expectEqualStrings("alice", gate.find(id).?.decided_by);
}

test "approval: timeout expires the request on a virtual clock" {
    var mc = clock_mod.ManualClock.init(0);
    var gate = Gate.init(std.testing.allocator, mc.clock(), .manual);
    defer gate.deinit();

    const id = try gate.request(.{
        .task_id = 1,
        .agent_id = "coder",
        .tool_id = "fs.write_external",
        .side_effect = .external_write,
        .summary = "write outside workspace",
        .detail = "/etc/hosts",
        .timeout_ms = 100,
    });

    mc.advance(101);
    try std.testing.expectError(ApprovalError.ApprovalTimeout, gate.waitFor(id, null));
    try std.testing.expectEqual(Decision.expired, gate.find(id).?.decision);
}

test "approval: cancellation unblocks a waiter" {
    var gate = Gate.init(std.testing.allocator, clock_mod.system(), .manual);
    defer gate.deinit();

    var token = cancel_mod.Token.init(null);
    const id = try gate.request(.{
        .task_id = 1,
        .agent_id = "coder",
        .tool_id = "vcs.commit",
        .side_effect = .vcs_mutation,
        .summary = "commit",
        .detail = "",
    });

    const Canceller = struct {
        fn run(t: *cancel_mod.Token) void {
            compat.sleep(2);
            t.cancel(.user_request);
        }
    };
    var th = try std.Thread.spawn(.{}, Canceller.run, .{&token});
    defer th.join();

    try std.testing.expectError(ApprovalError.Canceled, gate.waitFor(id, &token));
}

test "approval: sweep and per-task rejection clear the queue" {
    var mc = clock_mod.ManualClock.init(0);
    var gate = Gate.init(std.testing.allocator, mc.clock(), .manual);
    defer gate.deinit();

    _ = try gate.request(.{ .task_id = 1, .agent_id = "a", .tool_id = "t", .side_effect = .vcs_mutation, .summary = "s", .detail = "", .timeout_ms = 50 });
    const keep = try gate.request(.{ .task_id = 2, .agent_id = "a", .tool_id = "t", .side_effect = .vcs_mutation, .summary = "s", .detail = "", .timeout_ms = 10_000 });

    mc.advance(60);
    try std.testing.expectEqual(@as(usize, 1), gate.sweepExpired());
    try std.testing.expectEqual(@as(usize, 1), gate.rejectPendingForTask(2));
    try std.testing.expectError(ApprovalError.ApprovalRejected, gate.waitFor(keep, null));

    const stats = gate.snapshotStats();
    try std.testing.expectEqual(@as(u64, 2), stats.requested);
    try std.testing.expectEqual(@as(u64, 1), stats.expired);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected);
}

test "approval: double resolution is rejected" {
    var gate = Gate.init(std.testing.allocator, clock_mod.system(), .manual);
    defer gate.deinit();

    const id = try gate.request(.{ .task_id = 1, .agent_id = "a", .tool_id = "t", .side_effect = .secret_access, .summary = "s", .detail = "" });
    try gate.resolve(id, .approved, "alice");
    try std.testing.expectError(ApprovalError.AlreadyDecided, gate.resolve(id, .rejected, "bob"));
    try std.testing.expectError(ApprovalError.RequestNotFound, gate.resolve(999, .approved, "bob"));
}
