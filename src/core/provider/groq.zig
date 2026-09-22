/// Groq OpenAI-compatible chat client — zero-alloc-friendly, fast path for IDE.
/// Reads `groq-api-key` from the project root (or GROQ_API_KEY env) and talks to
/// https://api.groq.com/openai/v1/chat/completions.
const std = @import("std");
const compat = @import("../compat.zig");

pub const endpoint = "https://api.groq.com/openai/v1/chat/completions";
pub const models_endpoint = "https://api.groq.com/openai/v1/models";

/// Curated free-tier chat models (verified live against Groq, Aug 2026).
pub const Model = struct {
    id: []const u8,
    label: []const u8,
    context_window: u32,
    /// Prefer for interactive IDE chat (latency).
    instant: bool = false,
};

pub const curated_models = [_]Model{
    .{ .id = "llama-3.1-8b-instant", .label = "Llama 3.1 · 8B ⚡", .context_window = 131_072, .instant = true },
    .{ .id = "llama-3.3-70b-versatile", .label = "Llama 3.3 · 70B", .context_window = 131_072 },
    .{ .id = "openai/gpt-oss-20b", .label = "GPT OSS · 20B ⚡", .context_window = 131_072, .instant = true },
    .{ .id = "openai/gpt-oss-120b", .label = "GPT OSS · 120B", .context_window = 131_072 },
    .{ .id = "qwen/qwen3.6-27b", .label = "Qwen 3.6 · 27B", .context_window = 131_072 },
    .{ .id = "groq/compound-mini", .label = "Compound Mini · β", .context_window = 131_072 },
    .{ .id = "groq/compound", .label = "Compound · β", .context_window = 131_072 },
    .{ .id = "allam-2-7b", .label = "Allam 2 · 7B", .context_window = 4_096 },
};

pub const default_model = curated_models[0].id;

pub const Role = enum {
    system,
    user,
    assistant,

    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8 = default_model,
    messages: []const Message,
    temperature: f32 = 0.4,
    max_tokens: u32 = 2048,
    stream: bool = false,
};

pub const ChatResponse = struct {
    allocator: std.mem.Allocator,
    content: []u8,
    model: []u8,
    finish_reason: []u8,
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,

    pub fn deinit(self: *ChatResponse) void {
        self.allocator.free(self.content);
        self.allocator.free(self.model);
        self.allocator.free(self.finish_reason);
        self.* = undefined;
    }
};

pub const GroqError = error{
    MissingApiKey,
    HttpFailed,
    BadStatus,
    InvalidJson,
    MissingContent,
    OutOfMemory,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    api_key: []u8,
    http: std.http.Client,
    io: std.Io,
    owns_key: bool,

    /// Loads key from GROQ_API_KEY or `groq-api-key` file candidates.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) GroqError!Client {
        const key = try loadApiKey(allocator);
        return .{
            .allocator = allocator,
            .api_key = key,
            .http = .{ .allocator = allocator, .io = io },
            .io = io,
            .owns_key = true,
        };
    }

    pub fn initWithKey(allocator: std.mem.Allocator, io: std.Io, key: []const u8) GroqError!Client {
        const owned = allocator.dupe(u8, key) catch return GroqError.OutOfMemory;
        return .{
            .allocator = allocator,
            .api_key = owned,
            .http = .{ .allocator = allocator },
            .owns_key = true,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        if (self.owns_key) {
            @memset(self.api_key, 0);
            self.allocator.free(self.api_key);
        }
        self.* = undefined;
    }

    /// Non-streaming chat completion. Returns owned ChatResponse.
    pub fn complete(self: *Client, req: ChatRequest) GroqError!ChatResponse {
        const body = try buildRequestJson(self.allocator, req);
        defer self.allocator.free(body);

        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(self.allocator);

        const auth_value = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch
            return GroqError.OutOfMemory;
        defer self.allocator.free(auth_value);

        const result = self.http.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = body,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_value },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_storage = .{ .dynamic = &response_body },
            .max_append_size = 8 * 1024 * 1024,
        }) catch return GroqError.HttpFailed;

        const status_int: u16 = @intFromEnum(result.status);
        if (status_int < 200 or status_int >= 300) {
            return GroqError.BadStatus;
        }

        return try parseChatResponse(self.allocator, response_body.items);
    }
};

/// IDE system prompt shared with the frontend.
pub const system_prompt =
    \\You are hiide, an expert AI coding assistant embedded in a high-performance IDE built with Zig.
    \\You have deep knowledge of Zig, TypeScript, Rust, Python, and general software engineering.
    \\Be concise and precise. Use fenced code blocks with the correct language tag.
    \\When reviewing or explaining code, focus on correctness, performance, and idioms.
;

pub fn loadApiKey(allocator: std.mem.Allocator, io: std.Io) GroqError![]u8 {
    if (compat.getEnvAlloc(allocator, "GROQ_API_KEY")) |env_key| {
        const trimmed = std.mem.trim(u8, env_key, " \t\r\n");
        if (trimmed.len > 0) {
            const out = allocator.dupe(u8, trimmed) catch {
                allocator.free(env_key);
                return GroqError.OutOfMemory;
            };
            allocator.free(env_key);
            return out;
        }
        allocator.free(env_key);
    }

    const candidates = [_][]const u8{
        "groq-api-key",
        "../groq-api-key",
        "../../groq-api-key",
    };
    for (candidates) |path| {
        var dir = std.Io.Dir.cwd();
        const raw = dir.readFileAlloc(io, path, allocator, .limited(4096)) catch continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(raw);
            continue;
        }
        const out = allocator.dupe(u8, trimmed) catch {
            allocator.free(raw);
            return GroqError.OutOfMemory;
        };
        allocator.free(raw);
        return out;
    }
    return GroqError.MissingApiKey;
}

fn buildRequestJson(allocator: std.mem.Allocator, req: ChatRequest) GroqError![]u8 {
    var list = compat.ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();
    const w = list.writer();

    w.writeAll("{\"model\":\"") catch return GroqError.OutOfMemory;
    try writeJsonString(w, req.model);
    w.writeAll("\",\"temperature\":") catch return GroqError.OutOfMemory;
    w.print("{d:.2}", .{req.temperature}) catch return GroqError.OutOfMemory;
    w.writeAll(",\"max_tokens\":") catch return GroqError.OutOfMemory;
    w.print("{d}", .{req.max_tokens}) catch return GroqError.OutOfMemory;
    w.writeAll(",\"stream\":") catch return GroqError.OutOfMemory;
    w.writeAll(if (req.stream) "true" else "false") catch return GroqError.OutOfMemory;
    w.writeAll(",\"messages\":[") catch return GroqError.OutOfMemory;

    for (req.messages, 0..) |msg, i| {
        if (i > 0) w.writeAll(",") catch return GroqError.OutOfMemory;
        w.writeAll("{\"role\":\"") catch return GroqError.OutOfMemory;
        w.writeAll(msg.role.name()) catch return GroqError.OutOfMemory;
        w.writeAll("\",\"content\":\"") catch return GroqError.OutOfMemory;
        try writeJsonString(w, msg.content);
        w.writeAll("\"}") catch return GroqError.OutOfMemory;
    }
    w.writeAll("]}") catch return GroqError.OutOfMemory;
    return list.toOwnedSlice() catch return GroqError.OutOfMemory;
}

fn writeJsonString(w: anytype, s: []const u8) GroqError!void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch return GroqError.OutOfMemory,
            '\\' => w.writeAll("\\\\") catch return GroqError.OutOfMemory,
            '\n' => w.writeAll("\\n") catch return GroqError.OutOfMemory,
            '\r' => w.writeAll("\\r") catch return GroqError.OutOfMemory,
            '\t' => w.writeAll("\\t") catch return GroqError.OutOfMemory,
            else => {
                if (c < 0x20) {
                    w.print("\\u{x:0>4}", .{c}) catch return GroqError.OutOfMemory;
                } else {
                    w.writeByte(c) catch return GroqError.OutOfMemory;
                }
            },
        }
    }
}

fn parseChatResponse(allocator: std.mem.Allocator, raw: []const u8) GroqError!ChatResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return GroqError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return GroqError.InvalidJson;

    const model_val = root.object.get("model") orelse return GroqError.InvalidJson;
    const model = switch (model_val) {
        .string => |s| allocator.dupe(u8, s) catch return GroqError.OutOfMemory,
        else => return GroqError.InvalidJson,
    };
    errdefer allocator.free(model);

    const choices = root.object.get("choices") orelse return GroqError.InvalidJson;
    if (choices != .array or choices.array.items.len == 0) return GroqError.MissingContent;
    const first = choices.array.items[0];
    if (first != .object) return GroqError.InvalidJson;

    const message = first.object.get("message") orelse return GroqError.MissingContent;
    if (message != .object) return GroqError.InvalidJson;
    const content_val = message.object.get("content") orelse return GroqError.MissingContent;
    const content = switch (content_val) {
        .string => |s| allocator.dupe(u8, s) catch return GroqError.OutOfMemory,
        else => return GroqError.MissingContent,
    };
    errdefer allocator.free(content);

    var finish_reason: []u8 = allocator.dupe(u8, "stop") catch return GroqError.OutOfMemory;
    errdefer allocator.free(finish_reason);
    if (first.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            allocator.free(finish_reason);
            finish_reason = allocator.dupe(u8, fr.string) catch return GroqError.OutOfMemory;
        }
    }

    var prompt_tokens: u32 = 0;
    var completion_tokens: u32 = 0;
    var total_tokens: u32 = 0;
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |v| {
                if (v == .integer) prompt_tokens = @intCast(@max(v.integer, 0));
            }
            if (usage.object.get("completion_tokens")) |v| {
                if (v == .integer) completion_tokens = @intCast(@max(v.integer, 0));
            }
            if (usage.object.get("total_tokens")) |v| {
                if (v == .integer) total_tokens = @intCast(@max(v.integer, 0));
            }
        }
    }

    return .{
        .allocator = allocator,
        .content = content,
        .model = model,
        .finish_reason = finish_reason,
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .total_tokens = total_tokens,
    };
}

pub fn findModel(id: []const u8) ?Model {
    for (curated_models) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "json escape roundtrip shape" {
    const alloc = std.testing.allocator;
    const body = try buildRequestJson(alloc, .{
        .model = "llama-3.1-8b-instant",
        .messages = &[_]Message{
            .{ .role = .system, .content = "Be brief" },
            .{ .role = .user, .content = "say \"hi\"\nnow" },
        },
        .temperature = 0.4,
        .max_tokens = 32,
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "llama-3.1-8b-instant") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hi\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "parse sample groq response" {
    const alloc = std.testing.allocator;
    const sample =
        \\{"id":"x","model":"llama-3.1-8b-instant","choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}
    ;
    var resp = try parseChatResponse(alloc, sample);
    defer resp.deinit();
    try std.testing.expectEqualStrings("Hello", resp.content);
    try std.testing.expectEqualStrings("llama-3.1-8b-instant", resp.model);
    try std.testing.expectEqual(@as(u32, 11), resp.total_tokens);
}

test "curated models non-empty default" {
    try std.testing.expect(curated_models.len >= 4);
    try std.testing.expect(findModel(default_model) != null);
}
