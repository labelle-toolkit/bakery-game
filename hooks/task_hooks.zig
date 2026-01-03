// Task hooks for the bakery game
//
// Uses labelle-tasks.createEngineHooks to reduce boilerplate.
// Game-specific hooks (store_started, pickup_dangling_started, item_delivered)
// respond to task engine events and integrate with the game's visual/movement systems.

const engine = @import("labelle-engine");
const tasks = @import("labelle-tasks");
const items = @import("../enums/items.zig");

// === Type Definitions ===

pub const ItemType = items.ItemType;
pub const GameId = u64;

// === Game-Specific Task Hooks ===

const GameHooks = struct {
    pub fn store_started(payload: anytype) void {
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        Context.queueMovement(payload.worker_id, storage_pos.x, storage_pos.y, .store);
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse return;

        Context.queueMovement(payload.worker_id, item_pos.x, item_pos.y, .pickup_dangling);
    }

    pub fn item_delivered(payload: anytype) void {
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

// === Task Engine Hooks ===

const TaskHooks = tasks.createEngineHooks(GameId, ItemType, GameHooks);

// Re-exports for scripts and other modules
pub const Context = TaskHooks.Context;
pub const MovementAction = TaskHooks.MovementAction;
pub const PendingMovement = TaskHooks.PendingMovement;

// Engine hooks (forwarded from TaskHooks)
pub const game_init = TaskHooks.game_init;
pub const scene_load = TaskHooks.scene_load;
pub const game_deinit = TaskHooks.game_deinit;
