const std = @import("std");
const compat = @import("../compat.zig");
const builtin = @import("builtin");
const json = std.json;
const agent_runtime = @import("agent_runtime.zig");
const fs_watch = @import("fs_watch.zig");
const workspace_tools = @import("../agent/framework/workspace_tools.zig");
const ipc_protocol = @import("protocol.zig");

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
    auth_token: ?[]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        auth_token: ?[]const u8,
    ) !IpcServer {
        const owned_auth_token = if (auth_token) |token| try allocator.dupe(u8, token) else null;
        errdefer if (owned_auth_token) |token| allocator.free(token);
        const server = try TcpServer.init(port);
        return .{
            .allocator = allocator,
            .listener = server,
            .port = port,
            .running = true,
            .auth_token = owned_auth_token,
        };
    }

    pub fn deinit(self: *IpcServer) void {
        self.running = false;
        self.listener.deinit();
        if (self.auth_token) |token| self.allocator.free(token);
        self.* = undefined;
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
            const connection_auth_token = if (self.auth_token) |token|
                allocator.dupe(u8, token) catch {
                    _ = active_connections.fetchSub(1, .acq_rel);
                    connection.stream.close();
                    continue;
                }
            else
                null;
            std.debug.print("IPC: accepted connection\n", .{});
            const thread = std.Thread.spawn(
                .{},
                handleConnection,
                .{ connection, allocator, connection_auth_token },
            ) catch {
                if (connection_auth_token) |token| allocator.free(token);
                _ = active_connections.fetchSub(1, .acq_rel);
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }
};

fn handleConnection(conn: TcpConnection, allocator: std.mem.Allocator, auth_token: ?[]u8) void {
    defer _ = active_connections.fetchSub(1, .acq_rel);
    defer conn.stream.close();
    defer if (auth_token) |token| allocator.free(token);

    // File-watcher pushes share this socket: every write (responses and fs
    // events) goes through this mutex so lines never interleave.
    var write_mutex: compat.Mutex = .init;
    const conn_id = fs_watch.newConnectionId();
    defer fs_watch.unsubscribeAll(conn_id);

    var buf: [65536]u8 = undefined;
    var pending = compat.ManagedArrayList(u8).init(allocator);
    defer pending.deinit();

    // Authentication is scoped to the TCP connection, not an individual
    // NDJSON line. Preserve the successful hello handshake for subsequent
    // requests on this same socket.
    var authenticated = auth_token == null;

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
            handleLine(allocator, conn, line, &write_mutex, conn_id, auth_token, &authenticated);
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
    auth_token: ?[]const u8,
    authenticated: bool,
};

fn handleLine(
    allocator: std.mem.Allocator,
    conn: TcpConnection,
    line: []const u8,
    write_mutex: *compat.Mutex,
    conn_id: u64,
    auth_token: ?[]u8,
    authenticated: *bool,
) void {
    var parsed = json.parseFromSlice(IpcMessage, allocator, line, .{}) catch |err| {
        writeResponse(allocator, conn, write_mutex, IpcResponse{ .id = 0, .err = @errorName(err) });
        return;
    };
    defer parsed.deinit();

    var ctx = DispatchContext{
        .conn = conn,
        .write_mutex = write_mutex,
        .conn_id = conn_id,
        .auth_token = auth_token,
        .authenticated = authenticated.*,
    };
    var resp = dispatch(allocator, parsed.value, &ctx) catch |err| {
        writeResponse(allocator, conn, write_mutex, IpcResponse{ .id = parsed.value.id, .err = @errorName(err) });
        return;
    };
    authenticated.* = ctx.authenticated;
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

fn authTokenMatches(expected: []const u8, params: ?json.Value) bool {
    const obj = switch (params orelse return false) {
        .object => |value| value,
        else => return false,
    };
    const supplied = obj.get("auth_token") orelse return false;
    const token = stringValue(supplied) catch return false;
    return std.mem.eql(u8, expected, token);
}

fn dispatch(allocator: std.mem.Allocator, req: IpcMessage, ctx: ?*DispatchContext) !IpcResponse {
    if (!std.mem.eql(u8, req.method, "hello")) {
        if (ctx) |dctx| {
            if (dctx.auth_token != null and !dctx.authenticated) {
                return errResp(req.id, "unauthorized");
            }
        }
    }

    if (req.method.len == 0) return errResp(req.id, "missing method");

    if (std.mem.eql(u8, req.method, "hello")) {
        if (ctx) |dctx| {
            if (dctx.auth_token) |expected| {
                if (!authTokenMatches(expected, req.params)) {
                    return errResp(req.id, "unauthorized");
                }
                dctx.authenticated = true;
            }
        }
        return okResp(req.id, .{ .object = try buildObj(allocator, &.{
            .{ "service", try dupStr(allocator, "hiide-zig-engine") },
            .{ "version", try dupStr(allocator, "0.1.0") },
            .{ "protocol_version", .{ .integer = ipc_protocol.protocol_version } },
            .{ "transport", try dupStr(allocator, "ndjson-json-rpc") },
            .{ "auth_required", .{ .bool = if (ctx) |dctx| dctx.auth_token != null else false } },
        }) });
    }

    if (std.mem.eql(u8, req.method, "ping")) {
        return okResp(req.id, try dupStr(allocator, "pong"));
    }

    if (std.mem.eql(u8, req.method, "workspace.search")) {
        const params = try objParams(req);
        const root = try paramStr(params, "root");
        const query = try paramStr(params, "query");
        const max_results: usize = blk: {
            const value = params.get("max_results") orelse break :blk 200;
            const raw = intValue(value) catch return errResp(req.id, "max_results must be an integer");
            if (raw <= 0) break :blk 200;
            break :blk @intCast(@min(raw, 10_000));
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
            const raw = intValue(value) catch return errResp(req.id, "max_entries must be an integer");
            if (raw <= 0) break :blk 50_000;
            break :blk @intCast(@min(raw, 50_000));
        };

        const entries = try workspace_tools.workspaceTree(allocator, root, max_entries);
        defer {
            for (entries) |e| {
                allocator.free(e.name);
                allocator.free(e.path);
            }
            allocator.free(entries);
        }

        var arr = json.Array.init(allocator);
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
            if (raw <= 0) return errResp(req.id, "timeout_ms must be greater than zero");
            break :blk @intCast(@min(raw, 600_000));
        };

        // Tool-level failures are NOT transport errors: the model must see the
        // error text as tool output so it can react (read again, retry, ...).
        std.debug.print("[diagnostic] IPC before agent runtime\n", .{});
        const resp = agent_runtime.executeTool(allocator, tool, input, workspace_root, timeout_ms) catch |err| {
            return errResp(req.id, @errorName(err));
        };
        std.debug.print("[diagnostic] IPC after agent runtime\n", .{});
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

test "dispatch: invalid numeric limits return errors instead of panicking" {
    const object_params: json.Value = .{ .object = blk: {
        var obj = json.ObjectMap.empty;
        try obj.put(testing.allocator, "root", .{ .string = "." });
        try obj.put(testing.allocator, "query", .{ .string = "x" });
        try obj.put(testing.allocator, "max_results", .{ .string = "not-a-number" });
        break :blk obj;
    } };
    var search = try runDispatch(testing.allocator, "workspace.search", object_params);
    defer cleanupResponse(testing.allocator, &search);
    try testing.expectEqualStrings("max_results must be an integer", search.err.?);

    var tree_obj: json.ObjectMap = .empty;
    try tree_obj.put(testing.allocator, "root", .{ .string = "." });
    try tree_obj.put(testing.allocator, "max_entries", .{ .bool = true });
    var tree = try runDispatch(testing.allocator, "workspace.tree", .{ .object = tree_obj });
    defer cleanupResponse(testing.allocator, &tree);
    try testing.expectEqualStrings("max_entries must be an integer", tree.err.?);
}

test "ipc auth token validation" {
    const params: json.Value = .{ .object = blk: {
        var obj = json.ObjectMap.empty;
        try obj.put(std.testing.allocator, "auth_token", .{ .string = "secret" });
        break :blk obj;
    }};
    defer @constCast(&params).object.deinit(std.testing.allocator);

    try std.testing.expect(authTokenMatches("secret", params));
    try std.testing.expect(!authTokenMatches("other", params));
    try std.testing.expect(!authTokenMatches("secret", null));
}

test "dispatch: authenticated connection stays authenticated after hello" {
    const allocator = testing.allocator;
    var params: json.ObjectMap = .empty;
    try params.put(allocator, "auth_token", .{ .string = "test-session-token" });
    defer params.deinit(allocator);

    var write_mutex: compat.Mutex = .init;
    var ctx = DispatchContext{
        .conn = .{ .stream = .{ .fd = -1 } },
        .write_mutex = &write_mutex,
        .conn_id = 1,
        .auth_token = "test-session-token",
        .authenticated = false,
    };

    var hello = try dispatch(allocator, .{
        .id = 1,
        .method = "hello",
        .params = .{ .object = params },
    }, &ctx);
    defer cleanupResponse(allocator, &hello);
    try expectNoErr(hello);
    try testing.expect(ctx.authenticated);

    var ping = try dispatch(allocator, .{ .id = 2, .method = "ping" }, &ctx);
    defer cleanupResponse(allocator, &ping);
    try expectNoErr(ping);
    try testing.expectEqualStrings("pong", ping.result.?.string);
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

test "dispatch: unknown method" {
    var resp = try runDispatch(testing.allocator, "nope", null);
    defer cleanupResponse(testing.allocator, &resp);
    try testing.expect(resp.err != null);
    try testing.expect(std.mem.startsWith(u8, resp.err.?, "unknown method"));
}

test "dispatch: agent.tool.execute rejects non-positive timeouts" {
    var params: json.ObjectMap = .empty;
    try params.put(testing.allocator, "tool", .{ .string = "file.read" });
    try params.put(testing.allocator, "input", .{ .string = "missing.txt" });
    try params.put(testing.allocator, "workspace_root", .{ .string = "." });
    try params.put(testing.allocator, "timeout_ms", .{ .integer = 0 });
    defer params.deinit(testing.allocator);

    var response = try runDispatch(testing.allocator, "agent.tool.execute", .{ .object = params });
    defer cleanupResponse(testing.allocator, &response);
    try testing.expectEqualStrings("timeout_ms must be greater than zero", response.err.?);
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
