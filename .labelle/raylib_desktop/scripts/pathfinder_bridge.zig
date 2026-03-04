// Pathfinder bridge script
//
// Init/update/deinit script that manages the pathfinder instance.
// On init: registers MovementNode entities as graph nodes, assigns
// ClosestMovementNode to entities that need pathfinder navigation.
// On update: ticks the pathfinder to advance active navigations.
//
// Public API: navigate(), cancel(), isNavigating() — called by other
// scripts (e.g. worker_movement) to start/stop pathfinder routes.

const std = @import("std");
const engine = @import("labelle-engine");
const pathfinder = @import("pathfinder");

const main = @import("../main.zig");
const movement_node_comp = @import("../components/movement_node.zig");
const movement_stair_comp = @import("../components/movement_stair.zig");
const closest_node_comp = @import("../components/closest_movement_node.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.render.Position;

const PathfinderGameHooks = @import("../hooks/pathfinder_hooks.zig").PathfinderGameHooks;
const MovementNode = movement_node_comp.MovementNode;
const MovementStair = movement_stair_comp.MovementStair;
const ClosestMovementNode = closest_node_comp.ClosestMovementNode;

const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const Storage = BoundTypes.Storage;
const Workstation = BoundTypes.Workstation;
const Bed = main.Bed;

const Pf = pathfinder.PathfinderWith(u64, PathfinderGameHooks);
const MovementPath = pathfinder.MovementPath;
const Config = pathfinder.Config;

const log = std.log.scoped(.pathfinder_bridge);

/// Pathfinder config — hardcoded for now, will move to pathfinder.zon later.
const pf_config = Config{
    .max_connection_distance = 200.0,
    .max_stair_distance = 300.0,
    .axis_tolerance = 1.0,
};

var pf: ?Pf = null;

/// Lookup map from pathfinder node_id to the ECS entity (as u64) that has the MovementNode component.
/// Built at init time for O(1) lookups.
var node_id_to_entity: std.AutoHashMap(u32, u64) = undefined;
var node_map_initialized: bool = false;

/// Adapter that bridges the pathfinder's duck-typed `ctx` API to the engine's
/// game.pos mixin. The pathfinder calls `ctx.getEntityPosition(entity_id)` and
/// `ctx.moveEntity(entity_id, dx, dy)`.
const PathfinderCtx = struct {
    game: *Game,

    pub fn getEntityPosition(self: *PathfinderCtx, entity_id: u64) ?Position {
        const entity = engine.entityFromU64(entity_id);
        const pos = self.game.pos.getLocalPosition(entity) orelse return null;
        return pos.*;
    }

    pub fn moveEntity(self: *PathfinderCtx, entity_id: u64, dx: f32, dy: f32) void {
        const entity = engine.entityFromU64(entity_id);
        self.game.pos.moveLocalPosition(entity, dx, dy);
    }
};

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    pf = Pf.init(game.allocator, pf_config);
    node_id_to_entity = std.AutoHashMap(u32, u64).init(game.allocator);
    node_map_initialized = true;

    const registry = game.getRegistry();
    var node_count: u32 = 0;

    // Register all MovementNode entities as graph nodes
    var node_view = registry.view(.{ MovementNode, Position });
    var node_iter = node_view.entityIterator();
    while (node_iter.next()) |entity| {
        const pos = node_view.get(Position, entity);
        const is_stair = registry.tryGet(MovementStair, entity) != null;

        const node_id = pf.?.addNode(.{ .x = pos.x, .y = pos.y }, is_stair) catch |err| {
            log.err("Failed to add node at ({d},{d}): {}", .{ pos.x, pos.y, err });
            continue;
        };

        // Write node_id back to the component
        if (registry.getComponent(entity, MovementNode)) |mn| {
            mn.node_id = node_id;
        }

        // Track node_id → entity mapping for O(1) lookups
        node_id_to_entity.put(node_id, engine.entityToU64(entity)) catch |err| {
            log.err("Failed to track node {d}: {}", .{ node_id, err });
        };
        node_count += 1;
    }

    // Assign ClosestMovementNode to entities that need navigation
    // (workers, storages, workstations, beds)
    var closest_count: u32 = 0;

    // Workers
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();
    while (worker_iter.next()) |entity| {
        if (assignClosestNode(registry, entity, worker_view.get(Position, entity))) {
            closest_count += 1;
        }
    }

    // Storages
    var storage_view = registry.view(.{ Storage, Position });
    var storage_iter = storage_view.entityIterator();
    while (storage_iter.next()) |entity| {
        if (assignClosestNode(registry, entity, storage_view.get(Position, entity))) {
            closest_count += 1;
        }
    }

    // Workstations
    var ws_view = registry.view(.{ Workstation, Position });
    var ws_iter = ws_view.entityIterator();
    while (ws_iter.next()) |entity| {
        if (assignClosestNode(registry, entity, ws_view.get(Position, entity))) {
            closest_count += 1;
        }
    }

    // Beds
    var bed_view = registry.view(.{ Bed, Position });
    var bed_iter = bed_view.entityIterator();
    while (bed_iter.next()) |entity| {
        if (assignClosestNode(registry, entity, bed_view.get(Position, entity))) {
            closest_count += 1;
        }
    }

    log.info("Registered {d} nodes, assigned {d} closest nodes", .{ node_count, closest_count });
}

pub fn deinit() void {
    if (pf) |*p| {
        p.deinit();
        pf = null;
    }
    if (node_map_initialized) {
        node_id_to_entity.deinit();
        node_map_initialized = false;
    }
    log.info("Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (pf) |*p| {
        var ctx = PathfinderCtx{ .game = game };
        p.tick(&ctx, dt);
    }
}

// --- Public API (for other scripts) ---

/// Result of a closest-node lookup.
pub const ClosestNodeResult = struct {
    node_id: u32,
    distance: f32,
};

/// Find the closest graph node to an arbitrary world position.
/// Useful for dangling items (no ClosestMovementNode) or workers that have drifted.
pub fn findClosestNodeToPosition(x: f32, y: f32) ?ClosestNodeResult {
    const p = pf orelse return null;
    const slots = p.graph.totalSlots();
    if (slots == 0) return null;

    var best_dist: f32 = std.math.inf(f32);
    var best_id: u32 = 0;

    for (0..slots) |i| {
        const nid: u32 = @intCast(i);
        if (p.graph.isRemoved(nid)) continue;
        const npos = p.graph.getPosition(nid);
        const dx = npos.x - x;
        const dy = npos.y - y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < best_dist) {
            best_dist = dist;
            best_id = nid;
        }
    }

    if (best_dist < std.math.inf(f32)) {
        return .{ .node_id = best_id, .distance = best_dist };
    }
    return null;
}

/// Get the world position of a graph node.
pub fn nodePosition(node_id: u32) ?Position {
    const p = pf orelse return null;
    if (node_id >= p.graph.totalSlots() or p.graph.isRemoved(node_id)) return null;
    const core_pos = p.graph.getPosition(node_id);
    return .{ .x = core_pos.x, .y = core_pos.y };
}

/// Start navigating an entity from one node to another.
pub fn navigate(entity_id: u64, from_node: u32, to_node: u32, speed: f32) ?*const MovementPath {
    if (pf) |*p| {
        return p.navigate(entity_id, from_node, to_node, speed) catch |err| {
            log.err("navigate failed: entity={d} from={d} to={d}: {}", .{ entity_id, from_node, to_node, err });
            return null;
        };
    }
    return null;
}

/// Cancel navigation for an entity.
pub fn cancel(entity_id: u64) void {
    if (pf) |*p| {
        p.cancel(entity_id);
    }
}

/// Check if an entity is currently navigating.
pub fn isNavigating(entity_id: u64) bool {
    if (pf) |*p| {
        return p.isNavigating(entity_id);
    }
    return false;
}

/// Look up the ECS entity (as u64) for a pathfinder node_id. O(1).
pub fn nodeEntity(node_id: u32) ?u64 {
    if (!node_map_initialized) return null;
    return node_id_to_entity.get(node_id);
}

/// Get the distance between two nodes.
pub fn distance(from: u32, to: u32) f32 {
    if (pf) |*p| {
        return p.distance(from, to);
    }
    return pathfinder.INF;
}

/// Check if a path exists between two nodes.
pub fn isReachable(from: u32, to: u32) bool {
    if (pf) |*p| {
        return p.isReachable(from, to);
    }
    return false;
}

// --- Internal ---

fn assignClosestNode(registry: anytype, entity: Entity, pos: *const Position) bool {
    var best_dist: f32 = std.math.inf(f32);
    var best_node_id: u32 = 0;
    var best_node_entity: u64 = 0;

    var mn_view = registry.view(.{ MovementNode, Position });
    var mn_iter = mn_view.entityIterator();
    while (mn_iter.next()) |node_entity| {
        const node_pos = mn_view.get(Position, node_entity);
        const dx = node_pos.x - pos.x;
        const dy = node_pos.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist < best_dist) {
            best_dist = dist;
            best_node_id = mn_view.get(MovementNode, node_entity).node_id;
            best_node_entity = engine.entityToU64(node_entity);
        }
    }

    if (best_dist < std.math.inf(f32)) {
        registry.set(entity, ClosestMovementNode{
            .node_entity = best_node_entity,
            .node_id = best_node_id,
            .distance = best_dist,
        });
        return true;
    }
    return false;
}
