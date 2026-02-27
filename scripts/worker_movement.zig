// Worker movement script
//
// Handles worker movement towards targets (dangling items, storages).
// Queries for entities with MovementTarget component and moves them.
// Notifies task engine when workers arrive at their destinations.
//
// All game-side state is stored in ECS components (no HashMaps).

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Context = main.labelle_tasksContext;
const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const WorkProgress = work_progress.WorkProgress;
const StoredItem = main.StoredItem;
const CarriedItem = main.CarriedItem;
const AssignedWorkstation = main.AssignedWorkstation;
const TransportTask = main.TransportTask;
const StoreTarget = main.StoreTarget;
const PickupSource = main.PickupSource;
const PendingArrival = main.PendingArrival;
const PendingTransport = main.PendingTransport;
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

                            // Attach item to worker (parent/child relationship)
                            game.hierarchy.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                            };
                            game.pos.setLocalPositionXY(item_entity, 0, 10);
                            std.log.info("[WorkerMovement] Attached item {d} to worker {d} (parent/child)", .{ item_id, worker_id });

                            // Track the item for delivery completion
                            registry.set(entity, CarriedItem{ .item_entity = item_id });

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
                        registry.remove(CarriedItem, entity);
                        _ = Context.workerAvailable(worker_id);
                    }
                },
                .store => {
                    // Worker delivered item (either dangling item to EIS, or task item to EOS)
                    if (registry.tryGet(CarriedItem, entity)) |carried| {
                        // This was a dangling item delivery - notify engine that EIS has item
                        const item_entity = engine.entityFromU64(carried.item_entity);
                        const item_id = carried.item_entity;

                        // Detach item from worker
                        game.hierarchy.removeParent(item_entity);

                        // Position item at storage location
                        var storage_view = registry.view(.{ Storage, Position });
                        var storage_iter = storage_view.entityIterator();

                        while (storage_iter.next()) |storage_entity| {
                            const storage = storage_view.get(Storage, storage_entity);
                            const storage_pos = storage_view.get(Position, storage_entity);

                            // Check if this is the target storage
                            const dx_check = storage_pos.x - pos.x;
                            const dy_check = storage_pos.y - pos.y;
                            const dist_check = @sqrt(dx_check * dx_check + dy_check * dy_check);

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
                                registry.remove(CarriedItem, entity);

                                // Handle based on storage role
                                if (storage.role == .eis) {
                                    // Dangling item delivered to EIS
                                    registry.set(storage_entity, StoredItem{ .item_entity = item_id });
                                    std.log.info("[WorkerMovement] Calling storeCompleted for dangling item delivery to EIS {d}", .{storage_id});
                                    _ = Context.storeCompleted(worker_id);
                                } else if (storage.role == .iis) {
                                    registry.set(storage_entity, StoredItem{ .item_entity = item_id });
                                    _ = Context.storeCompleted(worker_id);
                                } else if (storage.role == .eos) {
                                    // Output item (bread) delivered to EOS
                                    if (registry.tryGet(DanglingItem, item_entity)) |_| {
                                        registry.remove(DanglingItem, item_entity);
                                        std.log.info("[WorkerMovement] Removed DanglingItem component from item {d} (now stored in EOS)", .{item_id});
                                    }
                                    registry.set(storage_entity, StoredItem{ .item_entity = item_id });
                                    // Clean up store target tracking
                                    registry.remove(StoreTarget, entity);
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
                    const pickup_src = registry.tryGet(PickupSource, entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: no pickup storage tracked for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };
                    const eis_storage_id = pickup_src.storage_id;

                    // Get the item at EIS and attach to worker
                    const eis_entity = engine.entityFromU64(eis_storage_id);
                    const stored = registry.tryGet(StoredItem, eis_entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: no item found at EIS {d}", .{eis_storage_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };
                    const item_id = stored.item_entity;

                    const item_entity = engine.entityFromU64(item_id);

                    // Attach item to worker (parent/child relationship)
                    game.hierarchy.setParent(item_entity, entity) catch |err| {
                        std.log.err("[WorkerMovement] Failed to attach item to worker: {}", .{err});
                    };
                    game.pos.setLocalPositionXY(item_entity, 0, 10);

                    // Track that worker is carrying this item
                    registry.set(entity, CarriedItem{ .item_entity = item_id });

                    // Remove item from EIS storage tracking
                    registry.remove(StoredItem, eis_entity);

                    std.log.info("[WorkerMovement] pickup: attached item {d} from EIS {d} to worker {d}", .{
                        item_id, eis_storage_id, worker_id,
                    });

                    // Get the EIS storage to find what item type it accepts
                    const eis_storage = registry.tryGet(Storage, eis_entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: EIS {d} has no Storage component", .{eis_storage_id});
                        registry.remove(PickupSource, entity);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Find the workstation this worker is assigned to
                    const assigned_ws = registry.tryGet(AssignedWorkstation, entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: worker {d} not assigned to any workstation", .{worker_id});
                        registry.remove(PickupSource, entity);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };
                    const ws_id = assigned_ws.workstation_id;

                    // Find the IIS that accepts the same item type
                    const ws_entity = engine.entityFromU64(ws_id);
                    const workstation = registry.tryGet(Workstation, ws_entity) orelse {
                        std.log.warn("[WorkerMovement] pickup: workstation {d} has no Workstation component", .{ws_id});
                        registry.remove(PickupSource, entity);
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

                            // Track which IIS we're delivering to (reuse PickupSource)
                            registry.set(entity, PickupSource{ .storage_id = iis_id });

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
                        registry.remove(PickupSource, entity);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                    }
                },
                .deliver_to_iis => {
                    // Worker arrived at IIS to deposit item

                    // Get the IIS we're delivering to
                    const pickup_src = registry.tryGet(PickupSource, entity) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: no IIS tracked for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };
                    const iis_id = pickup_src.storage_id;

                    // Get the item the worker is carrying
                    const carried = registry.tryGet(CarriedItem, entity) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: worker {d} not carrying any item", .{worker_id});
                        registry.remove(PickupSource, entity);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };
                    const item_id = carried.item_entity;

                    const item_entity = engine.entityFromU64(item_id);
                    const iis_entity = engine.entityFromU64(iis_id);
                    const iis_pos = registry.tryGet(Position, iis_entity) orelse {
                        std.log.warn("[WorkerMovement] deliver_to_iis: IIS {d} has no Position", .{iis_id});
                        registry.remove(PickupSource, entity);
                        registry.remove(MovementTarget, entity);
                        _ = Context.pickupCompleted(worker_id);
                        break;
                    };

                    // Detach item from worker and place at IIS
                    game.hierarchy.removeParent(item_entity);
                    game.pos.setWorldPositionXY(item_entity, iis_pos.x, iis_pos.y);

                    // Track item at IIS storage
                    registry.set(iis_entity, StoredItem{ .item_entity = item_id });

                    std.log.info("[WorkerMovement] deliver_to_iis: worker {d} deposited item {d} at IIS {d}", .{
                        worker_id, item_id, iis_id,
                    });

                    // Clean up tracking - worker no longer carrying item
                    registry.remove(CarriedItem, entity);
                    registry.remove(PickupSource, entity);

                    // Remove MovementTarget before calling pickupCompleted
                    // (pickup_started hook may set a new one if there's another pickup)
                    registry.remove(MovementTarget, entity);

                    // Call pickupCompleted - task engine will advance state
                    _ = Context.pickupCompleted(worker_id);

                    // Check if worker still needs to go to workstation after pickups complete
                    if (registry.tryGet(MovementTarget, entity) == null) {
                        // No new pickup target - check if worker is pending arrival at workstation
                        if (registry.tryGet(PendingArrival, entity) != null) {
                            // Get workstation position and redirect worker there
                            if (registry.tryGet(AssignedWorkstation, entity)) |aw| {
                                const ws_entity = engine.entityFromU64(aw.workstation_id);
                                if (registry.tryGet(Position, ws_entity)) |ws_pos| {
                                    std.log.info("[WorkerMovement] deliver_to_iis: pickups complete, worker {d} moving to workstation {d} at ({d},{d})", .{
                                        worker_id, aw.workstation_id, ws_pos.x, ws_pos.y,
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

                    // Get the transport task
                    const task = registry.tryGet(TransportTask, entity) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: no transport task for worker {d}", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        break;
                    };
                    const eos_id = task.from_storage;
                    const dest_id = task.to_storage;

                    // Get the item at EOS
                    const eos_entity = engine.entityFromU64(eos_id);
                    const stored = registry.tryGet(StoredItem, eos_entity) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: no item found at EOS {d}", .{eos_id});
                        registry.remove(PendingTransport, eos_entity);
                        registry.remove(TransportTask, entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };
                    const item_id = stored.item_entity;

                    const item_entity = engine.entityFromU64(item_id);

                    // Attach item to worker (parent/child relationship)
                    game.hierarchy.setParent(item_entity, entity) catch |err| {
                        std.log.err("[WorkerMovement] transport_pickup: failed to attach item to worker: {}", .{err});
                    };
                    game.pos.setLocalPositionXY(item_entity, 0, 10);

                    // Track that worker is carrying this item
                    registry.set(entity, CarriedItem{ .item_entity = item_id });

                    // Remove item from EOS storage tracking (game-side)
                    registry.remove(StoredItem, eos_entity);

                    std.log.info("[WorkerMovement] transport_pickup: worker {d} picked up item {d} from EOS {d}", .{
                        worker_id, item_id, eos_id,
                    });

                    // Notify engine that pickup is complete (engine clears EOS, tracks item)
                    _ = Context.transportPickupCompleted(worker_id);

                    // Get destination position
                    const dest_entity = engine.entityFromU64(dest_id);
                    const dest_pos = registry.tryGet(Position, dest_entity) orelse {
                        std.log.warn("[WorkerMovement] transport_pickup: destination {d} has no Position", .{dest_id});
                        registry.remove(PendingTransport, eos_entity);
                        registry.remove(TransportTask, entity);
                        registry.remove(CarriedItem, entity);
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

                    // Get the item the worker is carrying
                    const carried = registry.tryGet(CarriedItem, entity) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: worker {d} not carrying any item", .{worker_id});
                        registry.remove(TransportTask, entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };
                    const item_id = carried.item_entity;

                    // Get the transport task
                    const task = registry.tryGet(TransportTask, entity) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: no transport task for worker {d}", .{worker_id});
                        registry.remove(CarriedItem, entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };
                    const dest_id = task.to_storage;
                    const from_id = task.from_storage;

                    const item_entity = engine.entityFromU64(item_id);
                    const dest_entity = engine.entityFromU64(dest_id);
                    const dest_pos = registry.tryGet(Position, dest_entity) orelse {
                        std.log.warn("[WorkerMovement] transport_deliver: destination {d} has no Position", .{dest_id});
                        registry.remove(CarriedItem, entity);
                        registry.remove(TransportTask, entity);
                        game.hierarchy.removeParent(item_entity);
                        registry.remove(MovementTarget, entity);
                        break;
                    };

                    // Detach item from worker and place at destination
                    game.hierarchy.removeParent(item_entity);
                    game.pos.setWorldPositionXY(item_entity, dest_pos.x, dest_pos.y);

                    // Track item at destination storage (game-side)
                    registry.set(dest_entity, StoredItem{ .item_entity = item_id });

                    std.log.info("[WorkerMovement] transport_deliver: worker {d} delivered item {d} from {d} to {d}", .{
                        worker_id, item_id, from_id, dest_id,
                    });

                    // Clean up all transport tracking
                    registry.remove(CarriedItem, entity);
                    registry.remove(TransportTask, entity);

                    // Clean up pending transport marker on source EOS
                    const from_entity = engine.entityFromU64(from_id);
                    registry.remove(PendingTransport, from_entity);

                    // Remove MovementTarget before notifying engine
                    registry.remove(MovementTarget, entity);

                    // Notify engine that delivery is complete
                    _ = Context.transportDeliveryCompleted(worker_id);

                    std.log.info("[WorkerMovement] transport_deliver: notified engine delivery complete for worker {d}", .{worker_id});
                },
                .pickup_from_ios => {
                    // Worker arrived at IOS to pick up the output item (bread)

                    const assigned_ws = registry.tryGet(AssignedWorkstation, entity) orelse {
                        std.log.warn("[WorkerMovement] pickup_from_ios: worker {d} not assigned to any workstation", .{worker_id});
                        registry.remove(MovementTarget, entity);
                        _ = Context.storeCompleted(worker_id);
                        break;
                    };
                    const ws_id = assigned_ws.workstation_id;

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
                            const stored = registry.tryGet(StoredItem, storage_entity_ref) orelse {
                                std.log.warn("[WorkerMovement] pickup_from_ios: no item at IOS {d}", .{ios_id});
                                break;
                            };
                            const item_id = stored.item_entity;

                            const item_entity = engine.entityFromU64(item_id);

                            // Attach bread to worker
                            game.hierarchy.setParent(item_entity, entity) catch |err| {
                                std.log.err("[WorkerMovement] pickup_from_ios: failed to attach item: {}", .{err});
                            };
                            game.pos.setLocalPositionXY(item_entity, 0, 10);

                            // Track that worker is carrying this item
                            registry.set(entity, CarriedItem{ .item_entity = item_id });

                            // Remove item from IOS tracking
                            registry.remove(StoredItem, storage_entity_ref);

                            std.log.info("[WorkerMovement] pickup_from_ios: worker {d} picked up item {d} from IOS {d}", .{
                                worker_id, item_id, ios_id,
                            });

                            // Get the target EOS and move there
                            const store_tgt = registry.tryGet(StoreTarget, entity) orelse {
                                std.log.warn("[WorkerMovement] pickup_from_ios: no EOS target for worker {d}", .{worker_id});
                                registry.remove(MovementTarget, entity);
                                _ = Context.storeCompleted(worker_id);
                                break;
                            };
                            const eos_id = store_tgt.storage_id;

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
                .seek_bed => {
                    // Worker arrived at bed/fountain facility for need fulfillment
                    const needs_manager = @import("needs_manager.zig");
                    if (needs_manager.getEngine()) |eng| {
                        _ = eng.handle(.{ .facility_reached = .{ .worker_id = worker_id } });
                    }
                    std.log.info("[WorkerMovement] seek_bed: worker {d} arrived at facility", .{worker_id});
                    registry.remove(MovementTarget, entity);
                },
                .seek_water => {
                    // Worker arrived at storage to pick up water for drink need
                    const needs_manager = @import("needs_manager.zig");
                    if (needs_manager.getEngine()) |eng| {
                        _ = eng.handle(.{ .item_picked_up = .{ .worker_id = worker_id } });
                    }
                    std.log.info("[WorkerMovement] seek_water: worker {d} picked up water", .{worker_id});
                    registry.remove(MovementTarget, entity);
                },
                .arrive_at_workstation => {
                    // Worker arrived at workstation to start work
                    std.log.info("[WorkerMovement] arrive_at_workstation: worker {d} arrived", .{worker_id});

                    // Clear pending arrival flag
                    registry.remove(PendingArrival, entity);

                    // Get workstation ID and start work
                    if (registry.tryGet(AssignedWorkstation, entity)) |aw| {
                        const ws_entity = engine.entityFromU64(aw.workstation_id);
                        if (registry.tryGet(Workstation, ws_entity)) |workstation| {
                            // Set up WorkProgress to start the work timer
                            registry.set(entity, WorkProgress{
                                .workstation_id = aw.workstation_id,
                                .duration = @floatFromInt(workstation.process_duration),
                            });
                            std.log.info("[WorkerMovement] arrive_at_workstation: worker {d} starting work at workstation {d} (duration={d}s)", .{
                                worker_id,
                                aw.workstation_id,
                                workstation.process_duration,
                            });
                        }
                    }
                },
            }

            // Skip target comparison for actions that manually remove MovementTarget
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
                        if (new_target.action == .pickup or new_target.action == .pickup_dangling) {
                            std.log.info("[WorkerMovement] Worker already at pickup location, completing pickup immediately", .{});
                            registry.remove(MovementTarget, entity);
                            _ = Context.pickupCompleted(worker_id);
                        } else if (new_target.action == .transport_pickup) {
                            std.log.info("[WorkerMovement] Worker at transport pickup location, will process next frame", .{});
                        } else {
                            std.log.info("[WorkerMovement] Removing MovementTarget (same position)", .{});
                            registry.remove(MovementTarget, entity);
                        }
                    } else {
                        std.log.info("[WorkerMovement] Keeping MovementTarget (new position set by hook)", .{});
                    }
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
            if (registry.tryGet(CarriedItem, entity)) |carried| {
                const item_entity = engine.entityFromU64(carried.item_entity);
                if (registry.tryGet(Position, item_entity)) |item_pos| {
                    const worker_x_int: i32 = @intFromFloat(pos.x);
                    if (@mod(worker_x_int, 100) < 3) {
                        std.log.info("[WorkerMovement] Worker {d} at ({d:.0},{d:.0}), item {d} at ({d:.0},{d:.0})", .{
                            worker_id, pos.x, pos.y, carried.item_entity, item_pos.x, item_pos.y,
                        });
                    }
                }
            }
        }
    }
}
