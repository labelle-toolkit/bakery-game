// Worker movement script
//
// Handles worker movement towards targets (dangling items, storages).
// Queries for entities with MovementTarget component and moves them.
// Notifies task engine when workers arrive at their destinations.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const task_hooks = @import("../hooks/task_hooks.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Context = main.labelle_tasksContext;
const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const WorkProgress = work_progress.WorkProgress;
const BoundTypes = main.labelle_tasksBindItems;
const Storage = BoundTypes.Storage;
const DanglingItem = BoundTypes.DanglingItem;
const Worker = BoundTypes.Worker;
const Workstation = BoundTypes.Workstation;

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

                            // NOTE: Don't remove DanglingItem component here - the task engine's
                            // storeCompleted handler needs it in dangling_items map.
                            // The component will be removed when the delivery completes.

                            // Attach item to worker (parent/child relationship)
                            game.hierarchy.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                            };
                            game.pos.setLocalPositionXY(item_entity, 0, 10);
                            std.log.info("[WorkerMovement] Attached item {d} to worker {d} (parent/child)", .{ item_id, worker_id });

                            // Track the item for delivery completion
                            task_hooks.ensureWorkerItemsInit();
                            task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                            std.log.info("[WorkerMovement] Worker {d} picked up item {d} ({s})", .{
                                worker_id,
                                item_id,
                                @tagName(dangling_item.item_type),
                            });

                            // Notify task engine - it will dispatch store_started hook
                            // which sets MovementTarget to the EIS
                            _ = Context.pickupCompleted(worker_id);

                            item_found = true;
                            break;
                        }
                    }

                    if (!item_found) {
                        std.log.warn("[WorkerMovement] pickup_dangling: no dangling item found at worker position!", .{});
                        // Clean up worker tracking state before marking as available
                        task_hooks.ensureWorkerItemsInit();
                        _ = task_hooks.worker_carried_items.remove(worker_id);
                        _ = Context.workerAvailable(worker_id);
                    }
                },
                .store => {
                    // Worker delivered item (either dangling item to EIS, or task item to EOS)
                    task_hooks.ensureWorkerItemsInit();
                    if (task_hooks.worker_carried_items.get(worker_id)) |item_id| {
                        // This was a dangling item delivery - notify engine that EIS has item
                        const item_entity = engine.entityFromU64(item_id);

                        // Detach item from worker
                        game.hierarchy.removeParent(item_entity);

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

                            // Match EIS (dangling item delivery), IIS (task-managed transfer), EOS (output storage), or standalone
                            const is_target_storage = dist_check < 10.0 and
                                (storage.role == .eis or storage.role == .iis or storage.role == .eos or storage.role == .standalone) and
                                storage.accepts != null;

                            if (is_target_storage) {
                                // Place item at storage position
                                game.pos.setWorldPositionXY(item_entity, storage_pos.x, storage_pos.y);

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
                                    // Dangling item delivered to EIS - notify task engine
                                    // Task engine will dispatch item_delivered, clear dangling_task,
                                    // and re-evaluate workstations (which makes worker available)
                                    task_hooks.storage_items.put(storage_id, item_id) catch {};
                                    std.log.info("[WorkerMovement] Calling storeCompleted for dangling item delivery to EIS {d}", .{storage_id});
                                    _ = Context.storeCompleted(worker_id);
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
                    game.hierarchy.setParent(item_entity, entity) catch |err| {
                        std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                    };
                    game.pos.setLocalPositionXY(item_entity, 0, 10);

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
                    game.hierarchy.removeParent(item_entity);
                    game.pos.setWorldPositionXY(item_entity, iis_pos.x, iis_pos.y);

                    // Track item at IIS storage
                    task_hooks.storage_items.put(iis_id, item_id) catch {};

                    std.log.info("[WorkerMovement] deliver_to_iis: worker {d} deposited item {d} at IIS {d}", .{
                        worker_id, item_id, iis_id,
                    });

                    // Clean up tracking - worker no longer carrying item
                    _ = task_hooks.worker_carried_items.remove(worker_id);
                    _ = task_hooks.worker_pickup_storage.remove(worker_id);

                    // Remove MovementTarget before calling pickupCompleted
                    // (pickup_started hook may set a new one if there's another pickup)
                    registry.remove(MovementTarget, entity);

                    // Call pickupCompleted - task engine will advance state
                    // NOTE: pickupCompleted may trigger pickup_started for next EIS,
                    // which sets a new MovementTarget. Only redirect to workstation
                    // if no new pickup was triggered.
                    _ = Context.pickupCompleted(worker_id);

                    // Check if worker still needs to go to workstation after pickups complete
                    // (pickup_started may have set a new MovementTarget for next pickup)
                    if (registry.tryGet(MovementTarget, entity) == null) {
                        // No new pickup target - check if worker is pending arrival at workstation
                        if (task_hooks.worker_pending_arrival.get(worker_id)) |_| {
                            // Get workstation position and redirect worker there
                            if (task_hooks.worker_workstation.get(worker_id)) |ws_id| {
                                const ws_entity = engine.entityFromU64(ws_id);
                                if (registry.tryGet(Position, ws_entity)) |ws_pos| {
                                    std.log.info("[WorkerMovement] deliver_to_iis: pickups complete, worker {d} moving to workstation {d} at ({d},{d})", .{
                                        worker_id, ws_id, ws_pos.x, ws_pos.y,
                                    });
                                    registry.set(entity, MovementTarget{
                                        .target_x = ws_pos.x,
                                        .target_y = ws_pos.y,
                                        .action = .arrive_at_workstation,
                                    });
                                }
                            }
                        }
                    }
                },
                .transport_pickup => {
                    // Worker arrived at EOS to pick up item for engine-driven transport
                    task_hooks.ensureWorkerItemsInit();

                    // Get the EOS this worker is picking from
                    const eos_id = task_hooks.worker_transport_from.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: no EOS tracked for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    // Get the item at EOS
                    const item_id = task_hooks.storage_items.get(eos_id) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: no item found at EOS {d}", .{eos_id});
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        _ = task_hooks.worker_transport_to.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    const item_entity = engine.entityFromU64(item_id);

                    // Attach item to worker (parent/child relationship)
                    game.hierarchy.setParent(item_entity, entity) catch |err| {
                        std.log.err("[WorkerMovement] transport_pickup: failed to attach item to worker: {}", .{err});
                    };
                    game.pos.setLocalPositionXY(item_entity, 0, 10);

                    // Track that worker is carrying this item
                    task_hooks.worker_carried_items.put(worker_id, item_id) catch {};

                    // Remove item from EOS storage tracking (game-side)
                    _ = task_hooks.storage_items.remove(eos_id);

                    std.log.info("[WorkerMovement] transport_pickup: worker {d} picked up item {d} from EOS {d}", .{
                        worker_id, item_id, eos_id,
                    });

                    // Notify engine that pickup is complete (engine clears EOS, tracks item)
                    _ = Context.transportPickupCompleted(worker_id);

                    // Get the destination storage
                    const dest_id = task_hooks.worker_transport_to.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: no destination for worker {d}", .{worker_id});
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        _ = task_hooks.worker_carried_items.remove(worker_id);
                        game.hierarchy.removeParent(item_entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    // Get destination position
                    const dest_entity = engine.entityFromU64(dest_id);
                    const dest_pos = registry.tryGet(Position, dest_entity) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: destination {d} has no Position", .{dest_id});
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        _ = task_hooks.worker_transport_to.remove(worker_id);
                        _ = task_hooks.worker_carried_items.remove(worker_id);
                        game.hierarchy.removeParent(item_entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    std.log.info("[WorkerMovement] transport_pickup: worker {d} moving to destination {d} at ({d},{d})", .{
                        worker_id, dest_id, dest_pos.x, dest_pos.y,
                    });

                    // Set target to destination with transport_deliver action
                    registry.set(entity, MovementTarget{
                        .target_x = dest_pos.x,
                        .target_y = dest_pos.y,
                        .action = .transport_deliver,
                    });
                },
                .transport_deliver => {
                    // Worker arrived at destination to deliver item (engine-driven transport)
                    task_hooks.ensureWorkerItemsInit();

                    // Get the item the worker is carrying
                    const item_id = task_hooks.worker_carried_items.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: worker {d} not carrying any item", .{worker_id});
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        _ = task_hooks.worker_transport_to.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    // Get the destination storage
                    const dest_id = task_hooks.worker_transport_to.get(worker_id) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: no destination tracked for worker {d}", .{worker_id});
                        _ = task_hooks.worker_carried_items.remove(worker_id);
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    const item_entity = engine.entityFromU64(item_id);
                    const dest_entity = engine.entityFromU64(dest_id);
                    const dest_pos = registry.tryGet(Position, dest_entity) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: destination {d} has no Position", .{dest_id});
                        _ = task_hooks.worker_carried_items.remove(worker_id);
                        _ = task_hooks.worker_transport_from.remove(worker_id);
                        _ = task_hooks.worker_transport_to.remove(worker_id);
                        game.hierarchy.removeParent(item_entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    // Detach item from worker and place at destination
                    game.hierarchy.removeParent(item_entity);
                    game.pos.setWorldPositionXY(item_entity, dest_pos.x, dest_pos.y);

                    // Track item at destination storage (game-side)
                    task_hooks.storage_items.put(dest_id, item_id) catch {};

                    const from_id = task_hooks.worker_transport_from.get(worker_id) orelse 0;

                    std.log.info("[WorkerMovement] transport_deliver: worker {d} delivered item {d} from {d} to {d}", .{
                        worker_id, item_id, from_id, dest_id,
                    });

                    // Clean up all transport tracking
                    _ = task_hooks.worker_carried_items.remove(worker_id);
                    _ = task_hooks.worker_transport_from.remove(worker_id);
                    _ = task_hooks.worker_transport_to.remove(worker_id);

                    // Remove MovementTarget before notifying engine
                    registry.remove(MovementTarget, entity);

                    // Notify engine that delivery is complete
                    // Engine handles: placing item at destination, releasing worker, releasing reservation
                    _ = Context.transportDeliveryCompleted(worker_id);

                    std.log.info("[WorkerMovement] transport_deliver: notified engine delivery complete for worker {d}", .{worker_id});
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
                            game.hierarchy.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] pickup_from_ios: failed to attach item: {}", .{err});
                            };
                            game.pos.setLocalPositionXY(item_entity, 0, 10);

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
                    std.log.info("[WorkerMovement] arrive_at_workstation: worker {d} arrived", .{worker_id});

                    // Clear pending arrival flag
                    task_hooks.ensureWorkerItemsInit();
                    _ = task_hooks.worker_pending_arrival.remove(worker_id);

                    // Get workstation ID and start work
                    if (task_hooks.worker_workstation.get(worker_id)) |workstation_id| {
                        const ws_entity = engine.entityFromU64(workstation_id);
                        if (registry.tryGet(Workstation, ws_entity)) |workstation| {
                            // Set up WorkProgress to start the work timer
                            registry.set(entity, WorkProgress{
                                .workstation_id = workstation_id,
                                .duration = @floatFromInt(workstation.process_duration),
                            });
                            std.log.info("[WorkerMovement] arrive_at_workstation: worker {d} starting work at workstation {d} (duration={d}s)", .{
                                worker_id,
                                workstation_id,
                                workstation.process_duration,
                            });
                        }
                    }
                },
            }

            // Skip target comparison for actions that manually remove MovementTarget
            // Note: .pickup now sets a new target to IIS, so it should NOT skip the check
            const skip_target_check = (old_action == .deliver_to_iis or old_action == .transport_pickup or old_action == .transport_deliver or old_action == .pickup_from_ios);

            // Only remove MovementTarget if no new target was set by hooks
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
                        if (new_target.action == .pickup or new_target.action == .pickup_dangling) {
                            // Worker already at pickup location, complete immediately
                            std.log.info("[WorkerMovement] Worker already at pickup location, completing pickup immediately", .{});
                            registry.remove(MovementTarget, entity);
                            _ = Context.pickupCompleted(worker_id);
                        } else if (new_target.action == .transport_pickup) {
                            // Transport pickup at same location (e.g. worker just stored to this EOS
                            // and engine immediately assigned transport from it). Keep the
                            // MovementTarget so the full transport_pickup handler runs next frame.
                            std.log.info("[WorkerMovement] Worker at transport pickup location, will process next frame", .{});
                        } else {
                            // Not a pickup - task complete, remove component
                            std.log.info("[WorkerMovement] Removing MovementTarget (same position)", .{});
                            registry.remove(MovementTarget, entity);
                        }
                    } else {
                        std.log.info("[WorkerMovement] Keeping MovementTarget (new position set by hook)", .{});
                    }
                    // else: new target was set by hook, keep it
                }
            }
        } else {
            // Move towards target
            const move_dist = @min(target.speed * dt, dist);
            const move_x = (dx / dist) * move_dist;
            const move_y = (dy / dist) * move_dist;
            game.pos.moveLocalPosition(entity, move_x, move_y);

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
