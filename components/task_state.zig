// Shared task engine state (simplified with TaskEngineContext)
//
// This module uses labelle-tasks TaskEngineContext to reduce boilerplate.
// Only game-specific hook handlers remain here.

const std = @import("std");
const tasks = @import("labelle-tasks");
const engine = @import("labelle-engine");
const items = @import("items.zig");

pub const ItemType = items.ItemType;
pub const GameId = u64;

// Re-export tasks components for use in ComponentRegistry
pub const Storage = tasks.Storage(ItemType);
pub const Worker = tasks.Worker(ItemType);
pub const DanglingItem = tasks.DanglingItem(ItemType);
pub const StorageRole = tasks.StorageRole;

// Hook receiver for task engine events (game-specific behavior)
pub const BakeryTaskHooks = struct {
    pub fn process_completed(payload: anytype) void {
        std.log.info("[TaskEngine] process_completed: workstation={d}, worker={d}", .{
            payload.workstation_id,
            payload.worker_id,
        });
    }

    pub fn cycle_completed(payload: anytype) void {
        std.log.info("[TaskEngine] cycle_completed: workstation={d}, cycles={d}", .{
            payload.workstation_id,
            payload.cycles_completed,
        });
    }

    pub fn pickup_started(payload: anytype) void {
        std.log.info("[TaskEngine] pickup_started: worker={d}, storage={d}", .{
            payload.worker_id,
            payload.storage_id,
        });
    }

    pub fn store_started(payload: anytype) void {
        std.log.info("[TaskEngine] store_started: worker={d}, storage={d}", .{
            payload.worker_id,
            payload.storage_id,
        });

        // Queue movement to storage
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        Context.queueMovement(payload.worker_id, storage_pos.x, storage_pos.y, .store);
    }

    pub fn worker_assigned(payload: anytype) void {
        std.log.info("[TaskEngine] worker_assigned: worker={d}, workstation={d}", .{
            payload.worker_id,
            payload.workstation_id,
        });
    }

    pub fn worker_released(payload: anytype) void {
        std.log.info("[TaskEngine] worker_released: worker={d}", .{
            payload.worker_id,
        });
    }

    pub fn workstation_queued(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_queued: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn workstation_blocked(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_blocked: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn workstation_activated(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_activated: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        std.log.info("[TaskEngine] pickup_dangling_started: worker={d}, item={d}, item_type={}, target_eis={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.item_type,
            payload.target_eis_id,
        });

        // Queue movement to dangling item
        const registry = Context.getRegistry(engine.Registry) orelse return;
        const Position = engine.render.Position;
        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse return;

        Context.queueMovement(payload.worker_id, item_pos.x, item_pos.y, .pickup_dangling);
    }

    pub fn item_delivered(payload: anytype) void {
        std.log.info("[TaskEngine] item_delivered: worker={d}, item={d}, storage={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.storage_id,
        });

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

// Use TaskEngineContext for lifecycle and state management
pub const Context = tasks.TaskEngineContext(GameId, ItemType, BakeryTaskHooks);

// Re-export types for compatibility
pub const TaskEngine = Context.Engine;
pub const MovementAction = Context.MovementAction;
pub const PendingMovement = Context.PendingMovement;

// Component type (for component registry compatibility - empty marker)
pub const TaskState = struct {
    _unused: u8 = 0,
};

/// Distance function for spatial queries (passed to Context.init)
pub fn getEntityDistance(from_id: GameId, to_id: GameId) ?f32 {
    const registry = Context.getRegistry(engine.Registry) orelse return null;
    const Position = engine.render.Position;

    const from_pos = registry.tryGet(Position, engine.entityFromU64(from_id)) orelse return null;
    const to_pos = registry.tryGet(Position, engine.entityFromU64(to_id)) orelse return null;

    const dx = to_pos.x - from_pos.x;
    const dy = to_pos.y - from_pos.y;
    return @sqrt(dx * dx + dy * dy);
}
