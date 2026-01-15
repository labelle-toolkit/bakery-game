// Task initializer script
//
// Initializes the task engine with workers and dangling items on scene load.
// This script:
// 1. Notifies the engine about all idle workers so they can be assigned tasks
// 2. Manually assigns dangling item pickup tasks to idle workers (dangling items
//    are not managed by the task engine, so we handle them here)

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target_mod = @import("../components/movement_target.zig");
const task_hooks = @import("../hooks/task_hooks.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Context = main.labelle_tasksContext;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const DanglingItem = BoundTypes.DanglingItem;
const Storage = BoundTypes.Storage;
const MovementTarget = movement_target_mod.MovementTarget;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("[TaskInitializer] Initializing task engine with scene entities", .{});

    const registry = game.getRegistry();

    // 1. Register and notify engine about all workers
    var worker_view = registry.view(.{Worker});
    var worker_iter = worker_view.entityIterator();

    var worker_count: u32 = 0;
    while (worker_iter.next()) |entity| {
        const worker_id = engine.entityToU64(entity);
        Context.registerWorker(worker_id);
        Context.workerIdle(worker_id);
        worker_count += 1;
        std.log.info("[TaskInitializer] Registered worker {d} with task engine", .{worker_id});
    }

    std.log.info("[TaskInitializer] Initialized {d} workers for task engine", .{worker_count});

    // 2. Manually assign dangling item pickups to idle workers
    // (Dangling items are not managed by task engine, we handle them manually)
    var dangling_view = registry.view(.{ DanglingItem, Position });
    var dangling_iter = dangling_view.entityIterator();

    var assigned_pickups: u32 = 0;
    while (dangling_iter.next()) |dangling_entity| {
        const dangling_item = dangling_view.get(DanglingItem, dangling_entity);
        const dangling_pos = dangling_view.get(Position, dangling_entity);
        const dangling_id = engine.entityToU64(dangling_entity);

        // Find matching EIS that accepts this item type
        var storage_view = registry.view(.{ Storage, Position });
        var storage_iter = storage_view.entityIterator();

        while (storage_iter.next()) |storage_entity| {
            const storage = storage_view.get(Storage, storage_entity);

            // Only assign to EIS storages that accept this item type
            if (storage.role != .eis or storage.accepts != dangling_item.item_type) {
                continue;
            }

            const storage_id = engine.entityToU64(storage_entity);

            // Find an available worker (try the first one for simplicity)
            worker_iter = worker_view.entityIterator();
            if (worker_iter.next()) |worker_entity| {
                const worker_id = engine.entityToU64(worker_entity);

                // Assign worker to pick up this dangling item
                registry.set(worker_entity, MovementTarget{
                    .target_x = dangling_pos.x,
                    .target_y = dangling_pos.y,
                    .action = .pickup_dangling,
                });

                // Track the item the worker will pick up (needed for delivery)
                task_hooks.ensureWorkerItemsInit();
                task_hooks.worker_carried_items.put(worker_id, dangling_id) catch {};
                // Track which EIS this item should be delivered to
                task_hooks.dangling_item_targets.put(dangling_id, storage_id) catch {};

                std.log.info("[TaskInitializer] Assigned worker {d} to pick up dangling item {d} ({s}) and deliver to EIS {d}", .{
                    worker_id,
                    dangling_id,
                    @tagName(dangling_item.item_type),
                    storage_id,
                });

                assigned_pickups += 1;
                break;
            }
        }
    }

    std.log.info("[TaskInitializer] Assigned {d} dangling item pickups", .{assigned_pickups});
}

pub fn deinit() void {
    std.log.info("[TaskInitializer] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
