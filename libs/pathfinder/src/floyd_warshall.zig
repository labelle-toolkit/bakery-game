const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");

const NodeId = types.NodeId;
const INF = types.INF;
const Allocator = std.mem.Allocator;
const Graph = graph_mod.Graph;

pub const FloydWarshall = struct {
    /// dist[i * n + j] = shortest distance from node i to node j
    dist: []f32,
    /// next[i * n + j] = first node on shortest path from i to j
    next: []?NodeId,
    node_count: u32,
    allocator: Allocator,

    /// Build distance and next-hop matrices from the graph's adjacency.
    /// O(V³) time, O(V²) space where V = graph.totalSlots().
    pub fn build(allocator: Allocator, graph: *const Graph) !FloydWarshall {
        const n = graph.totalSlots();
        const size = @as(usize, n) * @as(usize, n);

        const dist = try allocator.alloc(f32, size);
        const next = try allocator.alloc(?NodeId, size);

        // Initialize: all distances to INF, all next-hops to null
        @memset(dist, INF);
        @memset(next, null);

        // Self-distances are 0
        for (0..n) |i| {
            dist[i * n + i] = 0;
        }

        // Fill from graph edges
        for (0..n) |i| {
            if (graph.isRemoved(@intCast(i))) continue;
            for (graph.getEdges(@intCast(i))) |edge| {
                if (graph.isRemoved(edge.to)) continue;
                const edge_idx = i * n + @as(usize, edge.to);
                dist[edge_idx] = edge.cost;
                next[edge_idx] = edge.to;
            }
        }

        // Floyd-Warshall triple loop
        for (0..n) |k| {
            if (graph.isRemoved(@intCast(k))) continue;
            for (0..n) |i| {
                if (graph.isRemoved(@intCast(i))) continue;
                const ik = dist[i * n + k];
                if (ik == INF) continue;
                for (0..n) |j| {
                    if (graph.isRemoved(@intCast(j))) continue;
                    const kj = dist[k * n + j];
                    if (kj == INF) continue;
                    const new_dist = ik + kj;
                    if (new_dist < dist[i * n + j]) {
                        dist[i * n + j] = new_dist;
                        next[i * n + j] = next[i * n + k];
                    }
                }
            }
        }

        return .{
            .dist = dist,
            .next = next,
            .node_count = n,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FloydWarshall) void {
        self.allocator.free(self.dist);
        self.allocator.free(self.next);
    }

    /// Reconstruct full path from start to goal by following the next-hop matrix.
    /// Returns null if unreachable. Caller owns the returned slice.
    pub fn getPath(self: *const FloydWarshall, allocator: Allocator, start: NodeId, goal: NodeId) !?[]NodeId {
        // Self-path: just return the node itself
        if (start == goal) {
            const path = try allocator.alloc(NodeId, 1);
            path[0] = start;
            return path;
        }

        if (self.next[idx(self, start, goal)] == null) return null;

        var path_list = std.ArrayListUnmanaged(NodeId){};
        var current = start;
        try path_list.append(allocator, current);

        while (current != goal) {
            current = self.next[idx(self, current, goal)] orelse return null;
            try path_list.append(allocator, current);
        }

        return try path_list.toOwnedSlice(allocator);
    }

    /// O(1) — lookup next hop without reconstructing full path.
    pub fn getNextHop(self: *const FloydWarshall, from: NodeId, to: NodeId) ?NodeId {
        return self.next[idx(self, from, to)];
    }

    /// O(1) — precomputed shortest distance.
    pub fn getDistance(self: *const FloydWarshall, from: NodeId, to: NodeId) f32 {
        return self.dist[idx(self, from, to)];
    }

    fn idx(self: *const FloydWarshall, i: NodeId, j: NodeId) usize {
        return @as(usize, i) * @as(usize, self.node_count) + @as(usize, j);
    }
};
