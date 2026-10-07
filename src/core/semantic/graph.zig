/// Semantic codebase graph per spec §2.
/// Stores nodes (file, symbol, function, etc.) and typed edges
/// in a mutable in-memory store backed by append-only delta segments.
const std = @import("std");

pub const NodeKind = enum(u8) {
    file,
    symbol,
    type_decl,
    function,
    field,
    issue,
    pr,
    commit,
};

pub const EdgeKind = enum(u8) {
    imports,
    calls,
    defines,
    overrides,
    reads,
    writes,
    implements,
    links_to,
};

pub const SymbolId = packed struct(u128) {
    hi: u64,
    lo: u64,

    pub fn fromU128(v: u128) SymbolId {
        return @bitCast(v);
    }

    pub fn toU128(self: SymbolId) u128 {
        return @bitCast(self);
    }
};

pub const SnapshotId = u64;

pub const NodeRecord = struct {
    id: SymbolId,
    kind: NodeKind,
    /// Interned name string owned by StringPool.
    name: []const u8,
    /// Interned language identifier owned by StringPool.
    lang: []const u8,
    /// Optional parent node.
    parent: ?SymbolId,
};

pub const EdgeRecord = struct {
    from: SymbolId,
    to: SymbolId,
    kind: EdgeKind,
};

pub const GraphDelta = struct {
    snapshot_id: SnapshotId,
    added_nodes: []const NodeRecord,
    removed_ids: []const SymbolId,
    added_edges: []const EdgeRecord,
    removed_edges: []const EdgeRecord,
};

pub const GraphError = error{
    NodeNotFound,
    DuplicateNode,
    OutOfMemory,
};

/// Mükerrer string tahsislerini önleyen ve belleği optimize eden String Havuzu.
const StringPool = struct {
    strings: std.StringHashMapUnmanaged(void),

    pub fn init() StringPool {
        return .{ .strings = .{} };
    }

    pub fn deinit(self: *StringPool, alloc: std.mem.Allocator) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        self.strings.deinit(alloc);
    }

    pub fn intern(self: *StringPool, alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        if (self.strings.getEntry(bytes)) |entry| {
            return entry.key_ptr.*;
        }
        const owned = try alloc.dupe(u8, bytes);
        errdefer alloc.free(owned);
        try self.strings.put(alloc, owned, {});
        return owned;
    }
};

/// In-memory semantic graph store.
pub const SemanticGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(SymbolId, NodeRecord),
    edges: std.ArrayListUnmanaged(EdgeRecord),
    /// Reverse call index: callee -> callers. Keeps callers_of queries O(degree)
    /// instead of scanning the entire edge store on every query.
    call_index: std.AutoHashMapUnmanaged(SymbolId, std.ArrayListUnmanaged(SymbolId)),
    /// Name -> node ids index for exact symbol lookup without scanning all nodes.
    name_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)),
    /// Source-node adjacency index for graph traversals.
    out_index: std.AutoHashMapUnmanaged(SymbolId, std.ArrayListUnmanaged(EdgeRecord)),
    strings: StringPool,
    current_snapshot: SnapshotId,

    pub fn init(alloc: std.mem.Allocator) SemanticGraph {
        return .{
            .allocator = alloc,
            .nodes = .{},
            .edges = .empty,
            .call_index = .{},
            .name_index = .{},
            .out_index = .{},
            .strings = StringPool.init(),
            .current_snapshot = 0,
        };
    }

    pub fn deinit(self: *SemanticGraph) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        var name_it = self.name_index.iterator();
        while (name_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.name_index.deinit(self.allocator);
        var call_it = self.call_index.iterator();
        while (call_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.call_index.deinit(self.allocator);
        var out_it = self.out_index.iterator();
        while (out_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.out_index.deinit(self.allocator);
        self.strings.deinit(self.allocator);
    }

    /// Applies an incremental delta: adds nodes/edges and removes obsolete ones.
    pub fn applyDelta(self: *SemanticGraph, delta: GraphDelta) !void {
        // 1. Düğüm Silme (Memory Leak Düzeltildi + Silinecek id'leri Hızlı Arama İçi Set Yapma)
        var removed_node_set = std.AutoHashMapUnmanaged(SymbolId, void){};
        defer removed_node_set.deinit(self.allocator);

        for (delta.removed_ids) |sym_id| {
            if (self.nodes.fetchRemove(sym_id)) |_| {
                try removed_node_set.put(self.allocator, sym_id, {});
            }
        }

        // 2. Kenar Silme Optimize Edildi: O(N*M) -> O(N+M)
        var removed_edge_set = std.AutoHashMapUnmanaged(EdgeRecord, void){};
        defer removed_edge_set.deinit(self.allocator);

        for (delta.removed_edges) |re| {
            try removed_edge_set.put(self.allocator, re, {});
        }

        // Kenarları tek geçişte filtresiz olarak sil (Hem manuel silinenler hem silinen düğümlere bağlı olanlar)
        var write_idx: usize = 0;
        for (self.edges.items) |e| {
            const is_explicitly_removed = removed_edge_set.contains(e);
            const connects_to_deleted_node = removed_node_set.contains(e.from) or removed_node_set.contains(e.to);

            if (!is_explicitly_removed and !connects_to_deleted_node) {
                self.edges.items[write_idx] = e;
                write_idx += 1;
            }
        }
        self.edges.shrinkRetainingCapacity(write_idx);

        // Keep secondary indexes consistent using the same O(E + R) removal set
        // used by the primary edge store. This avoids the old O(E * R) scan.
        if (delta.removed_edges.len > 0 or delta.removed_ids.len > 0) {
            var out_it = self.out_index.iterator();
            while (out_it.next()) |entry| {
                var write: usize = 0;
                for (entry.value_ptr.items) |edge| {
                    if (!removed_node_set.contains(edge.from) and
                        !removed_node_set.contains(edge.to) and
                        !removed_edge_set.contains(edge))
                    {
                        entry.value_ptr.items[write] = edge;
                        write += 1;
                    }
                }
                entry.value_ptr.shrinkRetainingCapacity(write);
            }

            var call_it = self.call_index.iterator();
            while (call_it.next()) |entry| {
                var write: usize = 0;
                for (entry.value_ptr.items) |caller| {
                    const edge = EdgeRecord{ .from = caller, .to = entry.key_ptr.*, .kind = .calls };
                    if (!removed_node_set.contains(caller) and
                        !removed_node_set.contains(entry.key_ptr.*) and
                        !removed_edge_set.contains(edge))
                    {
                        entry.value_ptr.items[write] = caller;
                        write += 1;
                    }
                }
                entry.value_ptr.shrinkRetainingCapacity(write);
            }

            var name_it = self.name_index.iterator();
            while (name_it.next()) |entry| {
                var write: usize = 0;
                for (entry.value_ptr.items) |id| {
                    if (!removed_node_set.contains(id)) {
                        entry.value_ptr.items[write] = id;
                        write += 1;
                    }
                }
                entry.value_ptr.shrinkRetainingCapacity(write);
            }
        }

        // 3. Yeni Düğümleri Ekle (String Interning Yapılarak)
        for (delta.added_nodes) |node| {
            if (self.nodes.contains(node.id)) continue; // Idempotent check

            const interned_name = try self.strings.intern(self.allocator, node.name);
            const interned_lang = try self.strings.intern(self.allocator, node.lang);

            try self.nodes.put(self.allocator, node.id, .{
                .id = node.id,
                .kind = node.kind,
                .name = interned_name,
                .lang = interned_lang,
                .parent = node.parent,
            });

            const name_bucket = try self.name_index.getOrPut(self.allocator, interned_name);
            if (!name_bucket.found_existing) name_bucket.value_ptr.* = .empty;
            try name_bucket.value_ptr.append(self.allocator, node.id);
        }

        // 4. Yeni Kenarları Ekle
        try self.edges.ensureUnusedCapacity(self.allocator, delta.added_edges.len);
        for (delta.added_edges) |edge| {
            self.edges.appendAssumeCapacity(edge);
            const out = try self.out_index.getOrPut(self.allocator, edge.from);
            if (!out.found_existing) out.value_ptr.* = .empty;
            try out.value_ptr.append(self.allocator, edge);

            if (edge.kind == .calls) {
                const gop = try self.call_index.getOrPut(self.allocator, edge.to);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, edge.from);
            }
        }

        self.current_snapshot = delta.snapshot_id;
    }

    /// Returns all callers of a given symbol (nodes with a `calls` edge to it).
    pub fn callersOf(self: *const SemanticGraph, target: SymbolId, alloc: std.mem.Allocator) ![]SymbolId {
        if (self.call_index.get(target)) |callers| {
            return alloc.dupe(SymbolId, callers.items);
        }
        return alloc.alloc(SymbolId, 0);
    }

    /// Looks up a node by SymbolId. Returns null if not found.
    pub fn lookupNode(self: *const SemanticGraph, id: SymbolId) ?NodeRecord {
        return self.nodes.get(id);
    }

    pub fn nodeCount(self: *const SemanticGraph) usize {
        return self.nodes.count();
    }

    pub fn edgeCount(self: *const SemanticGraph) usize {
        return self.edges.items.len;
    }
};

// --- Testler ---

test "graph: apply delta adds nodes and edges" {
    const alloc = std.testing.allocator;
    var graph = SemanticGraph.init(alloc);
    defer graph.deinit();

    const id_a = SymbolId.fromU128(1);
    const id_b = SymbolId.fromU128(2);

    const nodes = [_]NodeRecord{
        .{ .id = id_a, .kind = .function, .name = "main", .lang = "zig", .parent = null },
        .{ .id = id_b, .kind = .function, .name = "helper", .lang = "zig", .parent = null },
    };
    const edges = [_]EdgeRecord{
        .{ .from = id_a, .to = id_b, .kind = .calls },
    };

    try graph.applyDelta(.{
        .snapshot_id = 1,
        .added_nodes = &nodes,
        .removed_ids = &.{},
        .added_edges = &edges,
        .removed_edges = &.{},
    });

    try std.testing.expectEqual(@as(usize, 2), graph.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), graph.edgeCount());

    const callers = try graph.callersOf(id_b, alloc);
    defer alloc.free(callers);
    try std.testing.expectEqual(@as(usize, 1), callers.len);
    try std.testing.expectEqual(id_a.toU128(), callers[0].toU128());
}

test "graph: remove node via delta cleans memory and dangling edges" {
    const alloc = std.testing.allocator;
    var graph = SemanticGraph.init(alloc);
    defer graph.deinit();

    const id_a = SymbolId.fromU128(99);
    const id_b = SymbolId.fromU128(100);

    const nodes = [_]NodeRecord{
        .{ .id = id_a, .kind = .file, .name = "x.zig", .lang = "zig", .parent = null },
        .{ .id = id_b, .kind = .function, .name = "foo", .lang = "zig", .parent = null },
    };
    const edges = [_]EdgeRecord{
        .{ .from = id_b, .to = id_a, .kind = .defines },
    };

    try graph.applyDelta(.{ .snapshot_id = 1, .added_nodes = &nodes, .removed_ids = &.{}, .added_edges = &edges, .removed_edges = &.{} });
    try std.testing.expectEqual(@as(usize, 2), graph.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), graph.edgeCount());

    // Düğüm A silindiğinde ona bağlı kenarın da silinmesi gerekir
    try graph.applyDelta(.{ .snapshot_id = 2, .added_nodes = &.{}, .removed_ids = &[_]SymbolId{id_a}, .added_edges = &.{}, .removed_edges = &.{} });
    try std.testing.expectEqual(@as(usize, 1), graph.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), graph.edgeCount());
}


test "graph: secondary indexes stay consistent after edge and node removal" {
    const alloc = std.testing.allocator;
    var g = SemanticGraph.init(alloc);
    defer g.deinit();

    const caller = SymbolId.fromU128(10);
    const target = SymbolId.fromU128(11);
    const other = SymbolId.fromU128(12);
    const nodes = [_]NodeRecord{
        .{ .id = caller, .kind = .function, .name = "run", .lang = "zig", .parent = null },
        .{ .id = target, .kind = .function, .name = "run", .lang = "zig", .parent = null },
        .{ .id = other, .kind = .function, .name = "other", .lang = "zig", .parent = null },
    };
    const edges = [_]EdgeRecord{
        .{ .from = caller, .to = target, .kind = .calls },
        .{ .from = other, .to = target, .kind = .calls },
    };

    try g.applyDelta(.{
        .snapshot_id = 1,
        .added_nodes = &nodes,
        .removed_ids = &.{},
        .added_edges = &edges,
        .removed_edges = &.{},
    });

    const callers_before = try g.callersOf(target, alloc);
    defer alloc.free(callers_before);
    try std.testing.expectEqual(@as(usize, 2), callers_before.len);
    try std.testing.expectEqual(@as(usize, 2), g.name_index.get("run").?.items.len);

    try g.applyDelta(.{
        .snapshot_id = 2,
        .added_nodes = &.{},
        .removed_ids = &[_]SymbolId{caller},
        .added_edges = &.{},
        .removed_edges = &.{},
    });

    const callers_after = try g.callersOf(target, alloc);
    defer alloc.free(callers_after);
    try std.testing.expectEqual(@as(usize, 1), callers_after.len);
    try std.testing.expectEqual(other.toU128(), callers_after[0].toU128());
    try std.testing.expectEqual(@as(usize, 1), g.name_index.get("run").?.items.len);
}

test "graph: explicit call-edge removal updates reverse index" {
    const alloc = std.testing.allocator;
    var g = SemanticGraph.init(alloc);
    defer g.deinit();

    const caller = SymbolId.fromU128(20);
    const target = SymbolId.fromU128(21);
    const nodes = [_]NodeRecord{
        .{ .id = caller, .kind = .function, .name = "caller", .lang = "zig", .parent = null },
        .{ .id = target, .kind = .function, .name = "target", .lang = "zig", .parent = null },
    };
    const edge = EdgeRecord{ .from = caller, .to = target, .kind = .calls };

    try g.applyDelta(.{
        .snapshot_id = 1,
        .added_nodes = &nodes,
        .removed_ids = &.{},
        .added_edges = &[_]EdgeRecord{edge},
        .removed_edges = &.{},
    });
    try std.testing.expectEqual(@as(usize, 1), (try g.callersOf(target, alloc)).len);

    try g.applyDelta(.{
        .snapshot_id = 2,
        .added_nodes = &.{},
        .removed_ids = &.{},
        .added_edges = &.{},
        .removed_edges = &[_]EdgeRecord{edge},
    });

    const callers = try g.callersOf(target, alloc);
    defer alloc.free(callers);
    try std.testing.expectEqual(@as(usize, 0), callers.len);
}
