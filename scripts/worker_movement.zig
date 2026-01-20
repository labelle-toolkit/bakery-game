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
const Workstation = BoundTypes.Workstation;

/// Try to assign the given worker to pick up a remaining dangling item
fn tryAssignDanglingItem(registry: anytype, worker_entity: anytype, worker_id: u64) bool {
    std.log.info("[WorkerMovement] tryAssignDanglingItem: looking for remaining dangling items for worker {d}", .{worker_id});

    // Query for dangling items that still exist
    var dangling_view = registry.view(.{ DanglingItem, Position });
    var dangling_iter = dangling_view.entityIterator();

    var dangling_count: u32 = 0;

    while (dangling_iter.next()) |dangling_entity| {
        const dangling_item = dangling_view.get(DanglingItem, dangling_entity);
        const dangling_pos = dangling_view.get(Position, dangling_entity);
        const dangling_id = engine.entityToU64(dangling_entity);
        dangling_count += 1;

        std.log.info("[WorkerMovement] tryAssignDanglingItem: found dangling item {d} ({s}) at ({d},{d})", .{
            dangling_id,
            @tagName(dangling_item.item_type),
            dangling_pos.x,
            dangling_pos.y,
        });

        // Find matching EIS that accepts this item type
        var storage_view = registry.view(.{ Storage, Position });
        var storage_iter = storage_view.entityIterator();

        while (storage_iter.next()) |storage_entity| {
            const storage = storage_view.get(Storage, storage_entity);

            // Only assign to EIS storages that accept this item type
            if (storage.role != .eis) continue;
            const accepts = storage.accepts orelse continue;
            if (accepts != dangling_item.item_type) continue;

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
    std.log.info("[WorkerMovement] tryAssignDanglingItem: no remaining dangling items found (checked {d} items)", .{dangling_count});
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

                                    // NOTE: Don't remove DanglingItem component here - the task engine's
                                    // storeCompleted handler needs it in dangling_items map.
                                    // The component will be removed when the delivery completes.

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

                            // Match EIS (dangling item delivery), IIS (task-managed transfer), or EOS (output storage)
                            const is_target_storage = dist_check < 10.0 and
                                (storage.role == .eis or storage.role == .iis or storage.role == .eos) and
                                storage.accepts != null;

                            if (is_target_storage) {
                                // Place item at storage position
                                game.setWorldPositionXY(item_entity, storage_pos.x, storage_pos.y);

                                const storage_id = engine.entityToU64(storage_entity);

                                std.log.info("[WorkerMovement] Worker {d} delivered item {d} to {s} {d}", .{
                                    worker_id,
                                    item_id,
                                    @tagName(storage.role),
                                    storage_id,
                                });

                                // Clean up worker→item tracking
                                _ = task_hooks.worker_carried_items.remove(worker_id);

                                // Handle based on storage role
                                if (storage.role == .eis) {
                                    // Dangling item delivered to EIS - get item type and notify
                                    if (registry.tryGet(DanglingItem, item_entity)) |dangling| {
                                        _ = Context.itemAdded(storage_id, dangling.item_type);
                                        // Remove DanglingItem component - item is now "stored"
                                        registry.remove(DanglingItem, item_entity);
                                        std.log.info("[WorkerMovement] Removed DanglingItem component from item {d} (now stored in EIS)", .{item_id});
                                    }
                                    // Track item at EIS storage for later consumption
                                    task_hooks.storage_items.put(storage_id, item_id) catch {};
                                    // Check for remaining dangling items BEFORE notifying task engine
                                    // This ensures all dangling items are picked up before workstation tasks start
                                    if (!tryAssignDanglingItem(registry, entity, worker_id)) {
                                        // No more dangling items - mark worker as available for task engine
                                        _ = Context.workerAvailable(worker_id);
                                    }
                                } else if (storage.role == .iis) {
                                    task_hooks.storage_items.put(storage_id, item_id) catch {};
                                    _ = Context.storeCompleted(worker_id);
                                } else if (storage.role == .eos) {
                                    // Output item (bread) delivered to EOS - remove DanglingItem and complete store
                                    if (registry.tryGet(DanglingItem, item_entity)) |_| {
                                        registry.remove(DanglingItem, item_entity);
                                        std.log.info("[WorkerMovement] Removed DanglingItem component from item {d} (now stored in EOS)", .{item_id});
                                    }
                                    // Track item at EOS storage
                                    task_hooks.storage_items.put(storage_id, item_id) catch {};
                                    // Clean up store target tracking
                                    _ = task_hooks.worker_store_target.remove(worker_id);
                                    // Notify task engine that store is complete
                                    _ = Context.storeCompleted(worker_id);
                                }
                                break;
                            }
                        }
                    } else {
                        // Regular task store - notify engine
                        _ = Context.storeCompleted(worker_id);
                    }
                },
                .pickup => {
                    // Worker arrived at EIS to pick up item
                    // After picking up, move to IIS before calling pickupCompleted
                    task_hooks.ensureWorkerItemsInit();
                    const eis_storage_id = task_hooks.worker_pickup_storage.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] pickup: no pickup storage tracked for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Get the item at EIS and attach to worker
                    const item_id = task_hooks.storage_items.get(eis_storage_id) orelse {
                        std.log.warn("[WorkerMovement] pickup: no item found at EIS {d}", .{eis_storage_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    const item_entity = engine.entityFromU64(item_id);

                    // Attach item to worker (parent/child relationship)
                    game.setParent(item_entity, entity) catch |err| {
                        std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                    };
                    game.setLocalPositionXY(item_entity, 0, 10);

                    // Track that worker is carrying this item
                    task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                    // Remove item from EIS storage tracking
                    _ = task_hooks.storage_items.remove(eis_storage_id);

                    std.log.info("[WorkerMovement] pickup: attached item {d} from EIS {d} to worker {d}", .{
                        item_id, eis_storage_id, worker_id,
                    });

                    // Get the EIS storage to find what item type it accepts
                    const eis_entity = engine.entityFromU64(eis_storage_id);
                    const eis_storage = registry.tryGet(Storage, eis_entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: EIS {d} has no Storage component", .{eis_storage_id});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Find the workstation this worker is assigned to
                    const ws_id = task_hooks.worker_workstation.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] pickup: worker {d} not assigned to any workstation", .{worker_id});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Find the IIS that accepts the same item type
                    const ws_entity = engine.entityFromU64(ws_id);
                    const workstation = registry.tryGet(Workstation, ws_entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: workstation {d} has no Workstation component", .{ws_id});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Find IIS that accepts the same item type as the EIS
                    var found_iis = false;
                    for (workstation.storages) |storage_entity_ref| {
                        const storage = registry.tryGet(Storage, storage_entity_ref) orelse continue;
                        if (storage.role == .iis and storage.accepts == eis_storage.accepts) {
                            const iis_pos = registry.tryGet(Position, storage_entity_ref) orelse continue;
                            const iis_id = engine.entityToU64(storage_entity_ref);

                            // Track which IIS we're delivering to (reuse worker_pickup_storage)
                            task_hooks.worker_pickup_storage.put(worker_id, iis_id) catch {};

                            std.log.info("[WorkerMovement] pickup: worker {d} moving from EIS {d} to IIS {d} at ({d},{d})", .{
                                worker_id, eis_storage_id, iis_id, iis_pos.x, iis_pos.y,
                            });

                            // Set new target to IIS
                            registry.set(entity, MovementTarget{
                                .target_x = iis_pos.x,
                                .target_y = iis_pos.y,
                                .action = .deliver_to_iis,
                            });
                            found_iis = true;
                            break;
                        }
                    }

                    if (!found_iis) {
                        std.log.warn("[WorkerMovement] pickup: no IIS found for item type, completing pickup directly", .{});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                    }
                },
                .deliver_to_iis => {
                    // Worker arrived at IIS to deposit item
                    task_hooks.ensureWorkerItemsInit();

                    // Get the IIS we're delivering to
                    const iis_id = task_hooks.worker_pickup_storage.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: no IIS tracked for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Get the item the worker is carrying
                    const item_id = task_hooks.worker_carried_items.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: worker {d} not carrying any item", .{worker_id});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    const item_entity = engine.entityFromU64(item_id);
                    const iis_entity = engine.entityFromU64(iis_id);
                    const iis_pos = registry.tryGet(Position, iis_entity) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: IIS {d} has no Position", .{iis_id});
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Detach item from worker and place at IIS
                    game.removeParent(item_entity);
                    game.setWorldPositionXY(item_entity, iis_pos.x, iis_pos.y);

                    // Track item at IIS storage
                    task_hooks.storage_items.put(iis_id, item_id) catch {};

                    std.log.info("[WorkerMovement] deliver_to_iis: worker {d} deposited item {d} at IIS {d}", .{
                        worker_id, item_id, iis_id,
                    });

                    // Clean up tracking - worker no longer carrying item
                    _ = task_hooks.worker_carried_items.remove(worker_id);
                    _ = task_hooks.worker_pickup_storage.remove(worker_id);

                    // Now call pickupCompleted - task engine will advance to Process step
                    registry.remove(MovementTarget, entity);
                    _ = Context.pickupCompleted(worker_id);
                },
                .transport_pickup => {
                    // Worker arrived to pick up item from storage for transport
                    task_hooks.ensureWorkerItemsInit();
                    if (task_hooks.worker_pickup_storage.get(worker_id)) |storage_id| {
                        if (task_hooks.storage_items.get(storage_id)) |item_id| {
                            const item_entity = engine.entityFromU64(item_id);

                            // Attach item to worker (parent/child relationship)
                            game.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                            };
                            game.setLocalPositionXY(item_entity, 0, 10);

                            // Track that worker is carrying this item
                            task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                            // Remove item from storage tracking
                            _ = task_hooks.storage_items.remove(storage_id);

                            std.log.info("[WorkerMovement] transport_pickup: attached item {d} from storage {d} to worker {d}", .{
                                item_id, storage_id, worker_id,
                            });
                        } else {
                            std.log.warn("[WorkerMovement] transport_pickup: no item found at storage {d}", .{storage_id});
                        }

                        // Clean up pickup tracking
                        _ = task_hooks.worker_pickup_storage.remove(worker_id);
                    } else {
                        std.log.warn("[WorkerMovement] transport_pickup: no pickup storage tracked for worker {d}", .{worker_id});
                    }

                    // Remove MovementTarget before calling pickupCompleted since hooks may set a new one
                    registry.remove(MovementTarget, entity);
                    _ = Context.pickupCompleted(worker_id);
                },
                .pickup_from_ios => {
                    // Worker arrived at IOS to pick up the output item (bread)
                    task_hooks.ensureWorkerItemsInit();

                    // Find the IOS at this position and get the bread
                    const ws_id = task_hooks.worker_workstation.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] pickup_from_ios: worker {d} not assigned to any workstation", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.storeCompleted(worker_id);
                        break;
                    };

                    const ws_entity_ref = engine.entityFromU64(ws_id);
                    const workstation = registry.tryGet(Workstation, ws_entity_ref) orelse {
                        std.log.warn("[WorkerMovement] pickup_from_ios: workstation {d} has no Workstation component", .{ws_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.storeCompleted(worker_id);
                        break;
                    };

                    // Find IOS and its item
                    var found_ios = false;
                    for (workstation.storages) |storage_entity_ref| {
                        const storage = registry.tryGet(Storage, storage_entity_ref) orelse continue;
                        if (storage.role == .ios) {
                            const ios_id = engine.entityToU64(storage_entity_ref);

                            // Get the item (bread) at IOS
                            const item_id = task_hooks.storage_items.get(ios_id) orelse {
                                std.log.warn("[WorkerMovement] pickup_from_ios: no item at IOS {d}", .{ios_id});
                                break;
                            };

                            const item_entity = engine.entityFromU64(item_id);

                            // Attach bread to worker
                            game.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] pickup_from_ios: failed to attach item: {}", .{err});
                            };
                            game.setLocalPositionXY(item_entity, 0, 10);

                            // Track that worker is carrying this item
                            task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                            // Remove item from IOS tracking
                            _ = task_hooks.storage_items.remove(ios_id);

                            std.log.info("[WorkerMovement] pickup_from_ios: worker {d} picked up item {d} from IOS {d}", .{
                                worker_id, item_id, ios_id,
                            });

                            // Get the target EOS and move there
                            const eos_id = task_hooks.worker_store_target.get(worker_id) orelse {
                                std.log.warn("[WorkerMovement] pickup_from_ios: no EOS target for worker {d}", .{worker_id});
                                registry.remove(MovementTarget, entity);
                                _ = Context.storeCompleted(worker_id);
                                break;
                            };

                            const eos_entity = engine.entityFromU64(eos_id);
                            const eos_pos = registry.tryGet(Position, eos_entity) orelse {
                                std.log.warn("[WorkerMovement] pickup_from_ios: EOS {d} has no Position", .{eos_id});
                                registry.remove(MovementTarget, entity);
                                _ = Context.storeCompleted(worker_id);
                                break;
                            };

                            std.log.info("[WorkerMovement] pickup_from_ios: worker {d} moving to EOS {d} at ({d},{d})", .{
                                worker_id, eos_id, eos_pos.x, eos_pos.y,
                            });

                            // Set target to EOS
                            registry.set(entity, MovementTarget{
                                .target_x = eos_pos.x,
                                .target_y = eos_pos.y,
                                .action = .store,
                            });
                            found_ios = true;
                            break;
                        }
                    }

                    if (!found_ios) {
                        std.log.warn("[WorkerMovement] pickup_from_ios: no IOS found in workstation", .{});
                        registry.remove(MovementTarget, entity);
                        _ = Context.storeCompleted(worker_id);
                    }
                },
                .arrive_at_workstation => {
                    // Worker arrived at workstation to start work
                    _ = Context.storeCompleted(worker_id);
                },
            }

            // Skip target comparison for actions that call pickupCompleted and remove MovementTarget
            // Note: .pickup now sets a new target to IIS, so it should NOT skip the check
            const skip_target_check = (old_action == .deliver_to_iis or old_action == .transport_pickup or old_action == .pickup_from_ios);

            // Only remove MovementTarget if no new target was set by hooks
            var target_was_removed = false;
            if (!skip_target_check) {
                if (registry.tryGet(MovementTarget, entity)) |new_target| {
                    std.log.info("[WorkerMovement] After action, checking target: old=({d},{d}) new=({d},{d})", .{
                        old_target_x,
                        old_target_y,
                        new_target.target_x,
                        new_target.target_y,
                    });
                    if (new_target.target_x == old_target_x and new_target.target_y == old_target_y) {
                        // Same target position - check if this is a pickup action
                        // If worker is already at pickup location, immediately complete the pickup
                        if (new_target.action == .pickup or new_target.action == .transport_pickup) {
                            std.log.info("[WorkerMovement] Worker already at pickup location, completing pickup immediately", .{});
                            registry.remove(MovementTarget, entity);
                            _ = Context.pickupCompleted(worker_id);
                        } else {
                            // Not a pickup - task complete, remove component
                            std.log.info("[WorkerMovement] Removing MovementTarget (same position)", .{});
                            registry.remove(MovementTarget, entity);
                            target_was_removed = true;
                        }
                    } else {
                        std.log.info("[WorkerMovement] Keeping MovementTarget (new position set by hook)", .{});
                    }
                    // else: new target was set by hook, keep it
                }
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
