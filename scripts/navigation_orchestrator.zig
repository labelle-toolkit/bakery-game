// Navigation orchestrator script
//
// Manages the lifecycle of NavigationIntent components:
// 1. pending   → resolve nodes, call pathfinder_bridge.navigate()
// 2. navigating → poll pathfinder_bridge.isNavigating()
// 3. last_mile  → set MovementTarget for final approach to actual target
// 4. fallback   → set MovementTarget for straight-line (no path found)
//
// Must run AFTER pathfinder_bridge (so tick has processed) and
// BEFORE worker_movement (so last-mile MovementTarget is picked up same frame).

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const pathfinder_bridge = @import("pathfinder_bridge.zig");
const navigation_intent_comp = @import("../components/navigation_intent.zig");
const movement_target_comp = @import("../components/movement_target.zig");
const closest_node_comp = @import("../components/closest_movement_node.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.render.Position;
const NavigationIntent = navigation_intent_comp.NavigationIntent;
const MovementTarget = movement_target_comp.MovementTarget;
const ClosestMovementNode = closest_node_comp.ClosestMovementNode;
const movement_node_comp = @import("../components/movement_node.zig");
const MovementNode = movement_node_comp.MovementNode;

const log = std.log.scoped(.navigation_orchestrator);

const DEFAULT_SPEED: f32 = 200.0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    log.info("Script initialized", .{});
}

pub fn deinit() void {
    log.info("Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const registry = game.getRegistry();

    // Collect entities to process (can't modify during iteration)
    var process_list = std.ArrayListUnmanaged(Entity){};
    defer process_list.deinit(game.allocator);

    var view = registry.view(.{NavigationIntent});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        process_list.append(game.allocator, entity) catch continue;
    }

    for (process_list.items) |entity| {
        const intent = registry.tryGet(NavigationIntent, entity) orelse continue;
        const entity_id = engine.entityToU64(entity);

        switch (intent.state) {
            .pending => handlePending(registry, entity, entity_id, intent),
            .navigating => handleNavigating(registry, entity, entity_id, intent),
            .last_mile, .fallback_linear => handleTransitionToMovementTarget(registry, entity, intent),
        }
    }
}

fn handlePending(registry: anytype, entity: Entity, entity_id: u64, intent: *const NavigationIntent) void {
    // Resolve "from" node: use worker's current closest node or find dynamically
    const from_node = blk: {
        if (registry.tryGet(ClosestMovementNode, entity)) |cmn| {
            break :blk cmn.node_id;
        }
        // Fallback: find closest node to entity's current position
        const pos = registry.tryGet(Position, entity) orelse {
            transitionToFallback(registry, entity);
            return;
        };
        const result = pathfinder_bridge.findClosestNodeToPosition(pos.x, pos.y) orelse {
            transitionToFallback(registry, entity);
            return;
        };
        break :blk result.node_id;
    };

    // Resolve "to" node
    const to_node = blk: {
        if (intent.target_node != 0xFFFFFFFF) {
            break :blk intent.target_node;
        }
        // Look up target entity's ClosestMovementNode
        const target_entity = engine.entityFromU64(intent.target_entity);
        if (registry.tryGet(ClosestMovementNode, target_entity)) |cmn| {
            break :blk cmn.node_id;
        }
        // Fallback: find closest node to target position
        const result = pathfinder_bridge.findClosestNodeToPosition(intent.target_x, intent.target_y) orelse {
            transitionToFallback(registry, entity);
            return;
        };
        break :blk result.node_id;
    };

    // Same node → skip straight to last mile
    if (from_node == to_node) {
        log.info("entity={d} same node from={d} to={d}, skipping to last_mile", .{ entity_id, from_node, to_node });
        if (registry.getComponent(entity, NavigationIntent)) |mutable_intent| {
            mutable_intent.state = .last_mile;
            mutable_intent.target_node = to_node;
        }
        return;
    }

    // Start pathfinder navigation
    const path = pathfinder_bridge.navigate(entity_id, from_node, to_node, DEFAULT_SPEED);
    if (path == null) {
        log.info("entity={d} no path from={d} to={d}, falling back to linear", .{ entity_id, from_node, to_node });
        transitionToFallback(registry, entity);
        return;
    }

    log.info("entity={d} navigating from={d} to={d}", .{ entity_id, from_node, to_node });
    if (registry.getComponent(entity, NavigationIntent)) |mutable_intent| {
        mutable_intent.state = .navigating;
        mutable_intent.target_node = to_node;
    }
}

fn handleNavigating(registry: anytype, entity: Entity, entity_id: u64, intent: *const NavigationIntent) void {
    if (pathfinder_bridge.isNavigating(entity_id)) return;

    // Pathfinder finished — transition to last mile
    log.info("entity={d} arrived at node={d}, transitioning to last_mile", .{ entity_id, intent.target_node });

    // Update worker's ClosestMovementNode to reflect new position
    if (intent.target_node != 0xFFFFFFFF) {
        if (pathfinder_bridge.nodePosition(intent.target_node)) |_| {
            // Find the actual MovementNode entity for this node_id
            const node_entity_id = findNodeEntity(registry, intent.target_node);
            registry.set(entity, ClosestMovementNode{
                .node_entity = node_entity_id,
                .node_id = intent.target_node,
                .distance = 0,
            });
        }
    }

    if (registry.getComponent(entity, NavigationIntent)) |mutable_intent| {
        mutable_intent.state = .last_mile;
    }
}

fn handleTransitionToMovementTarget(registry: anytype, entity: Entity, intent: *const NavigationIntent) void {
    // Set MovementTarget for the final approach (or full fallback)
    registry.set(entity, MovementTarget{
        .target_x = intent.target_x,
        .target_y = intent.target_y,
        .action = intent.action,
    });

    // Remove NavigationIntent — worker_movement takes over
    registry.remove(NavigationIntent, entity);
}

fn transitionToFallback(registry: anytype, entity: Entity) void {
    if (registry.getComponent(entity, NavigationIntent)) |mutable_intent| {
        mutable_intent.state = .fallback_linear;
    }
}

// --- Internal helpers ---

/// Find the MovementNode entity for a given node_id.
fn findNodeEntity(registry: anytype, target_node_id: u32) u64 {
    var mn_view = registry.view(.{ MovementNode, Position });
    var mn_iter = mn_view.entityIterator();
    while (mn_iter.next()) |node_entity| {
        const mn = mn_view.get(MovementNode, node_entity);
        if (mn.node_id == target_node_id) {
            return engine.entityToU64(node_entity);
        }
    }
    return 0;
}

// --- Public API (for cancellation by other scripts) ---

/// Cancel any active pathfinder navigation and remove NavigationIntent.
pub fn cancelNavigation(registry: anytype, entity: Entity, entity_id: u64) void {
    pathfinder_bridge.cancel(entity_id);
    if (registry.tryGet(NavigationIntent, entity) != null) {
        registry.remove(NavigationIntent, entity);
    }
    if (registry.tryGet(MovementTarget, entity) != null) {
        registry.remove(MovementTarget, entity);
    }
}
