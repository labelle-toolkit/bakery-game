// Shared task engine state
//
// This module holds the global task engine instance used by the bakery game.
// The engine is initialized on scene_load and cleaned up on scene_unload.

const std = @import("std");
const tasks = @import("labelle-tasks");
const engine = @import("labelle-engine");
const items = @import("items.zig");

pub const ItemType = items.ItemType;

// GameId is u64 to match entity_id from ComponentPayload
pub const GameId = u64;

// Re-export storage role for convenience
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
        // TODO: Start worker movement towards the dangling item
    }
};

// The task engine type
pub const TaskEngine = tasks.Engine(GameId, ItemType, BakeryTaskHooks);

// Global task engine state
pub var task_engine: ?*TaskEngine = null;
var engine_allocator: ?std.mem.Allocator = null;

// Game registry reference for distance calculations
var game_registry: ?*engine.Registry = null;

// Component type (for component registry compatibility)
pub const TaskState = struct {
    _unused: u8 = 0,
};

/// Distance function for spatial queries - simple Euclidean distance
fn getEntityDistance(from_id: GameId, to_id: GameId) ?f32 {
    const registry = game_registry orelse return null;

    const from_entity = engine.entityFromU64(from_id);
    const to_entity = engine.entityFromU64(to_id);

    const Position = engine.render.Position;
    const from_pos = registry.tryGet(Position, from_entity) orelse return null;
    const to_pos = registry.tryGet(Position, to_entity) orelse return null;

    const dx = to_pos.x - from_pos.x;
    const dy = to_pos.y - from_pos.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Set the game registry for distance calculations
pub fn setRegistry(registry: *engine.Registry) void {
    game_registry = registry;
}

/// Initialize the task engine (called from scene_load hook)
pub fn init(allocator: std.mem.Allocator) !void {
    if (task_engine != null) {
        std.log.warn("[TaskState] Task engine already initialized", .{});
        return;
    }

    engine_allocator = allocator;

    const task_eng = try allocator.create(TaskEngine);
    task_eng.* = TaskEngine.init(allocator, .{}, getEntityDistance);
    task_engine = task_eng;

    std.log.info("[TaskState] Task engine initialized with distance function", .{});
}

/// Deinitialize the task engine (called from scene_unload hook)
pub fn deinit() void {
    if (task_engine) |task_eng| {
        task_eng.deinit();
        if (engine_allocator) |allocator| {
            allocator.destroy(task_eng);
        }
        task_engine = null;
        engine_allocator = null;
        game_registry = null;
        std.log.info("[TaskState] Task engine deinitialized", .{});
    }
}

/// Get the task engine instance
pub fn getEngine() ?*TaskEngine {
    return task_engine;
}

/// Add a storage to the task engine
pub fn addStorage(storage_id: GameId, config: TaskEngine.StorageConfig) !void {
    if (task_engine) |task_eng| {
        try task_eng.addStorage(storage_id, config);
        std.log.info("[TaskState] Added storage: id={d}, role={}, accepts={?}, initial_item={?}", .{
            storage_id,
            config.role,
            config.accepts,
            config.initial_item,
        });
    } else {
        std.log.warn("[TaskState] Cannot add storage - engine not initialized", .{});
    }
}

/// Add a workstation to the task engine
pub fn addWorkstation(workstation_id: GameId, config: TaskEngine.WorkstationConfig) !void {
    if (task_engine) |task_eng| {
        try task_eng.addWorkstation(workstation_id, config);
        std.log.info("[TaskState] Added workstation: id={d}, eis={d}, iis={d}, ios={d}, eos={d}", .{
            workstation_id,
            config.eis.len,
            config.iis.len,
            config.ios.len,
            config.eos.len,
        });
    } else {
        std.log.warn("[TaskState] Cannot add workstation - engine not initialized", .{});
    }
}

/// Add a worker to the task engine
pub fn addWorker(worker_id: GameId) !void {
    if (task_engine) |task_eng| {
        try task_eng.addWorker(worker_id);
        std.log.info("[TaskState] Added worker: id={d}", .{worker_id});
    } else {
        std.log.warn("[TaskState] Cannot add worker - engine not initialized", .{});
    }
}

/// Add a dangling item to the task engine
pub fn addDanglingItem(item_id: GameId, item_type: ItemType) !void {
    if (task_engine) |task_eng| {
        try task_eng.addDanglingItem(item_id, item_type);
        std.log.info("[TaskState] Added dangling item: id={d}, type={}", .{ item_id, item_type });
    } else {
        std.log.warn("[TaskState] Cannot add dangling item - engine not initialized", .{});
    }
}

/// Remove a dangling item from the task engine
pub fn removeDanglingItem(item_id: GameId) void {
    if (task_engine) |task_eng| {
        task_eng.removeDanglingItem(item_id);
        std.log.info("[TaskState] Removed dangling item: id={d}", .{item_id});
    } else {
        std.log.warn("[TaskState] Cannot remove dangling item - engine not initialized", .{});
    }
}
