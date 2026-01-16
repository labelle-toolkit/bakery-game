// Worker movement script
//
// Handles worker movement towards targets (dangling items, storages).
// Queries for entities with MovementTarget component and moves them.
// Notifies task engine when workers arrive at their destinations.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const task_hooks = @import("../hooks/task_hooks.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Context = main.labelle_tasksContext;
const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const BoundTypes = main.labelle_tasksBindItems;
const Storage = BoundTypes.Storage;
const DanglingItem = BoundTypes.DanglingItem;
const Worker = BoundTypes.Worker;

/// Try to assign the given worker to pick up a remaining dangling item
fn tryAssignDanglingItem(registry: anytype, worker_entity: anytype, worker_id: u64) bool {
    // Query for dangling items that still exist
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

            std.log.info("[WorkerMovement] Assigned worker {d} to pick up remaining dangling item {d} ({s}) -> EIS {d}", .{
                worker_id,
                dangling_id,
                @tagName(dangling_item.item_type),
                storage_id,
            });

            return true;
        }
    }
    return false;
}

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    std.log.info("[WorkerMovement] Script initialized", .{});
}

pub fn deinit() void {
    std.log.info("[WorkerMovement] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const registry = game.getRegistry();

    // Query for entities with MovementTarget component
    var view = registry.view(.{ MovementTarget, Position });
    var iter = view.entityIterator();

    while (iter.next()) |entity| {
        const target = view.get(MovementTarget, entity);
        const pos = view.get(Position, entity);

        const dx = target.target_x - pos.x;
        const dy = target.target_y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist < 5.0) {
            // Arrived at target
            const worker_id = engine.entityToU64(entity);
            std.log.info("[WorkerMovement] Worker {d} arrived at target, action={}", .{ worker_id, target.action });

            // Save old target for comparison
            const old_target_x = target.target_x;
            const old_target_y = target.target_y;
            const old_action = target.action;

            // Handle action based on type
            switch (target.action) {
                .pickup_dangling => {
                    // Worker picked up a dangling item
                    // Find item at current position and deliver to matching EIS
                    std.log.info("[WorkerMovement] pickup_dangling: worker {d} at ({d},{d})", .{ worker_id, pos.x, pos.y });

                    // Find the dangling item at this position
                    var item_found = false;
                    var dangling_view = registry.view(.{ DanglingItem, Position });
                    var dangling_iter = dangling_view.entityIterator();

                    while (dangling_iter.next()) |item_entity| {
                        const item_pos = dangling_view.get(Position, item_entity);
                        const dist_to_item = @sqrt((item_pos.x - pos.x) * (item_pos.x - pos.x) + (item_pos.y - pos.y) * (item_pos.y - pos.y));

                        if (dist_to_item < 20.0) {
                            const dangling_item = dangling_view.get(DanglingItem, item_entity);
                            const item_id = engine.entityToU64(item_entity);
                            std.log.info("[WorkerMovement] pickup_dangling: found item {d} ({s}) at distance {d}", .{
                                item_id,
                                @tagName(dangling_item.item_type),
                                dist_to_item,
                            });

                            // Find matching EIS for this item type
                            var storage_view = registry.view(.{ Storage, Position });
                            var storage_iter = storage_view.entityIterator();

                            while (storage_iter.next()) |storage_entity| {
                                const storage = storage_view.get(Storage, storage_entity);
                                if (storage.role == .eis and storage.accepts == dangling_item.item_type) {
                                    const storage_pos = storage_view.get(Position, storage_entity);
                                    const storage_id = engine.entityToU64(storage_entity);

                                    // Remove DanglingItem component - item is now being carried
                                    registry.remove(DanglingItem, item_entity);

                                    // Attach item to worker (parent/child relationship)
                                    game.setParent(item_entity, entity) catch |err| {
                                        std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                                    };
                                    game.setLocalPositionXY(item_entity, 0, 10);
                                    std.log.info("[WorkerMovement] Attached item {d} to worker {d} (parent/child)", .{ item_id, worker_id });

                                    // Track the item for delivery completion
                                    task_hooks.ensureWorkerItemsInit();
                                    task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                                    // Assign worker to deliver to this EIS
                                    registry.set(entity, MovementTarget{
                                        .target_x = storage_pos.x,
                                        .target_y = storage_pos.y,
                                        .action = .store,
                                    });

                                    std.log.info("[WorkerMovement] Worker {d} picked up item {d} ({s}), delivering to EIS {d} at ({d},{d})", .{
                                        worker_id,
                                        item_id,
                                        @tagName(dangling_item.item_type),
                                        storage_id,
                                        storage_pos.x,
                                        storage_pos.y,
                                    });

                                    item_found = true;
                                    break;
                                }
                            }
                            if (item_found) break;
                        }
                    }

                    if (!item_found) {
                        std.log.warn("[WorkerMovement] pickup_dangling: no dangling item found at worker position!", .{});
                    }
                },
                .store => {
                    // Worker delivered item (either dangling item to EIS, or task item to EOS)
                    task_hooks.ensureWorkerItemsInit();
                    if (task_hooks.worker_carried_items.get(worker_id)) |item_id| {
                        // This was a dangling item delivery - notify engine that EIS has item
                        const item_entity = engine.entityFromU64(item_id);

                        // Detach item from worker
                        game.removeParent(item_entity);

                        // Position item at storage location
                        // Find the storage entity at this location
                        var storage_view = registry.view(.{ Storage, Position });
                        var storage_iter = storage_view.entityIterator();

                        while (storage_iter.next()) |storage_entity| {
                            const storage = storage_view.get(Storage, storage_entity);
                            const storage_pos = storage_view.get(Position, storage_entity);

                            // Check if this is the target storage
                            const dx_check = storage_pos.x - pos.x;
                            const dy_check = storage_pos.y - pos.y;
                            const dist_check = @sqrt(dx_check * dx_check + dy_check * dy_check);

                            if (dist_check < 10.0 and storage.role == .eis and storage.accepts != null) {
                                // This is the target EIS
                                game.setWorldPositionXY(item_entity, storage_pos.x, storage_pos.y);

                                // Notify engine that item was added to storage
                                // (registry/game pointers are automatically set via ensureContext)
                                const storage_id = engine.entityToU64(storage_entity);
                                _ = Context.itemAdded(storage_id, storage.accepts.?);

                                std.log.info("[WorkerMovement] Worker {d} delivered item {d} to EIS {d}", .{
                                    worker_id,
                                    item_id,
                                    storage_id,
                                });

                                // Clean up tracking
                                _ = task_hooks.worker_carried_items.remove(worker_id);

                                // Don't call workerIdle() here - if the task engine wants to assign
                                // a new task, the hook (pickup_started) will have set a new MovementTarget.
                                // The MovementTarget cleanup logic below will detect this and keep it.
                                break;
                            }
                        }
                    } else {
                        // Regular task store - notify engine
                        _ = Context.storeCompleted(worker_id);
                    }
                },
                .pickup, .transport_pickup => {
                    // Worker arrived to pick up item from storage (task engine managed)
                    _ = Context.pickupCompleted(worker_id);
                },
                .arrive_at_workstation => {
                    // Worker arrived at workstation to start work
                    _ = Context.storeCompleted(worker_id);
                },
            }

            // Only remove MovementTarget if no new target was set by hooks
            var target_was_removed = false;
            if (registry.tryGet(MovementTarget, entity)) |new_target| {
                std.log.info("[WorkerMovement] After action, checking target: old=({d},{d}) new=({d},{d})", .{
                    old_target_x,
                    old_target_y,
                    new_target.target_x,
                    new_target.target_y,
                });
                if (new_target.target_x == old_target_x and new_target.target_y == old_target_y) {
                    // Same target position - task complete, remove component
                    std.log.info("[WorkerMovement] Removing MovementTarget (same position)", .{});
                    registry.remove(MovementTarget, entity);
                    target_was_removed = true;
                } else {
                    std.log.info("[WorkerMovement] Keeping MovementTarget (new position set by hook)", .{});
                }
                // else: new target was set by hook, keep it
            }

            // If we removed the MovementTarget and it's a Worker with no new task,
            // try to assign remaining dangling items or notify engine worker is idle
            if (target_was_removed and registry.tryGet(Worker, entity) != null) {
                // Check if this was a dangling item delivery (not task-engine managed)
                // by checking if the old action was .store and there's no MovementTarget now
                if (old_action == .store and registry.tryGet(MovementTarget, entity) == null) {
                    // Try to assign a remaining dangling item first
                    if (!tryAssignDanglingItem(registry, entity, worker_id)) {
                        // No more dangling items, worker is now idle
                        std.log.info("[WorkerMovement] Calling workerAvailable for worker {d}", .{worker_id});
                        _ = Context.workerAvailable(worker_id);
                    }
                }
            }
        } else {
            // Move towards target
            const move_dist = @min(target.speed * dt, dist);
            const move_x = (dx / dist) * move_dist;
            const move_y = (dy / dist) * move_dist;
            game.moveLocalPosition(entity, move_x, move_y);

            // Debug: log worker and carried item positions every ~60 frames
            const worker_id = engine.entityToU64(entity);
            task_hooks.ensureWorkerItemsInit();
            if (task_hooks.worker_carried_items.get(worker_id)) |item_id| {
                const item_entity = engine.entityFromU64(item_id);
                if (registry.tryGet(Position, item_entity)) |item_pos| {
                    // Log occasionally (when worker x is near a multiple of 50)
                    const worker_x_int: i32 = @intFromFloat(pos.x);
                    if (@mod(worker_x_int, 100) < 3) {
                        std.log.info("[WorkerMovement] Worker {d} at ({d:.0},{d:.0}), item {d} at ({d:.0},{d:.0})", .{
                            worker_id, pos.x, pos.y, item_id, item_pos.x, item_pos.y,
                        });
                    }
                }
            }
        }
    }
}
