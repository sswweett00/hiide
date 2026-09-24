/// Provider abstraction and routing layer per spec §4.
/// Selects the optimal provider (BYOK / managed / self-hosted) based on
/// policy, capability, health, cost, and locality.
const std = @import("std");

pub const ModelCapabilities = packed struct {
    tool_use: bool,
    vision: bool,
    structured_output: bool,
    long_context: bool,
    streaming: bool,

    pub fn all() ModelCapabilities {
        return .{
            .tool_use = true,
            .vision = true,
            .structured_output = true,
            .long_context = true,
            .streaming = true,
        };
    }

    pub fn local() ModelCapabilities {
        return .{
            .tool_use = false,
            .vision = false,
            .structured_output = true,
            .long_context = false,
            .streaming = true,
        };
    }
};

pub const ProviderMode = enum(u8) {
    byok,
    managed,
    self_hosted,
};

pub const HealthStatus = enum(u8) {
    healthy,
    degraded,
    circuit_open,
    unknown,
};

pub const ModelDescriptor = struct {
    id: []const u8,
    provider_id: []const u8,
    capabilities: ModelCapabilities,
    context_window: u32,
    /// Highest data-classification level this model endpoint may receive.
    /// 0 = public, 4 = secret.
    max_classification: u8 = 0,
    /// Cost per 1k tokens in microunits.
    cost_per_1k_input: u32,
    cost_per_1k_output: u32,
};

pub const UsageSnapshot = struct {
    input_tokens_used: u64,
    output_tokens_used: u64,
    requests_today: u32,
};

pub const QuotaSnapshot = struct {
    daily_token_limit: u64,
    remaining: u64,
    reset_ts_unix_ms: i64,
};

/// Abstract provider vtable per spec §4.2.
pub const Provider = struct {
    id: []const u8,
    mode: ProviderMode,
    health: HealthStatus,
    vtable: *const VTable,
    ctx: *anyopaque,
    /// Runtime routing telemetry, updated by the execution layer.
    success_count: u64 = 0,
    failure_count: u64 = 0,
    ema_latency_ms: f32 = 0,

    pub const VTable = struct {
        get_models: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ModelDescriptor,
        validate_key: *const fn (*anyopaque) anyerror!void,
        get_usage: *const fn (*anyopaque) anyerror!UsageSnapshot,
        get_quota: *const fn (*anyopaque) anyerror!QuotaSnapshot,
        supports: *const fn (*anyopaque, []const u8) ModelCapabilities,
    };

    pub fn getModels(self: *const Provider, alloc: std.mem.Allocator) ![]ModelDescriptor {
        return self.vtable.get_models(self.ctx, alloc);
    }

    pub fn validateKey(self: *const Provider) !void {
        return self.vtable.validate_key(self.ctx);
    }

    pub fn supports(self: *const Provider, model_id: []const u8) ModelCapabilities {
        return self.vtable.supports(self.ctx, model_id);
    }
};

pub const RouteRequest = struct {
    required_capabilities: ModelCapabilities,
    /// Latency class: 0 = best-effort, 1 = interactive, 2 = realtime.
    latency_class: u8,
    /// Maximum cost per 1k tokens in microunits; 0 = no limit.
    max_cost_1k: u32,
    /// Data classification level (maps to §3 Classification enum values).
    max_classification: u8,
};

pub const TenantConfig = struct {
    allow_byok: bool,
    allow_managed: bool,
    allow_self_hosted: bool,
    /// Provider IDs explicitly allowed.
    allowed_provider_ids: []const []const u8,
};

pub const RouteDecision = struct {
    provider_id: []const u8,
    model_id: []const u8,
    mode: ProviderMode,
    score: f32,
};

pub const RouterError = error{
    NoEligibleProvider,
    PolicyViolation,
    OutOfMemory,
};

/// Provider router with policy-filtered selection and circuit-breaker awareness.
/// @example
/// var router = Router.init(alloc);
/// try router.registerProvider(provider);
/// const route = try router.select(req, tenant_cfg, alloc);
pub const Router = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayListUnmanaged(Provider),
    /// Tracks consecutive failure counts per provider for circuit breaking.
    failure_counts: std.StringHashMapUnmanaged(u32),
    circuit_threshold: u32,

    pub fn init(alloc: std.mem.Allocator) Router {
        return .{
            .allocator = alloc,
            .providers = .empty,
            .failure_counts = .{},
            .circuit_threshold = 5,
        };
    }

    pub fn deinit(self: *Router) void {
        self.providers.deinit(self.allocator);
        self.failure_counts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerProvider(self: *Router, p: Provider) !void {
        try self.providers.append(self.allocator, p);
    }

    /// Selects the best provider/model for the request.
    /// @example
    /// const route = try router.select(req, cfg, alloc);
    pub fn select(
        self: *Router,
        req: RouteRequest,
        cfg: TenantConfig,
        alloc: std.mem.Allocator,
    ) RouterError!RouteDecision {
        var best: ?RouteDecision = null;
        var best_score: f32 = -1.0;

        for (self.providers.items) |*provider| {
            if (!isModeAllowed(provider.mode, cfg)) continue;
            if (provider.health == .circuit_open) continue;
            if (!isProviderAllowed(provider.id, cfg.allowed_provider_ids)) continue;

            const models = provider.getModels(alloc) catch continue;
            defer alloc.free(models);

            for (models) |model| {
                if (!capsMatch(req.required_capabilities, model.capabilities)) continue;
                if (model.max_classification < req.max_classification) continue;
                if (req.max_cost_1k > 0 and model.cost_per_1k_input > req.max_cost_1k) continue;

                const score = scoreModel(model, req, provider);
                if (score > best_score) {
                    best_score = score;
                    best = .{
                        .provider_id = provider.id,
                        .model_id = model.id,
                        .mode = provider.mode,
                        .score = score,
                    };
                }
            }
        }

        return best orelse RouterError.NoEligibleProvider;
    }

    /// Records a provider failure and potentially opens the circuit breaker.
    /// @example
    /// try router.recordFailure("openai");
    pub fn recordFailure(self: *Router, provider_id: []const u8) !void {
        const gop = try self.failure_counts.getOrPutValue(self.allocator, provider_id, 0);
        gop.value_ptr.* += 1;
        for (self.providers.items) |*p| {
            if (!std.mem.eql(u8, p.id, provider_id)) continue;
            p.failure_count += 1;
            if (gop.value_ptr.* >= self.circuit_threshold) {
                p.health = .circuit_open;
            } else if (p.health == .healthy) {
                p.health = .degraded;
            }
            break;
        }
    }

    /// Records a successful request and updates provider latency telemetry.
    pub fn recordSuccess(self: *Router, provider_id: []const u8, latency_ms: u32) void {
        _ = self.failure_counts.remove(provider_id);
        for (self.providers.items) |*p| {
            if (!std.mem.eql(u8, p.id, provider_id)) continue;
            p.success_count += 1;
            p.failure_count = 0;
            p.health = .healthy;
            const latency = @as(f32, @floatFromInt(latency_ms));
            if (p.success_count == 1) {
                p.ema_latency_ms = latency;
            } else {
                const alpha: f32 = 0.25;
                p.ema_latency_ms = p.ema_latency_ms * (1.0 - alpha) + latency * alpha;
            }
            break;
        }
    }

    /// Resets the failure count and re-marks provider as healthy.
    pub fn resetCircuit(self: *Router, provider_id: []const u8) void {
        _ = self.failure_counts.remove(provider_id);
        for (self.providers.items) |*p| {
            if (std.mem.eql(u8, p.id, provider_id)) {
                p.failure_count = 0;
                p.health = .healthy;
                break;
            }
        }
    }

    fn isModeAllowed(mode: ProviderMode, cfg: TenantConfig) bool {
        return switch (mode) {
            .byok => cfg.allow_byok,
            .managed => cfg.allow_managed,
            .self_hosted => cfg.allow_self_hosted,
        };
    }

    fn isProviderAllowed(id: []const u8, allowed: []const []const u8) bool {
        if (allowed.len == 0) return true;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, id)) return true;
        }
        return false;
    }

    fn capsMatch(required: ModelCapabilities, available: ModelCapabilities) bool {
        if (required.tool_use and !available.tool_use) return false;
        if (required.vision and !available.vision) return false;
        if (required.structured_output and !available.structured_output) return false;
        if (required.long_context and !available.long_context) return false;
        if (required.streaming and !available.streaming) return false;
        return true;
    }

    fn scoreModel(model: ModelDescriptor, req: RouteRequest, provider: *const Provider) f32 {
        var score: f32 = 1.0;
        if (req.latency_class >= 2 and provider.mode == .self_hosted) score += 0.5;
        if (provider.health == .healthy) score += 0.1;
        if (provider.health == .degraded) score -= 0.25;
        if (provider.health == .unknown) score -= 0.1;

        if (model.cost_per_1k_input > 0) {
            score -= @as(f32, @floatFromInt(model.cost_per_1k_input)) / 10_000.0;
        }
        score -= @as(f32, @floatFromInt(@min(provider.failure_count, 50))) * 0.02;
        if (provider.ema_latency_ms > 0) {
            score -= @min(provider.ema_latency_ms / 10_000.0, 0.5);
        }
        return score;
    }
};

/// Secure vault interface for BYOK credentials per spec §4.
/// In the desktop build this wraps OS-native secure storage.
/// In tests it uses an in-memory map.
pub const SecretVault = struct {
    allocator: std.mem.Allocator,
    store: std.StringHashMapUnmanaged([]u8),

    pub fn init(alloc: std.mem.Allocator) SecretVault {
        return .{ .allocator = alloc, .store = .{} };
    }

    pub fn deinit(self: *SecretVault) void {
        var it = self.store.iterator();
        while (it.next()) |entry| {
            // Zero-out secret bytes before freeing (secret zero-leak per spec §3.4).
            @memset(entry.value_ptr.*, 0);
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.store.deinit(self.allocator);
    }

    /// Stores a credential in the vault.
    /// @example
    /// try vault.put("anthropic", key_bytes);
    pub fn put(self: *SecretVault, provider_id: []const u8, secret: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, provider_id);
        errdefer self.allocator.free(owned_key);
        const owned_secret = try self.allocator.dupe(u8, secret);
        errdefer self.allocator.free(owned_secret);

        if (self.store.getPtr(provider_id)) |existing| {
            @memset(existing.*, 0);
            self.allocator.free(existing.*);
            existing.* = owned_secret;
            self.allocator.free(owned_key);
        } else {
            try self.store.put(self.allocator, owned_key, owned_secret);
        }
    }

    /// Retrieves a credential. Returns null if not found.
    pub fn get(self: *const SecretVault, provider_id: []const u8) ?[]const u8 {
        return self.store.get(provider_id);
    }

    /// Removes a credential, zeroing memory.
    pub fn remove(self: *SecretVault, provider_id: []const u8) void {
        if (self.store.getPtr(provider_id)) |secret| {
            @memset(secret.*, 0);
            self.allocator.free(secret.*);
        }
        if (self.store.fetchRemove(provider_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }
};

// ─── Test helpers ────────────────────────────────────────────────────────────

const TestProvider = struct {
    id: []const u8,
    mode: ProviderMode,
    models: []const ModelDescriptor,

    fn getModels(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]ModelDescriptor {
        const self: *const TestProvider = @ptrCast(@alignCast(ctx));
        return alloc.dupe(ModelDescriptor, self.models);
    }
    fn validateKey(_: *anyopaque) anyerror!void {}
    fn getUsage(_: *anyopaque) anyerror!UsageSnapshot {
        return .{ .input_tokens_used = 0, .output_tokens_used = 0, .requests_today = 0 };
    }
    fn getQuota(_: *anyopaque) anyerror!QuotaSnapshot {
        return .{ .daily_token_limit = 1_000_000, .remaining = 999_000, .reset_ts_unix_ms = 0 };
    }
    fn supports(_: *anyopaque, _: []const u8) ModelCapabilities {
        return ModelCapabilities.all();
    }

    const vtable = Provider.VTable{
        .get_models = getModels,
        .validate_key = validateKey,
        .get_usage = getUsage,
        .get_quota = getQuota,
        .supports = supports,
    };

    fn toProvider(self: *TestProvider) Provider {
        return .{
            .id = self.id,
            .mode = self.mode,
            .health = .healthy,
            .vtable = &vtable,
            .ctx = self,
        };
    }
};

test "router: runtime telemetry influences scoring" {
    const alloc = std.testing.allocator;
    var router = Router.init(alloc);
    defer router.deinit();

    var fast = TestProvider{
        .id = "fast",
        .mode = .byok,
        .models = &[_]ModelDescriptor{.{
            .id = "fast-model",
            .provider_id = "fast",
            .capabilities = ModelCapabilities.all(),
            .context_window = 16_000,
            .cost_per_1k_input = 1,
            .cost_per_1k_output = 1,
        }},
    };
    var slow = TestProvider{
        .id = "slow",
        .mode = .byok,
        .models = &[_]ModelDescriptor{.{
            .id = "slow-model",
            .provider_id = "slow",
            .capabilities = ModelCapabilities.all(),
            .context_window = 16_000,
            .cost_per_1k_input = 1,
            .cost_per_1k_output = 1,
        }},
    };
    try router.registerProvider(fast.toProvider());
    try router.registerProvider(slow.toProvider());

    router.recordSuccess("fast", 20);
    router.recordSuccess("slow", 900);

    const cfg = TenantConfig{
        .allow_byok = true,
        .allow_managed = false,
        .allow_self_hosted = false,
        .allowed_provider_ids = &.{},
    };
    const req = RouteRequest{
        .required_capabilities = .{ .tool_use = true, .vision = false, .structured_output = false, .long_context = false, .streaming = true },
        .latency_class = 1,
        .max_cost_1k = 0,
        .max_classification = 0,
    };

    const route = try router.select(req, cfg, alloc);
    try std.testing.expectEqualStrings("fast", route.provider_id);
}

test "router: filters models above their data classification ceiling" {
    const alloc = std.testing.allocator;
    var router = Router.init(alloc);
    defer router.deinit();

    var tp = TestProvider{
        .id = "public-only",
        .mode = .byok,
        .models = &[_]ModelDescriptor{.{
            .id = "public-model",
            .provider_id = "public-only",
            .capabilities = ModelCapabilities.all(),
            .context_window = 8_000,
            .max_classification = 0,
            .cost_per_1k_input = 1,
            .cost_per_1k_output = 1,
        }},
    };
    try router.registerProvider(tp.toProvider());

    const cfg = TenantConfig{
        .allow_byok = true,
        .allow_managed = false,
        .allow_self_hosted = false,
        .allowed_provider_ids = &.{},
    };
    const req = RouteRequest{
        .required_capabilities = .{ .tool_use = false, .vision = false, .structured_output = false, .long_context = false, .streaming = true },
        .latency_class = 0,
        .max_cost_1k = 0,
        .max_classification = 2,
    };
    try std.testing.expectError(RouterError.NoEligibleProvider, router.select(req, cfg, alloc));
}

test "router: selects eligible provider" {
    const alloc = std.testing.allocator;
    var router = Router.init(alloc);
    defer router.deinit();

    var tp = TestProvider{
        .id = "test-provider",
        .mode = .byok,
        .models = &[_]ModelDescriptor{.{
            .id = "gpt-4o",
            .provider_id = "test-provider",
            .capabilities = ModelCapabilities.all(),
            .context_window = 128_000,
            .cost_per_1k_input = 5,
            .cost_per_1k_output = 15,
        }},
    };
    try router.registerProvider(tp.toProvider());

    const cfg = TenantConfig{
        .allow_byok = true,
        .allow_managed = false,
        .allow_self_hosted = false,
        .allowed_provider_ids = &.{},
    };
    const req = RouteRequest{
        .required_capabilities = .{ .tool_use = false, .vision = false, .structured_output = false, .long_context = false, .streaming = true },
        .latency_class = 1,
        .max_cost_1k = 0,
        .max_classification = 0,
    };
    const route = try router.select(req, cfg, alloc);
    try std.testing.expectEqualStrings("test-provider", route.provider_id);
    try std.testing.expectEqualStrings("gpt-4o", route.model_id);
}

test "router: circuit breaker opens after threshold" {
    const alloc = std.testing.allocator;
    var router = Router.init(alloc);
    defer router.deinit();
    router.circuit_threshold = 2;

    var tp = TestProvider{
        .id = "flaky",
        .mode = .byok,
        .models = &[_]ModelDescriptor{.{
            .id = "m1",
            .provider_id = "flaky",
            .capabilities = ModelCapabilities.all(),
            .context_window = 8000,
            .cost_per_1k_input = 1,
            .cost_per_1k_output = 2,
        }},
    };
    try router.registerProvider(tp.toProvider());

    try router.recordFailure("flaky");
    try router.recordFailure("flaky");

    const cfg = TenantConfig{ .allow_byok = true, .allow_managed = true, .allow_self_hosted = true, .allowed_provider_ids = &.{} };
    const req = RouteRequest{ .required_capabilities = .{ .tool_use = false, .vision = false, .structured_output = false, .long_context = false, .streaming = false }, .latency_class = 0, .max_cost_1k = 0, .max_classification = 0 };
    const result = router.select(req, cfg, alloc);
    try std.testing.expectError(RouterError.NoEligibleProvider, result);
}

test "vault: put and get" {
    var vault = SecretVault.init(std.testing.allocator);
    defer vault.deinit();

    try vault.put("openai", "sk-secret");
    const val = vault.get("openai");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("sk-secret", val.?);
}
