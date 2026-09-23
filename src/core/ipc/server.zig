const std = @import("std");
const compat = @import("../compat.zig");
const builtin = @import("builtin");
const json = std.json;
const ipc_c_api = @import("../editor/c_api.zig");
const editor_diff = @import("../editor/diff.zig");
const agent_runtime = @import("agent_runtime.zig");
const fs_watch = @import("fs_watch.zig");
const workspace_tools = @import("../agent/framework/workspace_tools.zig");

// std.net was removed in Zig 0.17; use the compat shims backed by raw POSIX.
const TcpServer = compat.TcpServer;
const TcpConnection = compat.TcpConnection;

pub const IpcMessage = struct {
    id: u64,
    method: []const u8,
    params: ?json.Value = null,
};

pub const IpcResponse = struct {
    id: u64,
    result: ?json.Value = null,
    err: ?[]const u8 = null,
};

const max_connections: u32 = 64;
var active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const EditorRecord = struct {
    owner: u64,
    handle: ipc_c_api.EditorHandle,
};

const EditorRegistry = struct {
    mutex: compat.Mutex = .init,
    next_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    handles: std.AutoHashMapUnmanaged(u64, EditorRecord) = .{},

    fn create(self: *EditorRegistry, owner: u64, text: []const u8) !u64 {
        const handle = ipc_c_api.hiide_editor_create() orelse return error.EditorCreateFailed;
        errdefer ipc_c_api.hiide_editor_destroy(handle);
        ipc_c_api.hiide_editor_load(handle, text.ptr, text.len);

        const id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) return error.EditorHandleExhausted;

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handles.put(std.heap.c_allocator, id, .{ .owner = owner, .handle = handle });
        return id;
    }

    fn get(self: *EditorRegistry, owner: u64, id: u64) !ipc_c_api.EditorHandle {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.handles.get(id) orelse return error.InvalidHandle;
        if (owner != 0 and record.owner != owner) return error.InvalidHandle;
        return record.handle;
    }

    fn destroy(self: *EditorRegistry, owner: u64, id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const kv = self.handles.fetchRemove(id) orelse return error.InvalidHandle;
        if (owner != 0 and kv.value.owner != owner) {
            try self.handles.put(std.heap.c_allocator, id, kv.value);
            return error.InvalidHandle;
        }
        ipc_c_api.hiide_editor_destroy(kv.value.handle);
    }

    fn destroyOwner(self: *EditorRegistry, owner: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            var victim: ?u64 = null;
            var it = self.handles.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.owner == owner) {
                    victim = entry.key_ptr.*;
                    break;
                }
            }
            const id = victim orelse break;
            if (self.handles.fetchRemove(id)) |kv| {
                ipc_c_api.hiide_editor_destroy(kv.value.handle);
            } else break;
        }
    }
};

var editor_registry = EditorRegistry{};

/// Wire protocol: newline-delimited JSON.
/// The client writes exactly one JSON object per line; the server replies with
/// one JSON object per line. `err` strings are always static (never freed);
/// every string placed inside `result` is allocator-owned and released by
/// `deinitValue` after the response has been serialized.
pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    listener: TcpServer,
    port: u16,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, port: u16) !IpcServer {
        const server = try TcpServer.init(port);
        return .{
            .allocator = allocator,
            .listener = server,
            .port = port,
            .running = true,
        };
    }

    pub fn deinit(self: *IpcServer) void {
        self.running = false;
        self.listener.deinit();
    }

    pub fn run(self: *IpcServer) !void {
        while (self.running) {
            const connection = self.listener.accept() catch |err| {
                if (err == error.AcceptFailed) continue;
                return err;
            };

            const previous = active_connections.fetchAdd(1, .acq_rel);
            if (previous >= max_connections) {
                _ = active_connections.fetchSub(1, .acq_rel);
                connection.stream.close();
                continue;
            }

            const allocator = self.allocator;
            std.debug.print("IPC: accepted connection\n", .{});
            const thread = std.Thread.spawn(.{}, handleConnection, .{ connection, allocator }) catch {
                _ = active_connections.fetchSub(1, .acq_rel);
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }
};

fn handleConnection(conn: TcpConnection, allocator: std.mem.Allocator) void {
    defer _ = active_connections.fetchSub(1, .acq_rel);
    defer conn.stream.close();

    // File-watcher pushes share this socket: every write (responses and fs
    // events) goes through this mutex so lines never interleave.
    var write_mutex: compat.Mutex = .init;
    const conn_id = fs_watch.newConnectionId();
    defer editor_registry.destroyOwner(conn_id);
    defer fs_watch.unsubscribeAll(conn_id);

    var buf: [65536]u8 = undefined;
    var pending = compat.ManagedArrayList(u8).init(allocator);
    defer pending.deinit();

    const max_pending = 2 * 1024 * 1024; // keep server/client response limits aligned
    const max_line = 2 * 1024 * 1024;

    while (true) {
        const n = conn.stream.read(&buf) catch break;
        if (n == 0) break;
        pending.appendSlice(buf[0..n]) catch break;
        if (pending.items.len > max_pending) break;

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |nl| {
            const line = pending.items[start..nl];
            start = nl + 1;
            if (line.len == 0) continue;
            if (line.len > max_line) {
                writeResponse(allocator, conn, &write_mutex, IpcResponse{ .id = 0, .err = "line too large" });
                return;
            }
            handleLine(allocator, conn, line, &write_mutex, conn_id);
        }

        // Keep the (possibly partial) remainder for the next read.
        const rem = pending.items.len - start;
        std.mem.copyForwards(u8, pending.items[0..rem], pending.items[start..]);
        pending.shrinkRetainingCapacity(rem);
    }
}

/// Per-connection context needed by dispatch methods that interact with the
/// outside world beyond a plain response (file-watcher subscriptions).
const DispatchContext = struct {
    conn: TcpConnection,
    write_mutex: *compat.Mutex,
    conn_id: u64,
};

fn handleLine(
    allocator: std.mem.Allocator,
    conn: TcpConnection,
    line: []const u8,
    write_mutex: *compat.Mutex,
    conn_id: u64,
) void {
    var parsed = json.parseFromSlice(IpcMessage, allocator, line, .{}) catch |err| {
        writeResponse(allocator, conn, write_mutex, IpcResponse{ .id = 0, .err = @errorName(err) });
        return;
    };
    defer parsed.deinit();

    var ctx = DispatchContext{ .conn = conn, .write_mutex = write_mutex, .conn_id = conn_id };
    var resp = dispatch(allocator, parsed.value, &ctx) catch |err| {
        writeResponse(allocator, conn, write_mutex, IpcResponse{ .id = parsed.value.id, .err = @errorName(err) });
        return;
    };
    writeResponse(allocator, conn, write_mutex, resp);
    cleanupResponse(allocator, &resp);
}

fn writeResponse(
    allocator: std.mem.Allocator,
    conn: TcpConnection,
    write_mutex: *compat.Mutex,
    resp: IpcResponse,
) void {
    const resp_bytes = compat.jsonStringifyAlloc(allocator, resp, .{}) catch return;
    defer allocator.free(resp_bytes);
    write_mutex.lock();
    defer write_mutex.unlock();
    conn.stream.writeAll(resp_bytes) catch {};
    conn.stream.writeAll("\n") catch {};
}

/// Recursively releases every allocator-owned value inside a response result.
fn cleanupResponse(allocator: std.mem.Allocator, resp: *IpcResponse) void {
    if (resp.result) |*value| {
        deinitValue(allocator, value);
    }
}

fn deinitValue(allocator: std.mem.Allocator, value: *json.Value) void {
    switch (value.*) {
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| deinitValue(allocator, entry.value_ptr);
            obj.deinit(allocator);
        },
        .array => |*arr| {
            for (arr.items) |*item| deinitValue(allocator, item);
            arr.deinit();
        },
        .string => |s| allocator.free(s),
        else => {},
    }
}

fn errResp(id: u64, msg: []const u8) IpcResponse {
    return .{ .id = id, .err = msg };
}

fn okResp(id: u64, value: json.Value) IpcResponse {
    return .{ .id = id, .result = value };
}

/// Releases the strings inside a map and the map storage itself.
fn deinitObject(allocator: std.mem.Allocator, map: *json.ObjectMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        var value = entry.value_ptr.*;
        deinitValue(allocator, &value);
    }
    map.deinit(allocator);
}

fn buildObj(allocator: std.mem.Allocator, pairs: []const struct { []const u8, json.Value }) !json.ObjectMap {
    var map: json.ObjectMap = .empty;
    errdefer deinitObject(allocator, &map);
    for (pairs) |pair| {
        try map.put(allocator, pair[0], pair[1]);
    }
    return map;
}

fn objParams(req: IpcMessage) !json.ObjectMap {
    const params = req.params orelse return error.MissingParams;
    return switch (params) {
        .object => |obj| obj,
        else => error.InvalidParams,
    };
}

fn intValue(value: json.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        else => error.InvalidParam,
    };
}

fn stringValue(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidParam,
    };
}

fn ownerId(ctx: ?*DispatchContext) u64 {
    return if (ctx) |dctx| dctx.conn_id else 0;
}

fn handleValue(ctx: ?*DispatchContext, value: json.Value) !ipc_c_api.EditorHandle {
    const raw = try intValue(value);
    if (raw < 1) return error.InvalidHandle;
    return editor_registry.get(ownerId(ctx), @intCast(raw));
}

fn paramHandle(ctx: ?*DispatchContext, obj: json.ObjectMap, key: []const u8) !ipc_c_api.EditorHandle {
    const value = obj.get(key) orelse return error.MissingHandle;
    return handleValue(ctx, value);
}

fn paramUint(obj: json.ObjectMap, key: []const u8) !usize {
    const value = obj.get(key) orelse return error.MissingParam;
    const raw = try intValue(value);
    if (raw < 0) return error.InvalidParam;
    return @intCast(raw);
}

fn paramStr(obj: json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingParam;
    return stringValue(value);
}

fn dupStr(allocator: std.mem.Allocator, s: []const u8) !json.Value {
    return .{ .string = try allocator.dupe(u8, s) };
}

fn dispatch(allocator: std.mem.Allocator, req: IpcMessage, ctx: ?*DispatchContext) !IpcResponse {
    if (req.method.len == 0) return errResp(req.id, "missing method");

    if (std.mem.eql(u8, req.method, "hello")) {
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "service", try dupStr(allocator, "hiide-zig-engine") },
            .{ "version", try dupStr(allocator, "0.1.0") },
        }) });
    }

    if (std.mem.eql(u8, req.method, "ping")) {
        return okResp(req.id, try dupStr(allocator, "pong"));
    }

    if (std.mem.eql(u8, req.method, "editor.load")) {
        const raw = req.params orelse return errResp(req.id, "missing text");
        const text = stringValue(raw) catch return errResp(req.id, "text must be a string");
        const handle_id = editor_registry.create(ownerId(ctx), text) catch return errResp(req.id, "editor create failed");
        const handle = editor_registry.get(ownerId(ctx), handle_id) catch return errResp(req.id, "editor create failed");
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "handle", .{ .integer = @intCast(handle_id) } },
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
            .{ "lines", .{ .integer = @intCast(ipc_c_api.hiide_editor_line_count(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.get_text")) {
        const raw = req.params orelse return errResp(req.id, "missing handle");
        const handle = handleValue(ctx, raw) catch return errResp(req.id, "invalid handle");
        const text_ptr = ipc_c_api.hiide_editor_get_text(handle) orelse return errResp(req.id, "get text failed");
        const text = std.mem.span(text_ptr);
        defer ipc_c_api.hiide_editor_free(@constCast(text_ptr));
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "text", try dupStr(allocator, text) },
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.insert")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const pos = try paramUint(params, "pos");
        const text = try paramStr(params, "text");
        ipc_c_api.hiide_editor_insert(handle, pos, text.ptr, text.len);
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.delete")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const pos = try paramUint(params, "pos");
        const len = try paramUint(params, "len");
        ipc_c_api.hiide_editor_delete(handle, pos, len);
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.undo")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        ipc_c_api.hiide_editor_undo(handle);
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{}) });
    }

    if (std.mem.eql(u8, req.method, "editor.redo")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        ipc_c_api.hiide_editor_redo(handle);
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{}) });
    }

    if (std.mem.eql(u8, req.method, "editor.line_count")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "lines", .{ .integer = @intCast(ipc_c_api.hiide_editor_line_count(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.size")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.search")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const query = try paramStr(params, "query");
        const max = 10000;
        const out = try allocator.alloc(ipc_c_api.SearchResult, max);
        defer allocator.free(out);
        const count = ipc_c_api.hiide_editor_search(handle, query.ptr, query.len, out.ptr, max);

        var arr = json.Array.init(allocator);
        errdefer {
            for (arr.items) |*item| deinitValue(allocator, item);
            arr.deinit();
        }
        for (out[0..count]) |r| {
            var map: json.ObjectMap = .empty;
            errdefer deinitObject(allocator, &map);
            try map.put(allocator, "line", .{ .integer = @intCast(r.line) });
            try map.put(allocator, "col", .{ .integer = @intCast(r.col) });
            try map.put(allocator, "text", try dupStr(allocator, query));
            try arr.append(.{ .object = map });
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "results", .{ .array = arr } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.highlight")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const lang = try paramStr(params, "lang");
        const html_ptr = ipc_c_api.hiide_editor_highlight(handle, lang.ptr, lang.len) orelse return errResp(req.id, "highlight failed");
        const html = std.mem.span(html_ptr);
        defer ipc_c_api.hiide_editor_free(@constCast(html_ptr));
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "html", try dupStr(allocator, html) },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.destroy")) {
        const params = try objParams(req);
        const value = params.get("handle") orelse return errResp(req.id, "missing handle");
        const raw = intValue(value) catch return errResp(req.id, "invalid handle");
        if (raw < 1) return errResp(req.id, "invalid handle");
        editor_registry.destroy(ownerId(ctx), @intCast(raw)) catch return errResp(req.id, "invalid handle");
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "ok", .{ .bool = true } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.apply_text")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const new_text = try paramStr(params, "text");

        // Minimal single-region edit computed natively in bytes: longest
        // common prefix + longest common suffix, then one delete + one insert.
        // This replaces the Dart-side diff + UTF-8 offset conversion with a
        // single IPC round trip.
        const old_ptr = ipc_c_api.hiide_editor_get_text(handle);
        const old = if (old_ptr) |p| std.mem.span(p) else "";
        defer {
            if (old_ptr) |p| ipc_c_api.hiide_editor_free(@constCast(p));
        }

        var prefix: usize = 0;
        const max_prefix = @min(old.len, new_text.len);
        while (prefix < max_prefix and old[prefix] == new_text[prefix]) prefix += 1;

        var old_suf = old.len;
        var new_suf = new_text.len;
        while (old_suf > prefix and new_suf > prefix and old[old_suf - 1] == new_text[new_suf - 1]) {
            old_suf -= 1;
            new_suf -= 1;
        }

        if (old_suf > prefix) ipc_c_api.hiide_editor_delete(handle, prefix, old_suf - prefix);
        if (new_suf > prefix) ipc_c_api.hiide_editor_insert(handle, prefix, new_text.ptr + prefix, new_suf - prefix);

        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "size", .{ .integer = @intCast(ipc_c_api.hiide_editor_size(handle)) } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "editor.diff_lines")) {
        const params = try objParams(req);
        const handle = try paramHandle(ctx, params, "handle");
        const disk_text = try paramStr(params, "disk_text");

        const old_ptr = ipc_c_api.hiide_editor_get_text(handle);
        const buffer_text = if (old_ptr) |p| std.mem.span(p) else "";
        defer {
            if (old_ptr) |p| ipc_c_api.hiide_editor_free(@constCast(p));
        }

        const regions = editor_diff.computeRegions(allocator, disk_text, buffer_text) catch |err| {
            return errResp(req.id, @errorName(err));
        };
        defer allocator.free(regions);

        var arr = json.Array.init(allocator);
        errdefer {
            for (arr.items) |*item| deinitValue(allocator, item);
            arr.deinit();
        }
        for (regions) |r| {
            var map = json.ObjectMap.empty;
            errdefer deinitObject(allocator, &map);
            try map.put(allocator, "line", .{ .integer = @intCast(r.line) });
            try map.put(allocator, "kind", try dupStr(allocator, @tagName(r.kind)));
            try map.put(allocator, "count", .{ .integer = @intCast(r.count) });
            try arr.append(.{ .object = map });
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "changes", .{ .array = arr } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "workspace.search")) {
        const params = try objParams(req);
        const root = try paramStr(params, "root");
        const query = try paramStr(params, "query");
        const max_results: usize = blk: {
            const value = params.get("max_results") orelse break :blk 200;
            if (value.integer <= 0) break :blk 200;
            break :blk @intCast(value.integer);
        };

        const hits = try workspace_tools.workspaceSearch(allocator, root, query, max_results, false);
        defer {
            for (hits) |hit| {
                allocator.free(hit.path);
                allocator.free(hit.text);
            }
            allocator.free(hits);
        }

        var arr = json.Array.init(allocator);
        errdefer {
            for (arr.items) |*item| deinitValue(allocator, item);
            arr.deinit();
        }
        for (hits) |hit| {
            var map = json.ObjectMap.empty;
            errdefer deinitObject(allocator, &map);
            try map.put(allocator, "path", try dupStr(allocator, hit.path));
            try map.put(allocator, "line", .{ .integer = @intCast(hit.line) });
            try map.put(allocator, "col", .{ .integer = @intCast(hit.col) });
            try map.put(allocator, "text", try dupStr(allocator, hit.text));
            try arr.append(.{ .object = map });
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "results", .{ .array = arr } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "workspace.tree")) {
        const params = try objParams(req);
        const root = try paramStr(params, "root");
        const max_entries: usize = blk: {
            const value = params.get("max_entries") orelse break :blk 50_000;
            if (value.integer <= 0) break :blk 50_000;
            break :blk @intCast(value.integer);
        };

        const entries = try workspace_tools.workspaceTree(allocator, root, max_entries);
        defer {
            for (entries) |e| {
                allocator.free(e.name);
                allocator.free(e.path);
            }
            allocator.free(entries);
        }

        var arr = compat.ManagedArrayList(json.Value).init(allocator);
        errdefer {
            for (arr.items) |*item| deinitValue(allocator, item);
            arr.deinit();
        }
        for (entries) |e| {
            var map = json.ObjectMap.empty;
            errdefer deinitObject(allocator, &map);
            try map.put(allocator, "name", try dupStr(allocator, e.name));
            try map.put(allocator, "path", try dupStr(allocator, e.path));
            try map.put(allocator, "kind", try dupStr(allocator, if (e.kind == .directory) "directory" else "file"));
            try map.put(allocator, "size", .{ .integer = @intCast(@min(e.size, std.math.maxInt(i64))) });
            try arr.append(.{ .object = map });
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "entries", .{ .array = arr } },
            .{ "truncated", .{ .bool = entries.len >= max_entries } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "watch.subscribe")) {
        const params = try objParams(req);
        const root = try paramStr(params, "root");
        const dctx = ctx orelse return errResp(req.id, "no connection");
        fs_watch.ensureStarted();
        fs_watch.subscribe(dctx.conn_id, root, dctx.conn, dctx.write_mutex) catch |err| {
            return errResp(req.id, @errorName(err));
        };
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{}) });
    }

    if (std.mem.eql(u8, req.method, "watch.unsubscribe")) {
        const dctx = ctx orelse return errResp(req.id, "no connection");
        fs_watch.unsubscribeAll(dctx.conn_id);
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{}) });
    }

    if (std.mem.eql(u8, req.method, "agent.tool.execute")) {
        const params = try objParams(req);
        const tool = try paramStr(params, "tool");
        const input = try paramStr(params, "input");
        const workspace_root = try paramStr(params, "workspace_root");
        const timeout_ms: ?u32 = blk: {
            const value = params.get("timeout_ms") orelse break :blk null;
            const raw = intValue(value) catch return errResp(req.id, "timeout_ms must be an integer");
            if (raw <= 0) break :blk null;
            break :blk @intCast(@min(raw, 600_000));
        };

        // Tool-level failures are NOT transport errors: the model must see the
        // error text as tool output so it can react (read again, retry, ...).
        const resp = agent_runtime.executeTool(allocator, tool, input, workspace_root, timeout_ms) catch |err| {
            return errResp(req.id, @errorName(err));
        };
        defer {
            allocator.free(resp.output);
            allocator.free(resp.error_message);
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "ok", .{ .bool = resp.ok } },
            .{ "output", try dupStr(allocator, resp.output) },
            .{ "error", try dupStr(allocator, resp.error_message) },
        }) });
    }

    var err_buf: [128]u8 = undefined;
    const err_msg = std.fmt.bufPrint(&err_buf, "unknown method: {s}", .{req.method}) catch "unknown method";
    return errResp(req.id, err_msg);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn runDispatch(allocator: std.mem.Allocator, method: []const u8, params: ?json.Value) !IpcResponse {
    return dispatch(allocator, .{ .id = 1, .method = method, .params = params }, null);
}

fn expectNoErr(resp: IpcResponse) !void {
    if (resp.err) |e| {
        std.debug.print("unexpected error: {s}\n", .{e});
        return error.UnexpectedError;
    }
}

test "dispatch: malformed params are rejected without crashing" {
    var bad = try runDispatch(testing.allocator, "editor.load", .{ .integer = 42 });
    defer cleanupResponse(testing.allocator, &bad);
    try testing.expectEqualStrings("text must be a string", bad.err.?);

    var badParams = try runDispatch(testing.allocator, "editor.insert", .{ .string = "not-an-object" });
    defer cleanupResponse(testing.allocator, &badParams);
    try testing.expectEqualStrings("InvalidParams", badParams.err.?);
}

test "dispatch: forged editor handles are rejected" {
    var response = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = 42 });
    defer cleanupResponse(testing.allocator, &response);
    try testing.expectEqualStrings("invalid handle", response.err.?);
}

test "dispatch: hello and ping" {
    var resp = try runDispatch(testing.allocator, "hello", null);
    defer cleanupResponse(testing.allocator, &resp);
    try expectNoErr(resp);
    try testing.expectEqualStrings("hiide-zig-engine", resp.result.?.object.get("service").?.string);
    try testing.expectEqualStrings("0.1.0", resp.result.?.object.get("version").?.string);

    var ping = try runDispatch(testing.allocator, "ping", null);
    defer cleanupResponse(testing.allocator, &ping);
    try expectNoErr(ping);
    try testing.expectEqualStrings("pong", ping.result.?.string);
}

test "dispatch: editor load/get_text roundtrip" {
    const text = "hello\nworld\n";
    var resp = try runDispatch(testing.allocator, "editor.load", .{ .string = text });
    defer cleanupResponse(testing.allocator, &resp);
    try expectNoErr(resp);
    const handle: i64 = resp.result.?.object.get("handle").?.integer;
    try testing.expectEqual(@as(i64, @intCast(text.len)), resp.result.?.object.get("size").?.integer);
    try testing.expectEqual(@as(i64, 3), resp.result.?.object.get("lines").?.integer);

    var get = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = handle });
    defer cleanupResponse(testing.allocator, &get);
    try expectNoErr(get);
    try testing.expectEqualStrings(text, get.result.?.object.get("text").?.string);
}

test "dispatch: editor insert/delete/search" {
    var resp = try runDispatch(testing.allocator, "editor.load", .{ .string = "hello world" });
    defer cleanupResponse(testing.allocator, &resp);
    const handle: i64 = resp.result.?.object.get("handle").?.integer;

    const insert_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "pos", .{ .integer = 5 } },
        .{ "text", .{ .string = try testing.allocator.dupe(u8, " XYZ") } },
    });
    var insert_params_resp = IpcResponse{ .id = 0, .result = .{ .object = insert_params } };
    defer cleanupResponse(testing.allocator, &insert_params_resp);
    var ins = try runDispatch(testing.allocator, "editor.insert", .{ .object = insert_params });
    defer cleanupResponse(testing.allocator, &ins);
    try expectNoErr(ins);
    try testing.expectEqual(@as(i64, 15), ins.result.?.object.get("size").?.integer);

    var get = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = handle });
    defer cleanupResponse(testing.allocator, &get);
    try testing.expectEqualStrings("hello XYZ world", get.result.?.object.get("text").?.string);

    const del_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "pos", .{ .integer = 5 } },
        .{ "len", .{ .integer = 4 } },
    });
    var del_params_resp = IpcResponse{ .id = 0, .result = .{ .object = del_params } };
    defer cleanupResponse(testing.allocator, &del_params_resp);
    var del = try runDispatch(testing.allocator, "editor.delete", .{ .object = del_params });
    defer cleanupResponse(testing.allocator, &del);
    try expectNoErr(del);

    const search_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "query", .{ .string = try testing.allocator.dupe(u8, "world") } },
    });
    var search_params_resp = IpcResponse{ .id = 0, .result = .{ .object = search_params } };
    defer cleanupResponse(testing.allocator, &search_params_resp);
    var search = try runDispatch(testing.allocator, "editor.search", .{ .object = search_params });
    defer cleanupResponse(testing.allocator, &search);
    try expectNoErr(search);
    const results = search.result.?.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqual(@as(i64, 1), results.items[0].object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 7), results.items[0].object.get("col").?.integer);
}

test "dispatch: editor line_count and destroy" {
    var resp = try runDispatch(testing.allocator, "editor.load", .{ .string = "a\nb\nc" });
    defer cleanupResponse(testing.allocator, &resp);
    const handle: i64 = resp.result.?.object.get("handle").?.integer;

    const lc_params = try buildObj(testing.allocator, &.{.{ "handle", .{ .integer = handle } }});
    var lc_params_resp = IpcResponse{ .id = 0, .result = .{ .object = lc_params } };
    defer cleanupResponse(testing.allocator, &lc_params_resp);
    var lc = try runDispatch(testing.allocator, "editor.line_count", .{ .object = lc_params });
    defer cleanupResponse(testing.allocator, &lc);
    try expectNoErr(lc);
    try testing.expectEqual(@as(i64, 3), lc.result.?.object.get("lines").?.integer);

    var destroy = try runDispatch(testing.allocator, "editor.destroy", .{ .object = lc_params });
    defer cleanupResponse(testing.allocator, &destroy);
    try expectNoErr(destroy);
    try testing.expectEqual(true, destroy.result.?.object.get("ok").?.bool);
}

test "dispatch: unknown method" {
    var resp = try runDispatch(testing.allocator, "nope", null);
    defer cleanupResponse(testing.allocator, &resp);
    try testing.expect(resp.err != null);
    try testing.expect(std.mem.startsWith(u8, resp.err.?, "unknown method"));
}

test "dispatch: agent.tool.execute runs framework tools" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    const write_params = try buildObj(testing.allocator, &.{
        .{ "tool", .{ .string = try testing.allocator.dupe(u8, "file.write") } },
        .{ "input", .{ .string = try testing.allocator.dupe(u8, "{\"path\":\"a.txt\",\"content\":\"ipc dispatch ok\"}") } },
        .{ "workspace_root", .{ .string = try testing.allocator.dupe(u8, root) } },
    });
    var write_params_resp = IpcResponse{ .id = 0, .result = .{ .object = write_params } };
    defer cleanupResponse(testing.allocator, &write_params_resp);
    var write = try runDispatch(testing.allocator, "agent.tool.execute", .{ .object = write_params });
    defer cleanupResponse(testing.allocator, &write);
    try expectNoErr(write);
    try testing.expectEqual(true, write.result.?.object.get("ok").?.bool);

    const read_params = try buildObj(testing.allocator, &.{
        .{ "tool", .{ .string = try testing.allocator.dupe(u8, "file.read") } },
        .{ "input", .{ .string = try testing.allocator.dupe(u8, "a.txt") } },
        .{ "workspace_root", .{ .string = try testing.allocator.dupe(u8, root) } },
    });
    var read_params_resp = IpcResponse{ .id = 0, .result = .{ .object = read_params } };
    defer cleanupResponse(testing.allocator, &read_params_resp);
    var read = try runDispatch(testing.allocator, "agent.tool.execute", .{ .object = read_params });
    defer cleanupResponse(testing.allocator, &read);
    try expectNoErr(read);
    try testing.expectEqual(true, read.result.?.object.get("ok").?.bool);
    try testing.expectEqualStrings("ipc dispatch ok", read.result.?.object.get("output").?.string);
}

test "dispatch: agent.tool.execute reports tool failure in result, not err" {
    const params = try buildObj(testing.allocator, &.{
        .{ "tool", .{ .string = try testing.allocator.dupe(u8, "file.read") } },
        .{ "input", .{ .string = try testing.allocator.dupe(u8, "missing.txt") } },
        .{ "workspace_root", .{ .string = try testing.allocator.dupe(u8, ".") } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);
    var resp = try runDispatch(testing.allocator, "agent.tool.execute", .{ .object = params });
    defer cleanupResponse(testing.allocator, &resp);
    try expectNoErr(resp);
    try testing.expectEqual(false, resp.result.?.object.get("ok").?.bool);
    try testing.expect(std.mem.indexOf(u8, resp.result.?.object.get("error").?.string, "file not found") != null);
}

test "dispatch: editor.apply_text syncs via a minimal native edit" {
    const original = "merhaba dünya\nikinci satır";
    var resp = try runDispatch(testing.allocator, "editor.load", .{ .string = original });
    defer cleanupResponse(testing.allocator, &resp);
    const handle: i64 = resp.result.?.object.get("handle").?.integer;

    // Insert " güzel" before "dünya" — a non-ASCII middle edit.
    const after = "merhaba güzel dünya\nikinci satır";
    const params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "text", .{ .string = try testing.allocator.dupe(u8, after) } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);
    var applied = try runDispatch(testing.allocator, "editor.apply_text", .{ .object = params });
    defer cleanupResponse(testing.allocator, &applied);
    try expectNoErr(applied);

    var get = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = handle });
    defer cleanupResponse(testing.allocator, &get);
    try expectNoErr(get);
    try testing.expectEqualStrings(after, get.result.?.object.get("text").?.string);

    // Deleting the middle (empty replacement) also works.
    const shortened = "merhaba dünya";
    const del_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "text", .{ .string = try testing.allocator.dupe(u8, shortened) } },
    });
    var del_params_resp = IpcResponse{ .id = 0, .result = .{ .object = del_params } };
    defer cleanupResponse(testing.allocator, &del_params_resp);
    var del = try runDispatch(testing.allocator, "editor.apply_text", .{ .object = del_params });
    defer cleanupResponse(testing.allocator, &del);
    try expectNoErr(del);

    var get2 = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = handle });
    defer cleanupResponse(testing.allocator, &get2);
    try expectNoErr(get2);
    try testing.expectEqualStrings(shortened, get2.result.?.object.get("text").?.string);

    // Full replacement of an empty buffer works too.
    var empty = try runDispatch(testing.allocator, "editor.load", .{ .string = "" });
    defer cleanupResponse(testing.allocator, &empty);
    const empty_handle: i64 = empty.result.?.object.get("handle").?.integer;
    const fill_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = empty_handle } },
        .{ "text", .{ .string = try testing.allocator.dupe(u8, "fresh") } },
    });
    var fill_params_resp = IpcResponse{ .id = 0, .result = .{ .object = fill_params } };
    defer cleanupResponse(testing.allocator, &fill_params_resp);
    var fill = try runDispatch(testing.allocator, "editor.apply_text", .{ .object = fill_params });
    defer cleanupResponse(testing.allocator, &fill);
    try expectNoErr(fill);
    var get3 = try runDispatch(testing.allocator, "editor.get_text", .{ .integer = empty_handle });
    defer cleanupResponse(testing.allocator, &get3);
    try expectNoErr(get3);
    try testing.expectEqualStrings("fresh", get3.result.?.object.get("text").?.string);
}

test "dispatch: editor.diff_lines returns line change regions" {
    const original = "alpha\nbeta\ngamma\n";
    var resp = try runDispatch(testing.allocator, "editor.load", .{ .string = original });
    defer cleanupResponse(testing.allocator, &resp);
    const handle: i64 = resp.result.?.object.get("handle").?.integer;

    // Identical disk text → no changes.
    const same_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "disk_text", .{ .string = try testing.allocator.dupe(u8, original) } },
    });
    var same_params_resp = IpcResponse{ .id = 0, .result = .{ .object = same_params } };
    defer cleanupResponse(testing.allocator, &same_params_resp);
    var same = try runDispatch(testing.allocator, "editor.diff_lines", .{ .object = same_params });
    defer cleanupResponse(testing.allocator, &same);
    try expectNoErr(same);
    try testing.expectEqual(@as(usize, 0), same.result.?.object.get("changes").?.array.items.len);

    // Disk has an extra trailing line → a deleted region at the boundary.
    const del_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "disk_text", .{ .string = try testing.allocator.dupe(u8, "alpha\nbeta\ngamma\ndelta\n") } },
    });
    var del_params_resp = IpcResponse{ .id = 0, .result = .{ .object = del_params } };
    defer cleanupResponse(testing.allocator, &del_params_resp);
    var del = try runDispatch(testing.allocator, "editor.diff_lines", .{ .object = del_params });
    defer cleanupResponse(testing.allocator, &del);
    try expectNoErr(del);
    const del_changes = del.result.?.object.get("changes").?.array;
    try testing.expectEqual(@as(usize, 1), del_changes.items.len);
    try testing.expectEqual(@as(i64, 3), del_changes.items[0].object.get("line").?.integer);
    try testing.expectEqualStrings("deleted", del_changes.items[0].object.get("kind").?.string);
    try testing.expectEqual(@as(i64, 1), del_changes.items[0].object.get("count").?.integer);

    // Disk differs in the middle → a modified region.
    const mod_params = try buildObj(testing.allocator, &.{
        .{ "handle", .{ .integer = handle } },
        .{ "disk_text", .{ .string = try testing.allocator.dupe(u8, "alpha\nBETA\ngamma\n") } },
    });
    var mod_params_resp = IpcResponse{ .id = 0, .result = .{ .object = mod_params } };
    defer cleanupResponse(testing.allocator, &mod_params_resp);
    var mod = try runDispatch(testing.allocator, "editor.diff_lines", .{ .object = mod_params });
    defer cleanupResponse(testing.allocator, &mod);
    try expectNoErr(mod);
    const mod_changes = mod.result.?.object.get("changes").?.array;
    try testing.expectEqual(@as(usize, 1), mod_changes.items.len);
    try testing.expectEqual(@as(i64, 1), mod_changes.items[0].object.get("line").?.integer);
    try testing.expectEqualStrings("modified", mod_changes.items[0].object.get("kind").?.string);
}

test "dispatch: workspace.tree returns sorted relative entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "bb" });
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.zig", .data = "aaaaa" });
    const root = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(root);

    const params = try buildObj(testing.allocator, &.{
        .{ "root", .{ .string = try testing.allocator.dupe(u8, root) } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);
    var resp = try runDispatch(testing.allocator, "workspace.tree", .{ .object = params });
    defer cleanupResponse(testing.allocator, &resp);
    try expectNoErr(resp);

    const entries = resp.result.?.object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("src", entries.items[0].object.get("path").?.string);
    try testing.expectEqualStrings("directory", entries.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("b.txt", entries.items[1].object.get("path").?.string);
    try testing.expectEqualStrings("file", entries.items[1].object.get("kind").?.string);
    try testing.expectEqualStrings("src/a.zig", entries.items[2].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 5), entries.items[2].object.get("size").?.integer);
}

test "dispatch: watch.subscribe registers a subscriber over a socket" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var sv: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SocketPairFailed;
    defer {
        std.posix.close(sv[0]);
        std.posix.close(sv[1]);
    }
    var write_mutex: compat.Mutex = .init;
    const conn = compat.TcpConnection{
        .stream = compat.TcpStream{ .fd = sv[0] },
    };
    const id = fs_watch.newConnectionId();
    var ctx = DispatchContext{ .conn = conn, .write_mutex = &write_mutex, .conn_id = id };
    defer fs_watch.unsubscribeAll(id);

    const params = try buildObj(testing.allocator, &.{
        .{ "root", .{ .string = try testing.allocator.dupe(u8, ".") } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);

    var resp = try dispatch(testing.allocator, .{ .id = 7, .method = "watch.subscribe", .params = .{ .object = params } }, &ctx);
    defer cleanupResponse(testing.allocator, &resp);
    try expectNoErr(resp);

    var unsub = try dispatch(testing.allocator, .{ .id = 8, .method = "watch.unsubscribe", .params = null }, &ctx);
    defer cleanupResponse(testing.allocator, &unsub);
    try expectNoErr(unsub);
}

test "dispatch: watch.subscribe without a connection errors" {
    const params = try buildObj(testing.allocator, &.{
        .{ "root", .{ .string = try testing.allocator.dupe(u8, ".") } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);

    var resp = try dispatch(testing.allocator, .{ .id = 1, .method = "watch.subscribe", .params = .{ .object = params } }, null);
    defer cleanupResponse(testing.allocator, &resp);
    try testing.expect(resp.err != null);
    try testing.expectEqualStrings("no connection", resp.err.?);
}

test "dispatch: agent.tool.execute rejects unknown tools" {
    const params = try buildObj(testing.allocator, &.{
        .{ "tool", .{ .string = try testing.allocator.dupe(u8, "nope.tool") } },
        .{ "input", .{ .string = try testing.allocator.dupe(u8, "{}") } },
        .{ "workspace_root", .{ .string = try testing.allocator.dupe(u8, ".") } },
    });
    var params_resp = IpcResponse{ .id = 0, .result = .{ .object = params } };
    defer cleanupResponse(testing.allocator, &params_resp);
    var resp = try runDispatch(testing.allocator, "agent.tool.execute", .{ .object = params });
    defer cleanupResponse(testing.allocator, &resp);
    try testing.expect(resp.err != null);
    try testing.expect(std.mem.eql(u8, resp.err.?, "ToolNotFound"));
}
