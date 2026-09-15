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
    strings: StringPool,
    current_snapshot: SnapshotId,

    pub fn init(alloc: std.mem.Allocator) SemanticGraph {
        return .{
            .allocator = alloc,
            .nodes = .{},
            .edges = .{},
            .strings = StringPool.init(),
            .current_snapshot = 0,
        };
    }

    pub fn deinit(self: *SemanticGraph) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
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
        }

        // 4. Yeni Kenarları Ekle
        try self.edges.ensureUnusedCapacity(self.allocator, delta.added_edges.len);
        for (delta.added_edges) |edge| {
            self.edges.appendAssumeCapacity(edge);
        }

        self.current_snapshot = delta.snapshot_id;
    }

    /// Returns all callers of a given symbol (nodes with a `calls` edge to it).
    pub fn callersOf(self: *const SemanticGraph, target: SymbolId, alloc: std.mem.Allocator) ![]SymbolId {
        var result = std.ArrayListUnmanaged(SymbolId).empty;
        errdefer result.deinit(alloc);

        for (self.edges.items) |edge| {
            if (edge.kind == .calls and edge.to.toU128() == target.toU128()) {
                try result.append(alloc, edge.from);
            }
        }
        return result.toOwnedSlice(alloc);
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
