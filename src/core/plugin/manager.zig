/// Plugin and extension ecosystem per spec §5.
/// Validates manifests, manages plugin lifecycle, and routes messages over
/// an asynchronous bus with per-plugin quotas and backpressure.
const std = @import("std");

pub const Capability = enum(u16) {
    read_workspace,
    write_workspace,
    network_egress,
    register_ui_panel,
    register_lint_rule,
    register_agent,
    register_indexer,
};

pub const PluginManifest = struct {
    id: []const u8,
    version: []const u8,
    abi_version: u32,
    capabilities: []const Capability,
    signature: []const u8,
    entrypoint: []const u8,
};

pub const PluginStatus = enum(u8) {
    unloaded,
    loaded,
    healthy,
    unhealthy,
    suspended,
};

pub const PluginHandle = struct {
    id: u32,
    manifest_id: []const u8,
    status: PluginStatus,
};

pub const RequestFrame = struct {
    id: u64,
    method: []const u8,
    payload: []const u8,
};

pub const ResponseFrame = struct {
    request_id: u64,
    ok: bool,
    payload: []const u8,
};

pub const EventFrame = struct {
    kind: []const u8,
    payload: []const u8,
};

pub const PluginMessage = union(enum) {
    request: RequestFrame,
    response: ResponseFrame,
    event: EventFrame,
};

pub const SignatureVerifier = *const fn (manifest: *const PluginManifest, bytes: []const u8) bool;

pub const PluginError = error{
    AbiMismatch,
    InvalidSignature,
    CapabilityViolation,
    PluginNotFound,
    BusQuotaExceeded,
    OutOfMemory,
};

/// Supported ABI version range. Plugins outside this range are rejected.
const ABI_MIN: u32 = 1;
const ABI_MAX: u32 = 1;
/// Maximum queued messages per plugin before backpressure kicks in.
const BUS_QUOTA: usize = 128;

fn acceptTestSignature(_: *const PluginManifest, bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "signed");
}

pub const PluginState = struct {
    handle: PluginHandle,
    manifest: PluginManifest,
    message_queue: std.ArrayListUnmanaged(PluginMessage),
};

/// Plugin manager: loads, validates, and tracks plugin instances.
/// @example
/// var mgr = PluginManager.init(alloc);
/// const handle = try mgr.load(manifest, bytes);
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayListUnmanaged(PluginState),
    next_id: u32,
    signature_verifier: ?SignatureVerifier,

    pub fn init(alloc: std.mem.Allocator) PluginManager {
        return .{ .allocator = alloc, .plugins = .empty, .next_id = 1, .signature_verifier = null };
    }

    pub fn initWithVerifier(alloc: std.mem.Allocator, verifier: SignatureVerifier) PluginManager {
        return .{ .allocator = alloc, .plugins = .empty, .next_id = 1, .signature_verifier = verifier };
    }

    pub fn deinit(self: *PluginManager) void {
        for (self.plugins.items) |*p| {
            p.message_queue.deinit(self.allocator);
        }
        self.plugins.deinit(self.allocator);
        self.* = undefined;
    }

    /// Loads a plugin after ABI and cryptographic signature verification.
    /// A manager created with `init` has no trust root and rejects packages;
    /// production code must inject an actual verifier.
    /// @example
    /// const handle = try mgr.load(manifest, bytes);
    pub fn load(
        self: *PluginManager,
        manifest: PluginManifest,
        bytes: []const u8,
    ) PluginError!PluginHandle {
        if (manifest.id.len == 0 or manifest.version.len == 0 or manifest.entrypoint.len == 0) {
            return PluginError.InvalidSignature;
        }

        // ABI compatibility check.
        if (manifest.abi_version < ABI_MIN or manifest.abi_version > ABI_MAX) {
            return PluginError.AbiMismatch;
        }

        // Never treat a non-empty signature string as proof of authenticity.
        // Production callers must inject an actual verifier (for example,
        // Ed25519 over the canonical manifest + package bytes).
        const verifier = self.signature_verifier orelse return PluginError.InvalidSignature;
        if (manifest.signature.len == 0 or !verifier(&manifest, bytes)) {
            return PluginError.InvalidSignature;
        }

        const id = self.next_id;
        self.next_id += 1;

        const handle = PluginHandle{
            .id = id,
            .manifest_id = manifest.id,
            .status = .loaded,
        };

        self.plugins.append(self.allocator, .{
            .handle = handle,
            .manifest = manifest,
            .message_queue = .empty,
        }) catch return PluginError.OutOfMemory;

        return handle;
    }

    /// Unloads a plugin by handle id, draining its message queue.
    pub fn unload(self: *PluginManager, handle_id: u32) PluginError!void {
        for (self.plugins.items, 0..) |*p, i| {
            if (p.handle.id == handle_id) {
                p.message_queue.deinit(self.allocator);
                _ = self.plugins.swapRemove(i);
                return;
            }
        }
        return PluginError.PluginNotFound;
    }

    /// Checks if a plugin has a specific capability.
    pub fn hasCapability(self: *const PluginManager, handle_id: u32, cap: Capability) bool {
        for (self.plugins.items) |p| {
            if (p.handle.id != handle_id) continue;
            for (p.manifest.capabilities) |c| {
                if (c == cap) return true;
            }
        }
        return false;
    }

    fn findPlugin(self: *PluginManager, handle_id: u32) ?*PluginState {
        for (self.plugins.items) |*p| {
            if (p.handle.id == handle_id) return p;
        }
        return null;
    }
};

/// Async message bus with per-plugin quotas per spec §5.3.
/// @example
/// try bus.send(handle, .{ .event = .{ .kind = "file_saved", .payload = "{}" } });
/// const msg = bus.receive(handle);
pub const PluginBus = struct {
    manager: *PluginManager,

    pub fn init(manager: *PluginManager) PluginBus {
        return .{ .manager = manager };
    }

    /// Sends a message to a plugin's queue, enforcing the bus quota.
    /// @example
    /// try bus.send(handle, msg);
    pub fn send(
        self: *PluginBus,
        handle: PluginHandle,
        msg: PluginMessage,
    ) PluginError!void {
        const state = self.manager.findPlugin(handle.id) orelse return PluginError.PluginNotFound;

        if (state.message_queue.items.len >= BUS_QUOTA) {
            return PluginError.BusQuotaExceeded;
        }

        state.message_queue.append(self.manager.allocator, msg) catch return PluginError.OutOfMemory;
    }

    /// Pops the next message from a plugin's queue. Returns null if empty.
    /// @example
    /// const msg = bus.receive(handle);
    pub fn receive(self: *PluginBus, handle: PluginHandle) ?PluginMessage {
        const state = self.manager.findPlugin(handle.id) orelse return null;
        if (state.message_queue.items.len == 0) return null;
        return state.message_queue.orderedRemove(0);
    }
};

test "plugin manager: load and check capabilities" {
    const manifest = PluginManifest{
        .id = "test-plugin",
        .version = "1.0.0",
        .abi_version = 1,
        .capabilities = &[_]Capability{ .read_workspace, .register_lint_rule },
        .signature = "fake-sig",
        .entrypoint = "main",
    };

    var verified_mgr = PluginManager.initWithVerifier(std.testing.allocator, acceptTestSignature);
    defer verified_mgr.deinit();

    const handle = try verified_mgr.load(manifest, "signed");
    try std.testing.expectEqual(PluginStatus.loaded, handle.status);
    try std.testing.expect(verified_mgr.hasCapability(handle.id, .read_workspace));
    try std.testing.expect(!verified_mgr.hasCapability(handle.id, .network_egress));
}

test "plugin manager: ABI mismatch rejected" {
    var mgr = PluginManager.init(std.testing.allocator);
    defer mgr.deinit();

    const manifest = PluginManifest{
        .id = "old-plugin",
        .version = "0.0.1",
        .abi_version = 99,
        .capabilities = &.{},
        .signature = "sig",
        .entrypoint = "main",
    };

    const result = mgr.load(manifest, &.{});
    try std.testing.expectError(PluginError.AbiMismatch, result);
}

test "plugin bus: send and receive" {
    var mgr = PluginManager.initWithVerifier(std.testing.allocator, acceptTestSignature);
    defer mgr.deinit();

    const manifest = PluginManifest{
        .id = "bus-test",
        .version = "1.0.0",
        .abi_version = 1,
        .capabilities = &.{},
        .signature = "sig",
        .entrypoint = "main",
    };
    const handle = try mgr.load(manifest, "signed");
    var bus = PluginBus.init(&mgr);

    try bus.send(handle, .{ .event = .{ .kind = "file_saved", .payload = "{}" } });
    const msg = bus.receive(handle);
    try std.testing.expect(msg != null);

    const evt = msg.?.event;
    try std.testing.expectEqualStrings("file_saved", evt.kind);
}

test "plugin bus: quota exceeded" {
    var mgr = PluginManager.initWithVerifier(std.testing.allocator, acceptTestSignature);
    defer mgr.deinit();

    const manifest = PluginManifest{
        .id = "flood-test",
        .version = "1.0.0",
        .abi_version = 1,
        .capabilities = &.{},
        .signature = "sig",
        .entrypoint = "main",
    };
    const handle = try mgr.load(manifest, &.{});
    var bus = PluginBus.init(&mgr);

    const msg = PluginMessage{ .event = .{ .kind = "e", .payload = "" } };
    var i: usize = 0;
    while (i < BUS_QUOTA) : (i += 1) {
        try bus.send(handle, msg);
    }
    const overflow = bus.send(handle, msg);
    try std.testing.expectError(PluginError.BusQuotaExceeded, overflow);
}


test "plugin manager: rejects unverifiable packages" {
    var mgr = PluginManager.init(std.testing.allocator);
    defer mgr.deinit();

    const manifest = PluginManifest{
        .id = "unsigned",
        .version = "1.0.0",
        .abi_version = 1,
        .capabilities = &.{},
        .signature = "anything",
        .entrypoint = "main",
    };
    try std.testing.expectError(PluginError.InvalidSignature, mgr.load(manifest, "payload"));
}
