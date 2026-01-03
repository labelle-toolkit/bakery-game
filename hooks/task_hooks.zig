// Task hooks for the bakery game
//
// Game-specific task event handlers for labelle-tasks.
// Engine hooks (game_init, scene_load, game_deinit) are automatically
// provided by createEngineHooks via project.labelle configuration.
//
// Hook payloads are enriched with .registry and .game pointers,
// so handlers can access the ECS directly without going through Context.

const engine = @import("labelle-engine");

/// Get Context from main.zig (for queueMovement)
fn getContext() type {
    return @import("../main.zig").labelle_tasksContext;
}

/// Game-specific task hooks for labelle-tasks integration.
/// These handlers respond to task engine events and integrate
/// with the game's visual/movement systems.
///
/// Payloads include:
/// - Original fields (worker_id, storage_id, item, etc.)
/// - .registry: ?*engine.Registry
/// - .game: ?*engine.Game
pub const GameHooks = struct {
    pub fn store_started(payload: anytype) void {
        const registry = payload.registry orelse return;
        const Position = engine.render.Position;
        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        const Context = getContext();
        Context.queueMovement(payload.worker_id, storage_pos.x, storage_pos.y, .store);
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        const registry = payload.registry orelse return;
        const Position = engine.render.Position;
        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse return;

        const Context = getContext();
        Context.queueMovement(payload.worker_id, item_pos.x, item_pos.y, .pickup_dangling);
    }

    pub fn item_delivered(payload: anytype) void {
        const registry = payload.registry orelse return;
        const game = payload.game orelse return;
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
