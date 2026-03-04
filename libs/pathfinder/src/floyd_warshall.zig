const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");
const zig_utils = @import("zig-utils");

const NodeId = types.NodeId;
const INF = types.INF;
const Allocator = std.mem.Allocator;
const Graph = graph_mod.Graph;

/// Scale factor for f32 → u32 distance conversion.
/// Preserves sub-pixel precision (1 unit = 0.01 pixels).
const DIST_SCALE: f32 = 100.0;
const U32_INF: u32 = std.math.maxInt(u32);

/// Optimized FW backend: SIMD + multi-threading via zig-utils.
const FWOptimized = zig_utils.FloydWarshallOptimized(.{
    .parallel = true,
    .simd = true,
});

pub const FloydWarshall = struct {
    inner: FWOptimized,
    node_count: u32,
    allocator: Allocator,

    /// Build distance and next-hop matrices from the graph's adjacency.
    /// Delegates to the SIMD/parallel optimized implementation from zig-utils.
    pub fn build(allocator: Allocator, graph: *const Graph) !FloydWarshall {
        const n = graph.totalSlots();

        var inner = FWOptimized.init(allocator);
        errdefer inner.deinit();

        // Count non-removed nodes to size the internal matrix
        var active_count: u32 = 0;
        for (0..n) |i| {
            if (!graph.isRemoved(@intCast(i))) active_count += 1;
        }

        inner.resize(active_count);
        try inner.clean();

        // Pre-register all non-removed nodes so isolated nodes are queryable
        for (0..n) |i| {
            const nid: u32 = @intCast(i);
            if (graph.isRemoved(nid)) continue;
            if (!inner.ids.contains(nid)) {
                const key = inner.newKey();
                try inner.ids.put(nid, key);
                try inner.reverse_ids.put(key, nid);
            }
        }

        // Add edges with f32 → u32 conversion
        for (0..n) |i| {
            const nid: u32 = @intCast(i);
            if (graph.isRemoved(nid)) continue;
            for (graph.getEdges(nid)) |edge| {
                if (graph.isRemoved(edge.to)) continue;
                const w: u32 = @intFromFloat(@round(edge.cost * DIST_SCALE));
                try inner.addEdgeWithMapping(nid, edge.to, w);
            }
        }

        inner.generate();

        return .{
            .inner = inner,
            .node_count = n,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FloydWarshall) void {
        self.inner.deinit();
    }

    /// Reconstruct full path from start to goal.
    /// Returns null if unreachable. Caller owns the returned slice.
    pub fn getPath(self: *const FloydWarshall, allocator: Allocator, start: NodeId, goal: NodeId) !?[]NodeId {
        // Self-path: just return the node itself
        if (start == goal) {
            const path = try allocator.alloc(NodeId, 1);
            path[0] = start;
            return path;
        }

        // Required: the optimized FW initializes next[i][j]=j for all pairs,
        // so setPathWithMappingUnmanaged returns a bogus path for unreachable nodes.
        if (!self.inner.hasPathWithMapping(start, goal)) return null;

        var path_list = std.ArrayListUnmanaged(NodeId){};
        errdefer path_list.deinit(allocator);

        self.inner.setPathWithMappingUnmanaged(allocator, &path_list, start, goal) catch |err| switch (err) {
            error.NoPathFound => {
                path_list.deinit(allocator);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };

        return try path_list.toOwnedSlice(allocator);
    }

    /// O(1) — lookup next hop without reconstructing full path.
    pub fn getNextHop(self: *const FloydWarshall, from: NodeId, to: NodeId) ?NodeId {
        if (!self.inner.hasPathWithMapping(from, to)) return null;
        const result = self.inner.nextWithMapping(from, to);
        if (result == U32_INF) return null;
        return result;
    }

    /// O(1) — precomputed shortest distance (converted back to f32).
    pub fn getDistance(self: *const FloydWarshall, from: NodeId, to: NodeId) f32 {
        const d = self.inner.valueWithMapping(from, to);
        if (d == U32_INF) return INF;
        return @as(f32, @floatFromInt(d)) / DIST_SCALE;
    }
};
