// Shared task engine state (RFC #28 simplified version)
//
// This module holds the global task engine instance used by the bakery game.
// Components (Storage, Worker, DanglingItem) auto-register via tasks.setEngineInterface().

const std = @import("std");
const tasks = @import("labelle-tasks");
const engine = @import("labelle-engine");
const items = @import("items.zig");

pub const ItemType = items.ItemType;
pub const GameId = u64;

// ECS interface type
const EcsInterface = tasks.EcsInterface(GameId, ItemType);

// Re-export tasks components for use in ComponentRegistry
pub const Storage = tasks.Storage(ItemType);
pub const Worker = tasks.Worker(ItemType);
pub const DanglingItem = tasks.DanglingItem(ItemType);
pub const StorageRole = tasks.StorageRole;

// Hook receiver for task engine events
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
        const registry = game_registry orelse return;
        const Position = engine.render.Position;
        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        queueMovement(payload.worker_id, storage_pos.x, storage_pos.y, .store_to_eis);
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
        const registry = game_registry orelse return;
        const Position = engine.render.Position;
        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse return;

        queueMovement(payload.worker_id, item_pos.x, item_pos.y, .pickup_dangling);
    }

    pub fn item_delivered(payload: anytype) void {
        std.log.info("[TaskEngine] item_delivered: worker={d}, item={d}, storage={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.storage_id,
        });

        // Move the item visual to the storage position
        const game = game_ptr orelse return;
        const registry = game_registry orelse return;
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

// The task engine type
pub const TaskEngine = tasks.Engine(GameId, ItemType, BakeryTaskHooks);

// Global state
pub var task_engine: ?*TaskEngine = null;
var engine_allocator: ?std.mem.Allocator = null;
var game_registry: ?*engine.Registry = null;
var game_ptr: ?*engine.Game = null;

// Component type (for component registry compatibility - empty marker)
pub const TaskState = struct {
    _unused: u8 = 0,
};

/// Distance function for spatial queries
fn getEntityDistance(from_id: GameId, to_id: GameId) ?f32 {
    const registry = game_registry orelse return null;
    const Position = engine.render.Position;

    const from_pos = registry.tryGet(Position, engine.entityFromU64(from_id)) orelse return null;
    const to_pos = registry.tryGet(Position, engine.entityFromU64(to_id)) orelse return null;

    const dx = to_pos.x - from_pos.x;
    const dy = to_pos.y - from_pos.y;
    return @sqrt(dx * dx + dy * dy);
}

pub fn setRegistry(registry: *engine.Registry) void {
    game_registry = registry;
}

pub fn setGame(game: *engine.Game) void {
    game_ptr = game;
}

/// Called by ecs_bridge to ensure context is set up before component operations.
/// This is called from Workstation.onAdd with the game/registry from ComponentPayload.
pub fn ensureContext(game_ptr_raw: *anyopaque, registry_ptr_raw: *anyopaque) void {
    if (game_registry == null) {
        game_registry = @ptrCast(@alignCast(registry_ptr_raw));
    }
    if (game_ptr == null) {
        game_ptr = @ptrCast(@alignCast(game_ptr_raw));
    }
}

// Custom vtable - will be populated at runtime from engine's vtable
var custom_vtable: EcsInterface.VTable = undefined;

/// Initialize the task engine
pub fn init(allocator: std.mem.Allocator) !void {
    if (task_engine != null) return;

    engine_allocator = allocator;

    const task_eng = try allocator.create(TaskEngine);
    task_eng.* = TaskEngine.init(allocator, .{}, getEntityDistance);
    task_engine = task_eng;

    // RFC #28: Connect tasks components to engine for auto-registration
    // Create a custom interface that adds ensureContext callback
    const engine_iface = task_eng.interface();

    // Copy engine's vtable and add our ensureContext
    custom_vtable = engine_iface.vtable.*;
    custom_vtable.ensureContext = ensureContext;

    const custom_iface = EcsInterface{
        .ptr = engine_iface.ptr,
        .vtable = &custom_vtable,
    };
    tasks.setEngineInterface(GameId, ItemType, custom_iface);

    std.log.info("[TaskState] Task engine initialized with auto-registration", .{});
}

/// Deinitialize the task engine
pub fn deinit() void {
    if (task_engine) |task_eng| {
        tasks.clearEngineInterface(GameId, ItemType);
        task_eng.deinit();
        if (engine_allocator) |allocator| {
            allocator.destroy(task_eng);
        }
        task_engine = null;
        engine_allocator = null;
        game_registry = null;
        game_ptr = null;
    }
}

pub fn getEngine() ?*TaskEngine {
    return task_engine;
}

pub fn getRegistry() ?*engine.Registry {
    return game_registry;
}

// Workstation still needs manual registration (complex logic)
pub fn addWorkstation(workstation_id: GameId, config: TaskEngine.WorkstationConfig) !void {
    if (task_engine) |task_eng| {
        try task_eng.addWorkstation(workstation_id, config);
    }
}

/// Notify task engine that a pickup was completed
pub fn pickupCompleted(worker_id: GameId) bool {
    if (task_engine) |task_eng| {
        return task_eng.pickupCompleted(worker_id);
    }
    return false;
}

/// Notify task engine that a store was completed
pub fn storeCompleted(worker_id: GameId) bool {
    if (task_engine) |task_eng| {
        return task_eng.storeCompleted(worker_id);
    }
    return false;
}

// ============================================
// Pending Movements Queue
// ============================================

pub const MovementAction = enum {
    pickup_dangling,
    store_to_eis,
};

pub const PendingMovement = struct {
    worker_id: GameId,
    target_x: f32,
    target_y: f32,
    action: MovementAction,
};

var pending_movements: std.ArrayListUnmanaged(PendingMovement) = .{};
var movements_initialized: bool = false;
const movements_allocator = std.heap.page_allocator;

pub fn queueMovement(worker_id: GameId, target_x: f32, target_y: f32, action: MovementAction) void {
    movements_initialized = true;
    pending_movements.append(movements_allocator, .{
        .worker_id = worker_id,
        .target_x = target_x,
        .target_y = target_y,
        .action = action,
    }) catch |err| {
        std.log.err("[TaskState] Failed to queue movement: {}", .{err});
    };
}

pub fn takePendingMovements() []PendingMovement {
    if (!movements_initialized or pending_movements.items.len == 0) {
        return &.{};
    }
    const slice = pending_movements.toOwnedSlice(movements_allocator) catch return &.{};
    return slice;
}

pub fn freePendingMovements(slice: []PendingMovement) void {
    std.heap.page_allocator.free(slice);
}
