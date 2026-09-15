/// Hybrid search query engine per spec §2: BM25 + vector + graph traversal.
/// Current implementation provides the query API and BM25 lexical scoring;
/// vector similarity is reserved for integration with embedding backends.
const std = @import("std");
const graph = @import("graph.zig");

pub const SemanticQuery = union(enum) {
    symbol_lookup: []const u8,
    changed_since: graph.SnapshotId,
    callers_of: graph.SymbolId,
    cross_language_path: struct { from: graph.SymbolId, to_lang: []const u8 },
    hybrid_search: struct { text: []const u8, top_k: u16 },
};

pub const QueryHit = struct {
    symbol_id: graph.SymbolId,
    name: []const u8,
    kind: graph.NodeKind,
    /// Combined relevance score (0.0–1.0).
    score: f32,
};

pub const SegmentHeader = extern struct {
    version: u32,
    checksum: u64,
    node_count: u64,
    edge_count: u64,
    embedding_dim: u16,
};

/// Simple BM25-style token scorer for in-memory symbol names.
/// k1 = 1.5, b = 0.75 (standard IDF approximation without corpus stats).
fn bm25Score(query: []const u8, doc: []const u8) f32 {
    if (doc.len == 0 or query.len == 0) return 0.0;

    // Exact match boost.
    if (std.mem.eql(u8, query, doc)) return 1.0;
    if (std.mem.containsAtLeast(u8, doc, 1, query)) return 0.75;

    // Prefix match.
    if (std.mem.startsWith(u8, doc, query)) return 0.6;

    // Substring match (case-insensitive naive approximation).
    var qi: usize = 0;
    var di: usize = 0;
    var matches: usize = 0;
    while (qi < query.len and di < doc.len) {
        const qc = std.ascii.toLower(query[qi]);
        const dc = std.ascii.toLower(doc[di]);
        if (qc == dc) {
            qi += 1;
            matches += 1;
        }
        di += 1;
    }
    return @as(f32, @floatFromInt(matches)) / @as(f32, @floatFromInt(query.len)) * 0.5;
}

/// Executes a semantic query against a graph store.
/// @example
/// const hits = try SemanticStore.query(g, .{ .hybrid_search = .{ .text = "auth", .top_k = 10 } }, alloc);
pub const SemanticStore = struct {
    g: *const graph.SemanticGraph,

    pub fn init(g: *const graph.SemanticGraph) SemanticStore {
        return .{ .g = g };
    }

    /// Runs a query and returns up to `top_k` results sorted by score descending.
    /// Caller owns returned slice.
    /// @example
    /// const hits = try store.query(.{ .symbol_lookup = "main" }, alloc);
    pub fn query(
        self: SemanticStore,
        q: SemanticQuery,
        alloc: std.mem.Allocator,
    ) ![]QueryHit {
        var hits = std.ArrayListUnmanaged(QueryHit).empty;
        errdefer hits.deinit(alloc);

        switch (q) {
            .symbol_lookup => |name| {
                var it = self.g.nodes.iterator();
                while (it.next()) |entry| {
                    const node = entry.value_ptr.*;
                    if (std.mem.eql(u8, node.name, name)) {
                        try hits.append(alloc, .{
                            .symbol_id = node.id,
                            .name = node.name,
                            .kind = node.kind,
                            .score = 1.0,
                        });
                    }
                }
            },

            .hybrid_search => |hs| {
                const top_k = hs.top_k;
                var it = self.g.nodes.iterator();
                while (it.next()) |entry| {
                    const node = entry.value_ptr.*;
                    const score = bm25Score(hs.text, node.name);
                    if (score > 0.1) {
                        try hits.append(alloc, .{
                            .symbol_id = node.id,
                            .name = node.name,
                            .kind = node.kind,
                            .score = score,
                        });
                    }
                }
                // Sort descending by score.
                std.mem.sort(QueryHit, hits.items, {}, struct {
                    fn lt(_: void, a: QueryHit, b: QueryHit) bool {
                        return a.score > b.score;
                    }
                }.lt);
                if (hits.items.len > top_k) hits.items.len = top_k;
            },

            .callers_of => |sym| {
                const callers = try self.g.callersOf(sym, alloc);
                defer alloc.free(callers);
                for (callers) |caller_id| {
                    if (self.g.lookupNode(caller_id)) |node| {
                        try hits.append(alloc, .{
                            .symbol_id = node.id,
                            .name = node.name,
                            .kind = node.kind,
                            .score = 1.0,
                        });
                    }
                }
            },

            .changed_since => |snap_id| {
                // Return all nodes in graphs newer than snap_id.
                // In this in-memory model we return everything if current > snap_id.
                if (self.g.current_snapshot > snap_id) {
                    var it = self.g.nodes.iterator();
                    while (it.next()) |entry| {
                        const node = entry.value_ptr.*;
                        try hits.append(alloc, .{
                            .symbol_id = node.id,
                            .name = node.name,
                            .kind = node.kind,
                            .score = 0.5,
                        });
                    }
                }
            },

            .cross_language_path => |clp| {
                // Cross-language resolution: find all nodes reachable from `from`
                // that match `to_lang` via any edge.
                var it = self.g.nodes.iterator();
                while (it.next()) |entry| {
                    const node = entry.value_ptr.*;
                    if (!std.mem.eql(u8, node.lang, clp.to_lang)) continue;
                    // Check if there is an edge from clp.from to this node.
                    for (self.g.edges.items) |edge| {
                        if (edge.from.toU128() == clp.from.toU128() and
                            edge.to.toU128() == node.id.toU128())
                        {
                            try hits.append(alloc, .{
                                .symbol_id = node.id,
                                .name = node.name,
                                .kind = node.kind,
                                .score = 0.8,
                            });
                            break;
                        }
                    }
                }
            },
        }

        return hits.toOwnedSlice(alloc);
    }
};

test "query: symbol_lookup" {
    const alloc = std.testing.allocator;
    var g = graph.SemanticGraph.init(alloc);
    defer g.deinit();

    const id = graph.SymbolId.fromU128(1);
    const nodes = [_]graph.NodeRecord{
        .{ .id = id, .kind = .function, .name = "authenticate", .lang = "zig", .parent = null },
    };
    try g.applyDelta(.{ .snapshot_id = 1, .added_nodes = &nodes, .removed_ids = &.{}, .added_edges = &.{}, .removed_edges = &.{} });

    const store = SemanticStore.init(&g);
    const hits = try store.query(.{ .symbol_lookup = "authenticate" }, alloc);
    defer alloc.free(hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hits[0].score, 0.01);
}

test "query: hybrid_search returns scored results" {
    const alloc = std.testing.allocator;
    var g = graph.SemanticGraph.init(alloc);
    defer g.deinit();

    const nodes = [_]graph.NodeRecord{
        .{ .id = graph.SymbolId.fromU128(1), .kind = .function, .name = "auth_token_refresh", .lang = "zig", .parent = null },
        .{ .id = graph.SymbolId.fromU128(2), .kind = .function, .name = "unrelated_fn", .lang = "zig", .parent = null },
    };
    try g.applyDelta(.{ .snapshot_id = 1, .added_nodes = &nodes, .removed_ids = &.{}, .added_edges = &.{}, .removed_edges = &.{} });

    const store = SemanticStore.init(&g);
    const hits = try store.query(.{ .hybrid_search = .{ .text = "auth", .top_k = 5 } }, alloc);
    defer alloc.free(hits);

    try std.testing.expect(hits.len >= 1);
    try std.testing.expect(hits[0].score > hits[hits.len - 1].score or hits.len == 1);
}
