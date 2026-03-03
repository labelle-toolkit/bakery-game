const std = @import("std");
const types = @import("types.zig");

const NodeId = types.NodeId;
const Vec2 = types.Vec2;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    max_connection_distance: f32,
    max_stair_distance: f32,
    axis_tolerance: f32 = 1.0,
};

pub const Edge = struct {
    to: NodeId,
    cost: f32,
};

const EdgeList = std.ArrayListUnmanaged(Edge);

pub const Graph = struct {
    allocator: Allocator,
    /// Node positions indexed by NodeId.
    positions: std.ArrayListUnmanaged(Vec2) = .{},
    /// Whether each node is a stair node.
    is_stair: std.ArrayListUnmanaged(bool) = .{},
    /// Whether each node has been removed (tombstone).
    removed: std.ArrayListUnmanaged(bool) = .{},
    /// Adjacency list: edges[node_id] = list of { neighbor_id, cost }.
    edges: std.ArrayListUnmanaged(EdgeList) = .{},
    /// Config loaded from pathfinder.zon.
    config: Config,
    /// Dirty flag — set on any mutation, cleared after Floyd-Warshall rebuild.
    dirty: bool = true,

    pub fn init(allocator: Allocator, config: Config) Graph {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.edges.items) |*edge_list| {
            edge_list.deinit(self.allocator);
        }
        self.edges.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.is_stair.deinit(self.allocator);
        self.removed.deinit(self.allocator);
    }

    /// Register a new node. Returns its NodeId.
    /// Auto-connects to existing nodes on the same X axis within max_connection_distance.
    /// If is_stair=true, also auto-connects to existing stair nodes on the same Y axis
    /// within max_stair_distance.
    /// Sets dirty = true.
    pub fn addNode(self: *Graph, position: Vec2, stair: bool) !NodeId {
        const new_id: NodeId = @intCast(self.positions.items.len);

        try self.positions.append(self.allocator, position);
        try self.is_stair.append(self.allocator, stair);
        try self.removed.append(self.allocator, false);
        try self.edges.append(self.allocator, .{});

        // Auto-connect on same X axis (nearest neighbor above and below)
        try self.autoConnectAxis(new_id, position, .x);

        // Auto-connect stair nodes on same Y axis (nearest neighbor left and right)
        if (stair) {
            try self.autoConnectAxis(new_id, position, .y);
        }

        self.dirty = true;
        return new_id;
    }

    const Axis = enum { x, y };

    /// Find nearest neighbors on the given axis and create bidirectional edges.
    /// For X axis: connects to nearest above (higher Y) and below (lower Y).
    /// For Y axis: connects to nearest left (lower X) and right (higher X), stair nodes only.
    fn autoConnectAxis(self: *Graph, new_id: NodeId, position: Vec2, comptime axis: Axis) !void {
        const axis_val = switch (axis) {
            .x => position.x,
            .y => position.y,
        };
        const perp_val = switch (axis) {
            .x => position.y,
            .y => position.x,
        };
        const max_dist = switch (axis) {
            .x => self.config.max_connection_distance,
            .y => self.config.max_stair_distance,
        };

        var nearest_pos: ?NodeId = null; // nearest in positive perpendicular direction
        var nearest_pos_dist: f32 = max_dist + 1.0;
        var nearest_neg: ?NodeId = null; // nearest in negative perpendicular direction
        var nearest_neg_dist: f32 = max_dist + 1.0;

        for (self.positions.items, 0..) |other_pos, i| {
            const other_id: NodeId = @intCast(i);
            if (other_id == new_id) continue;
            if (self.removed.items[i]) continue;

            // For Y-axis connections, both nodes must be stairs
            if (axis == .y and !self.is_stair.items[i]) continue;

            const other_axis_val = switch (axis) {
                .x => other_pos.x,
                .y => other_pos.y,
            };
            const other_perp_val = switch (axis) {
                .x => other_pos.y,
                .y => other_pos.x,
            };

            // Check same axis (within tolerance)
            if (@abs(other_axis_val - axis_val) > self.config.axis_tolerance) continue;

            const dist = position.distanceTo(other_pos);
            if (dist > max_dist) continue;

            // Classify as positive or negative direction on perpendicular axis
            if (other_perp_val > perp_val) {
                if (dist < nearest_pos_dist) {
                    nearest_pos = other_id;
                    nearest_pos_dist = dist;
                }
            } else if (other_perp_val < perp_val) {
                if (dist < nearest_neg_dist) {
                    nearest_neg = other_id;
                    nearest_neg_dist = dist;
                }
            }
            // If perp values are equal, classify as positive
            else {
                if (dist < nearest_pos_dist) {
                    nearest_pos = other_id;
                    nearest_pos_dist = dist;
                }
            }
        }

        // Connect to nearest neighbors and re-evaluate existing edges
        if (nearest_pos) |pos_id| {
            try self.addBidirectionalEdge(new_id, pos_id, nearest_pos_dist);
            // Re-evaluate: if pos_id was connected to neg_id, remove that edge
            // (the new node is in between)
            if (nearest_neg) |neg_id| {
                self.removeEdgeBetween(pos_id, neg_id);
            }
        }
        if (nearest_neg) |neg_id| {
            try self.addBidirectionalEdge(new_id, neg_id, nearest_neg_dist);
        }
    }

    fn addBidirectionalEdge(self: *Graph, a: NodeId, b: NodeId, cost: f32) !void {
        try self.edges.items[a].append(self.allocator, .{ .to = b, .cost = cost });
        try self.edges.items[b].append(self.allocator, .{ .to = a, .cost = cost });
    }

    fn removeEdgeBetween(self: *Graph, a: NodeId, b: NodeId) void {
        removeEdgeFromList(&self.edges.items[a], b);
        removeEdgeFromList(&self.edges.items[b], a);
    }

    fn removeEdgeFromList(edge_list: *EdgeList, target: NodeId) void {
        var i: usize = 0;
        while (i < edge_list.items.len) {
            if (edge_list.items[i].to == target) {
                _ = edge_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Remove a node and all its edges. Sets dirty = true.
    pub fn removeNode(self: *Graph, node_id: NodeId) void {
        if (node_id >= self.positions.items.len) return;
        if (self.removed.items[node_id]) return;

        // Remove all edges from this node
        for (self.edges.items[node_id].items) |edge| {
            removeEdgeFromList(&self.edges.items[edge.to], node_id);
        }
        self.edges.items[node_id].clearRetainingCapacity();

        // Mark as removed (tombstone)
        self.removed.items[node_id] = true;
        self.dirty = true;
    }

    /// Number of active (non-removed) nodes.
    pub fn nodeCount(self: *const Graph) u32 {
        var count: u32 = 0;
        for (self.removed.items) |r| {
            if (!r) count += 1;
        }
        return count;
    }

    /// Total number of node slots (including removed).
    pub fn totalSlots(self: *const Graph) u32 {
        return @intCast(self.positions.items.len);
    }

    /// Get the world position of a node.
    pub fn getPosition(self: *const Graph, node_id: NodeId) Vec2 {
        return self.positions.items[node_id];
    }

    /// Get edges for a node.
    pub fn getEdges(self: *const Graph, node_id: NodeId) []const Edge {
        return self.edges.items[node_id].items;
    }

    /// Check if a node has been removed.
    pub fn isRemoved(self: *const Graph, node_id: NodeId) bool {
        if (node_id >= self.removed.items.len) return true;
        return self.removed.items[node_id];
    }
};
