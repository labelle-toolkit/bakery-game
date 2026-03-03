const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");
const fw_mod = @import("floyd_warshall.zig");
const hooks_mod = @import("hooks.zig");
const mp_mod = @import("movement_path.zig");

const NodeId = types.NodeId;
const Position = types.Position;
const INF = types.INF;
const Graph = graph_mod.Graph;
const Config = graph_mod.Config;
const FloydWarshall = fw_mod.FloydWarshall;
const MovementPath = mp_mod.MovementPath;
const Allocator = std.mem.Allocator;

const ARRIVAL_THRESHOLD: f32 = 2.0;

/// Create a Pathfinder type parameterized on game types and hooks.
///
/// - GameId: entity identifier type (typically u64)
/// - GameHooks: struct with optional handler functions:
///   - `pub fn arrived(payload: anytype) void`
///   - `pub fn path_invalidated(payload: anytype) void`
///
/// Usage:
/// ```zig
/// const Pathfinder = pathfinder.PathfinderWith(u64, MyHooks);
/// var pf = Pathfinder.init(allocator, config);
/// ```
pub fn PathfinderWith(
    comptime GameId: type,
    comptime GameHooks: type,
) type {
    const Payload = hooks_mod.NavigationHookPayload(GameId);

    return struct {
        graph: Graph,
        fw: ?FloydWarshall = null,
        allocator: Allocator,
        /// Active navigations keyed by entity ID.
        active: std.AutoArrayHashMap(GameId, NavigationEntry),

        const Self = @This();

        const NavigationEntry = struct {
            path: MovementPath,
        };

        /// Initialize with config loaded from pathfinder.zon.
        pub fn init(allocator: Allocator, config: Config) Self {
            return .{
                .graph = Graph.init(allocator, config),
                .allocator = allocator,
                .active = std.AutoArrayHashMap(GameId, NavigationEntry).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all active path position arrays
            for (self.active.values()) |*entry| {
                self.allocator.free(entry.path.positions);
            }
            self.active.deinit();

            if (self.fw) |*fw| {
                fw.deinit();
            }
            self.graph.deinit();
        }

        // --- Graph building ---

        /// Register a node. Auto-connects to nearest axis-aligned neighbors.
        /// Does NOT trigger a rebuild — just marks dirty.
        pub fn addNode(self: *Self, position: Position, is_stair: bool) !NodeId {
            return self.graph.addNode(position, is_stair);
        }

        /// Remove a node and all its edges. Marks dirty.
        pub fn removeNode(self: *Self, node_id: NodeId) void {
            self.graph.removeNode(node_id);
        }

        // --- Navigation ---

        /// Compute the shortest path and start moving the entity.
        ///
        /// `ctx` must provide:
        /// - `getEntityPosition(entity_id: GameId) ?Position`
        ///
        /// If a path exists, stores a MovementPath internally and returns a pointer to it.
        /// If no path exists, returns null.
        /// Triggers a lazy Floyd-Warshall rebuild if the graph is dirty.
        pub fn navigate(
            self: *Self,
            entity: GameId,
            from_node: NodeId,
            to_node: NodeId,
            speed: f32,
        ) !?*const MovementPath {
            self.ensureBuilt();

            const fw = self.fw orelse return null;

            // Get path as node IDs
            const node_path = try fw.getPath(self.allocator, from_node, to_node) orelse return null;
            defer self.allocator.free(node_path);

            // Convert node IDs to world positions
            const positions = try self.allocator.alloc(Position, node_path.len);
            for (node_path, 0..) |node_id, i| {
                positions[i] = self.graph.getPosition(node_id);
            }

            // Cancel any existing navigation for this entity
            if (self.active.getPtr(entity)) |existing| {
                self.allocator.free(existing.path.positions);
            }

            // Start at index 1 — index 0 is the start node the entity is already at.
            // For single-node paths (start == goal), current_index >= len means
            // immediate arrival on next tick.
            const start_idx: u32 = if (positions.len > 1) 1 else 0;

            const entry = NavigationEntry{
                .path = .{
                    .positions = positions,
                    .current_index = start_idx,
                    .len = @intCast(positions.len),
                    .speed = speed,
                    .goal_node = to_node,
                },
            };

            try self.active.put(entity, entry);
            return &self.active.getPtr(entity).?.path;
        }

        /// Cancel navigation for an entity.
        /// Does NOT fire a hook.
        pub fn cancel(self: *Self, entity: GameId) void {
            if (self.active.fetchSwapRemove(entity)) |kv| {
                self.allocator.free(kv.value.path.positions);
            }
        }

        // --- Tick ---

        /// Advance all navigating entities.
        ///
        /// `ctx` must provide:
        /// - `moveEntity(entity_id: GameId, dx: f32, dy: f32) void`
        /// - `getEntityPosition(entity_id: GameId) ?Position`
        ///
        /// Handles movement interpolation, waypoint advancement, arrival detection,
        /// and path re-validation on graph changes. Fires hooks for arrivals and
        /// path invalidations.
        pub fn tick(self: *Self, ctx: anytype, dt: f32) void {
            // Rebuild if dirty and re-validate active paths
            if (self.graph.dirty) {
                self.rebuildAndValidate(ctx);
            }

            if (self.active.count() == 0) return;

            // Collect entities that have arrived (can't remove during iteration)
            var arrived_buf: [64]GameId = undefined;
            var arrived_count: usize = 0;

            for (self.active.keys(), self.active.values()) |entity, *entry| {
                const path = &entry.path;

                // Get current position
                var pos = ctx.getEntityPosition(entity) orelse continue;

                // Skip past any waypoints already within arrival threshold
                while (path.current_index < path.len) {
                    const target = path.positions[path.current_index];
                    const dx = target.x - pos.x;
                    const dy = target.y - pos.y;
                    const dist = @sqrt(dx * dx + dy * dy);

                    if (dist <= ARRIVAL_THRESHOLD) {
                        // At this waypoint — snap and advance
                        if (dist > 0.01) {
                            ctx.moveEntity(entity, dx, dy);
                            pos.x += dx;
                            pos.y += dy;
                        }
                        path.current_index += 1;
                        continue;
                    }

                    // Move toward target
                    const move_dist = path.speed * dt;
                    if (move_dist >= dist) {
                        // Snap to waypoint
                        ctx.moveEntity(entity, dx, dy);
                        pos.x += dx;
                        pos.y += dy;
                        path.current_index += 1;
                    } else {
                        // Partial move
                        const scale = move_dist / dist;
                        ctx.moveEntity(entity, dx * scale, dy * scale);
                    }
                    break;
                }

                // Check if arrived at final destination
                if (path.current_index >= path.len) {
                    if (arrived_count < arrived_buf.len) {
                        arrived_buf[arrived_count] = entity;
                        arrived_count += 1;
                    }
                }
            }

            // Process arrivals (remove from active, fire hooks)
            for (arrived_buf[0..arrived_count]) |entity| {
                const entry = self.active.fetchSwapRemove(entity) orelse continue;
                self.allocator.free(entry.value.path.positions);

                dispatchHook(GameHooks, .{ .arrived = .{
                    .entity = entity,
                    .goal_node = entry.value.path.goal_node,
                    .registry = null,
                } });
            }
        }

        // --- Utility queries ---

        /// Precomputed shortest distance between two nodes. Returns inf if unreachable.
        pub fn distance(self: *Self, from: NodeId, to: NodeId) f32 {
            self.ensureBuilt();
            const fw = self.fw orelse return INF;
            return fw.getDistance(from, to);
        }

        /// Check if a path exists between two nodes.
        pub fn isReachable(self: *Self, from: NodeId, to: NodeId) bool {
            return self.distance(from, to) != INF;
        }

        /// Get the world position of a node.
        pub fn nodePosition(self: *Self, node_id: NodeId) Position {
            return self.graph.getPosition(node_id);
        }

        /// Get a pointer to the MovementPath for an entity, or null if not navigating.
        pub fn getPath(self: *Self, entity: GameId) ?*MovementPath {
            if (self.active.getPtr(entity)) |entry| {
                return &entry.path;
            }
            return null;
        }

        /// Check if an entity is currently navigating.
        pub fn isNavigating(self: *Self, entity: GameId) bool {
            return self.active.contains(entity);
        }

        // --- Internal ---

        fn ensureBuilt(self: *Self) void {
            if (!self.graph.dirty and self.fw != null) return;

            if (self.fw) |*old_fw| {
                old_fw.deinit();
            }

            self.fw = FloydWarshall.build(self.allocator, &self.graph) catch null;
            self.graph.dirty = false;
        }

        fn rebuildAndValidate(self: *Self, ctx: anytype) void {
            self.ensureBuilt();

            const fw = self.fw orelse return;

            // Re-validate active paths
            var invalidated_buf: [64]GameId = undefined;
            var invalidated_count: usize = 0;

            for (self.active.keys(), self.active.values()) |entity, *entry| {
                const path = &entry.path;

                // Find current node (nearest waypoint the entity has reached)
                const current_node_idx: u32 = if (path.current_index > 0) path.current_index - 1 else 0;
                _ = current_node_idx;

                // Check if the goal is still reachable from the entity's area
                // Use the first waypoint's position to find nearest node
                if (fw.getDistance(0, path.goal_node) == INF and path.goal_node != 0) {
                    // Path may be broken — check more carefully
                    // For now, invalidate if goal node was removed
                    if (self.graph.isRemoved(path.goal_node)) {
                        if (invalidated_count < invalidated_buf.len) {
                            invalidated_buf[invalidated_count] = entity;
                            invalidated_count += 1;
                        }
                    }
                }
            }

            // Process invalidations
            for (invalidated_buf[0..invalidated_count]) |entity| {
                const entry = self.active.fetchSwapRemove(entity) orelse continue;
                self.allocator.free(entry.value.path.positions);

                dispatchHook(GameHooks, .{ .path_invalidated = .{
                    .entity = entity,
                    .goal_node = entry.value.path.goal_node,
                    .current_node = 0, // approximation
                    .registry = null,
                } });
            }

            _ = ctx;
        }

        /// Simple comptime hook dispatch — same pattern as labelle-tasks.
        fn dispatchHook(comptime Hooks: type, payload: Payload) void {
            switch (payload) {
                .arrived => |data| {
                    if (@hasDecl(Hooks, "arrived")) {
                        @field(Hooks, "arrived")(data);
                    }
                },
                .path_invalidated => |data| {
                    if (@hasDecl(Hooks, "path_invalidated")) {
                        @field(Hooks, "path_invalidated")(data);
                    }
                },
            }
        }
    };
}
