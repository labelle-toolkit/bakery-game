// Task hooks for the bakery game
//
// Contains:
// - Task engine initialization (game_init/game_deinit)
// - Game-specific task event handlers (movement queuing, visual updates)
// - TaskEngineContext instantiation with game types
//
// The task engine is initialized in game_init (before scene loading) so that
// component onAdd callbacks can register with it during entity creation.

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
// visual/movement systems. They are merged with LoggingHooks for debugging.

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

// === Task Engine Context ===

/// Merged hooks: game-specific handlers + default logging
pub const BakeryTaskHooks = tasks.MergeHooks(GameHooks, tasks.LoggingHooks);

/// Task engine context with game-specific types
pub const Context = tasks.TaskEngineContext(GameId, ItemType, BakeryTaskHooks);

// Re-exports for scripts
pub const MovementAction = Context.MovementAction;
pub const PendingMovement = Context.PendingMovement;

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

// === Engine Hooks ===

/// Initialize task engine during game initialization
pub fn game_init(payload: engine.HookPayload) void {
    const info = payload.game_init;

    Context.init(info.allocator, getEntityDistance) catch |err| {
        std.log.err("[TaskHooks] Failed to initialize task engine: {}", .{err});
        return;
    };

    std.log.info("[TaskHooks] game_init: task engine ready", .{});
}

/// Re-evaluate dangling items after scene is loaded (all entities now registered)
pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("[TaskHooks] scene_load: {s} - re-evaluating dangling items", .{info.name});

    if (Context.getEngine()) |task_eng| {
        task_eng.evaluateDanglingItems();
    }
}

/// Clean up task engine on game deinit
pub fn game_deinit(payload: engine.HookPayload) void {
    _ = payload;
    Context.deinit();
    std.log.info("[TaskHooks] game_deinit: task engine cleaned up", .{});
}
