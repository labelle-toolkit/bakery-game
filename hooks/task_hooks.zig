// Task hooks for the bakery game
//
// Uses labelle-tasks.createEngineHooks to reduce boilerplate.
// Game-specific hooks (store_started, pickup_dangling_started, item_delivered)
// and the distance function remain in this file.

const std = @import("std");
const engine = @import("labelle-engine");
const tasks = @import("labelle-tasks");
const items = @import("../enums/items.zig");

// === Type Definitions ===

pub const ItemType = items.ItemType;
pub const GameId = u64;

// === Game-Specific Task Hooks ===
//
// These hooks respond to task engine events and integrate with the game's
// visual/movement systems. They are merged with LoggingHooks automatically.

const GameHooks = struct {
    pub fn store_started(payload: anytype) void {
        // Queue movement to storage
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        Context.queueMovement(payload.worker_id, storage_pos.x, storage_pos.y, .store);
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        // Queue movement to dangling item
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse return;

        Context.queueMovement(payload.worker_id, item_pos.x, item_pos.y, .pickup_dangling);
    }

    pub fn item_delivered(payload: anytype) void {
        // Move the item visual to the storage position
        const game = Context.getGame(engine.Game) orelse return;
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const Shape = engine.render.Shape;

        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        const item_entity = engine.entityFromU64(payload.item_id);

        game.setPositionXY(item_entity, storage_pos.x, storage_pos.y);

        const storage_z = if (registry.tryGet(Shape, storage_entity)) |s| s.z_index else 128;
        game.setZIndex(item_entity, storage_z + 1);
    }
};

/// Distance function for spatial queries (used by task engine for finding nearest entities)
fn getEntityDistance(from_id: GameId, to_id: GameId) ?f32 {
    const registry = Context.getRegistry(engine.Registry) orelse return null;
    const Position = engine.render.Position;

    const from_pos = registry.tryGet(Position, engine.entityFromU64(from_id)) orelse return null;
    const to_pos = registry.tryGet(Position, engine.entityFromU64(to_id)) orelse return null;

    const dx = to_pos.x - from_pos.x;
    const dy = to_pos.y - from_pos.y;
    return @sqrt(dx * dx + dy * dy);
}

// === Task Engine Hooks ===
//
// createEngineHooks provides game_init, scene_load, game_deinit hooks
// and the Context type for accessing the task engine.

const TaskHooks = tasks.createEngineHooks(GameId, ItemType, GameHooks, getEntityDistance);

// Re-exports for scripts and other modules
pub const Context = TaskHooks.Context;
pub const MovementAction = TaskHooks.MovementAction;
pub const PendingMovement = TaskHooks.PendingMovement;

// Engine hooks (forwarded from TaskHooks)
pub const game_init = TaskHooks.game_init;
pub const scene_load = TaskHooks.scene_load;
pub const game_deinit = TaskHooks.game_deinit;
