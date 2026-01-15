// Dangling item assigner script
//
// Monitors idle workers and assigns them to pick up remaining dangling items.
// This runs continuously to ensure all dangling items are eventually picked up.

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
    _ = game;
    _ = scene;
    std.log.info("[DanglingItemAssigner] Script initialized", .{});
}

pub fn deinit() void {}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = dt;
    _ = scene;

    const registry = game.getRegistry();

    // Find idle workers (workers without MovementTarget)
    var worker_view = registry.view(.{Worker});
    var worker_iter = worker_view.entityIterator();

    while (worker_iter.next()) |worker_entity| {
        // Skip if worker already has a target
        if (registry.tryGet(MovementTarget, worker_entity)) |_| {
            continue;
        }

        const worker_id = engine.entityToU64(worker_entity);

        // Find a dangling item to assign
        var dangling_view = registry.view(.{ DanglingItem, Position });
        var dangling_iter = dangling_view.entityIterator();

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

                // Assign worker to pick up this dangling item
                registry.set(worker_entity, MovementTarget{
                    .target_x = dangling_pos.x,
                    .target_y = dangling_pos.y,
                    .action = .pickup_dangling,
                });

                // Track the item the worker will pick up
                task_hooks.ensureWorkerItemsInit();
                task_hooks.worker_carried_items.put(worker_id, dangling_id) catch {};
                task_hooks.dangling_item_targets.put(dangling_id, storage_id) catch {};

                std.log.info("[DanglingItemAssigner] Assigned idle worker {d} to pick up dangling item {d} ({s}) and deliver to EIS {d}", .{
                    worker_id,
                    dangling_id,
                    @tagName(dangling_item.item_type),
                    storage_id,
                });

                // Move to next worker
                break;
            }

            // If we assigned this item, break to next worker
            if (registry.tryGet(MovementTarget, worker_entity)) |_| {
                break;
            }
        }
    }
}
