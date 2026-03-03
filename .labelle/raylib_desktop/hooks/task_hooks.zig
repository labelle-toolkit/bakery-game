// Task hooks for the bakery game
//
// Game-specific task event handlers for labelle-tasks.
// Engine hooks (game_init, scene_load, game_deinit) are automatically
// provided by createEngineHooks via project.labelle configuration.
//
// Hook payloads are enriched with .registry and .game pointers,
// so handlers can access the ECS directly.
//
// All game-side state is stored in ECS components (no HashMaps).

const std = @import("std");
const log = std.log.scoped(.task_hooks);
const engine = @import("labelle-engine");
const labelle_tasks = @import("labelle-tasks");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const items = @import("../enums/items.zig");
const main = @import("../main.zig");

// Import bread prefab for instantiation in process_completed
const bread_prefab = @import("../prefabs/bread.zon");

const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const navigation_intent_comp = @import("../components/navigation_intent.zig");
const NavigationIntent = navigation_intent_comp.NavigationIntent;
const navigation_orchestrator = @import("../scripts/navigation_orchestrator.zig");
const WorkProgress = work_progress.WorkProgress;
const StoredItem = main.StoredItem;
const CarriedItem = main.CarriedItem;
const AssignedWorkstation = main.AssignedWorkstation;
const TransportTask = main.TransportTask;
const StoreTarget = main.StoreTarget;
const PickupSource = main.PickupSource;
const PendingArrival = main.PendingArrival;
const DanglingTarget = main.DanglingTarget;
const Position = engine.render.Position;
const Shape = engine.render.Shape;
const render = engine.render;
const BoundTypes = main.labelle_tasksBindItems;
const Workstation = BoundTypes.Workstation;
const Storage = BoundTypes.Storage;
const Items = items.Items;
const Context = main.labelle_tasksContext;

/// Game-specific task hooks for labelle-tasks integration.
/// These handlers respond to task engine events and integrate
/// with the game's visual/movement systems.
///
/// Payloads include:
/// - Original fields (worker_id, storage_id, item, etc.)
/// - .registry: ?*engine.Registry
/// - .game: ?*engine.Game
pub const GameHooks = struct {
    /// Handle worker being assigned to a workstation.
    /// Move the worker to the workstation position before starting work.
    pub fn worker_assigned(payload: anytype) void {
        log.info("worker_assigned: worker={d} workstation={d}", .{ payload.worker_id, payload.workstation_id });

        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Track workstation assignment
        registry.set(worker_entity, AssignedWorkstation{ .workstation_id = payload.workstation_id });

        // Get workstation position
        const ws_entity = engine.entityFromU64(payload.workstation_id);
        const ws_pos = registry.tryGet(Position, ws_entity) orelse {
            log.err("worker_assigned: workstation {d} has no Position", .{payload.workstation_id});
            return;
        };

        // Mark worker as pending arrival (don't start work until they arrive)
        registry.set(worker_entity, PendingArrival{});

        // Set NavigationIntent to route worker to workstation via pathfinder
        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.workstation_id,
            .action = .arrive_at_workstation,
            .target_x = ws_pos.x,
            .target_y = ws_pos.y,
        });

        log.info("worker_assigned: worker {d} moving to workstation {d} at ({d},{d})", .{
            payload.worker_id,
            payload.workstation_id,
            ws_pos.x,
            ws_pos.y,
        });
    }

    /// Handle worker being released from a workstation.
    pub fn worker_released(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const worker_entity = engine.entityFromU64(payload.worker_id);
        const ws_id: u64 = if (registry.tryGet(AssignedWorkstation, worker_entity)) |aw| aw.workstation_id else 0;
        log.info("worker_released: worker={d} workstation={d}", .{ payload.worker_id, ws_id });
        if (registry.tryGet(AssignedWorkstation, worker_entity) != null) {
            registry.remove(AssignedWorkstation, worker_entity);
        }

        // Try EOS→EIS transport before the task engine reassigns this worker.
        // Without this, the task engine immediately reassigns in tryAssignWorkers
        // and the EOS transport script's update() never gets a chance.
        const game: *engine.Game = @ptrCast(@alignCast(payload.game orelse return));
        const eos_transport = @import("../scripts/eos_transport.zig");
        if (eos_transport.tryAssignForWorker(payload.worker_id, game)) {
            log.info("worker_released: worker {d} assigned to EOS transport", .{payload.worker_id});
        }
    }

    /// Handle worker starting movement to workstation (initial assignment).
    /// Only handles workstation arrival - storage movements are handled by
    /// pickup_started and store_started hooks.
    pub fn movement_started(payload: anytype) void {
        std.debug.print("[HOOK] movement_started: worker={d} target={d}\n", .{ payload.worker_id, payload.target });
        const tasks = @import("labelle-tasks");
        log.info("movement_started: worker={d} target={d} type={s}", .{
            payload.worker_id,
            payload.target,
            @tagName(payload.target_type),
        });

        // Only handle workstation arrival
        if (payload.target_type != tasks.TargetType.workstation) return;

        const registry = payload.registry orelse return;

        const target_entity = engine.entityFromU64(payload.target);
        const target_pos = registry.tryGet(Position, target_entity) orelse return;

        const worker_entity = engine.entityFromU64(payload.worker_id);
        log.info("movement_started: setting NavigationIntent for worker to workstation {d} at ({d},{d})", .{
            payload.target,
            target_pos.x,
            target_pos.y,
        });
        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.target,
            .action = .arrive_at_workstation,
            .target_x = target_pos.x,
            .target_y = target_pos.y,
        });
    }

    /// Handle worker starting pickup from EIS.
    pub fn pickup_started(payload: anytype) void {
        log.info("pickup_started: worker={d} storage={d}", .{ payload.worker_id, payload.storage_id });
        const registry_ptr = payload.registry orelse {
            log.warn("pickup_started: registry is null", .{});
            return;
        };
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const storage_entity = engine.entityFromU64(payload.storage_id);
        log.info("pickup_started: converted entity ID {d} to entity", .{payload.storage_id});

        const storage_pos = registry.tryGet(Position, storage_entity) orelse {
            log.warn("pickup_started: storage entity {d} has no Position component", .{payload.storage_id});
            return;
        };

        log.info("pickup_started: storage {d} is at position ({d},{d})", .{
            payload.storage_id,
            storage_pos.x,
            storage_pos.y,
        });

        // Track which storage the worker is picking from (for visual item pickup)
        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, PickupSource{ .storage_id = payload.storage_id });
        log.info("pickup_started: tracking worker {d} picking from storage {d}", .{ payload.worker_id, payload.storage_id });

        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.storage_id,
            .action = .pickup,
            .target_x = storage_pos.x,
            .target_y = storage_pos.y,
        });

        log.info("pickup_started: set NavigationIntent for worker {d} to ({d},{d})", .{
            payload.worker_id,
            storage_pos.x,
            storage_pos.y,
        });
    }

    pub fn store_started(payload: anytype) void {
        log.info("store_started: worker={d} target_storage={d}", .{ payload.worker_id, payload.storage_id });

        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Check if target is an EIS (dangling item delivery) or EOS (post-process store)
        const target_entity = engine.entityFromU64(payload.storage_id);
        const target_storage = registry.tryGet(Storage, target_entity) orelse {
            log.err("store_started: target storage {d} not found", .{payload.storage_id});
            return;
        };

        if (target_storage.role == .eis) {
            // Dangling item delivery - move directly to EIS
            const eis_pos = registry.tryGet(Position, target_entity) orelse {
                log.err("store_started: EIS {d} has no Position", .{payload.storage_id});
                return;
            };

            log.info("store_started: worker {d} moving to EIS {d} at ({d},{d}) (dangling delivery)", .{
                payload.worker_id,
                payload.storage_id,
                eis_pos.x,
                eis_pos.y,
            });

            registry.set(worker_entity, NavigationIntent{
                .target_entity = payload.storage_id,
                .action = .store,
                .target_x = eis_pos.x,
                .target_y = eis_pos.y,
            });
            return;
        }

        // Post-process store flow: target is EOS, need to go via IOS
        // Save the target EOS for later (when worker arrives at IOS and needs to go to EOS)
        registry.set(worker_entity, StoreTarget{ .storage_id = payload.storage_id });

        // Find the workstation this worker is assigned to
        const assigned_ws = registry.tryGet(AssignedWorkstation, worker_entity) orelse {
            log.err("store_started: worker {d} has no assigned workstation", .{payload.worker_id});
            return;
        };

        // Find the IOS storage in the workstation
        const ws_entity = engine.entityFromU64(assigned_ws.workstation_id);
        const workstation = registry.tryGet(Workstation, ws_entity) orelse {
            log.err("store_started: workstation {d} not found", .{assigned_ws.workstation_id});
            return;
        };

        // Find IOS and move worker there first
        for (workstation.storages) |storage_entity| {
            const storage = registry.tryGet(Storage, storage_entity) orelse continue;
            if (storage.role == .ios) {
                const ios_pos = registry.tryGet(Position, storage_entity) orelse continue;
                log.info("store_started: worker {d} moving to IOS at ({d},{d})", .{
                    payload.worker_id,
                    ios_pos.x,
                    ios_pos.y,
                });

                // Move worker to IOS to pick up the bread
                registry.set(worker_entity, NavigationIntent{
                    .target_entity = engine.entityToU64(storage_entity),
                    .action = .pickup_from_ios,
                    .target_x = ios_pos.x,
                    .target_y = ios_pos.y,
                });
                return;
            }
        }

        log.err("store_started: no IOS found in workstation {d}", .{assigned_ws.workstation_id});
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        std.debug.print("[HOOK] pickup_dangling_started: worker={d} item={d}\n", .{ payload.worker_id, payload.item_id });
        log.info("pickup_dangling_started: worker={d} item={d}", .{ payload.worker_id, payload.item_id });

        const registry_ptr = payload.registry orelse {
            log.err("pickup_dangling_started: registry is null", .{});
            return;
        };
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const item_entity = engine.entityFromU64(payload.item_id);
        const item_pos = registry.tryGet(Position, item_entity) orelse {
            log.err("pickup_dangling_started: item {d} has no Position", .{payload.item_id});
            return;
        };

        // Get the item type from DanglingItem component
        const DanglingItem = BoundTypes.DanglingItem;
        const dangling_item = registry.tryGet(DanglingItem, item_entity) orelse {
            log.err("pickup_dangling_started: item {d} has no DanglingItem component", .{payload.item_id});
            // Still track the worker->item mapping even without item type info
            const worker_entity = engine.entityFromU64(payload.worker_id);
            registry.set(worker_entity, CarriedItem{ .item_entity = payload.item_id });
            // Set NavigationIntent anyway
            registry.set(worker_entity, NavigationIntent{
                .target_entity = payload.item_id,
                .action = .pickup_dangling,
                .target_x = item_pos.x,
                .target_y = item_pos.y,
            });
            return;
        };

        log.info("pickup_dangling_started: item type is {s}", .{@tagName(dangling_item.item_type)});

        // Track which item this worker will pick up
        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, CarriedItem{ .item_entity = payload.item_id });

        // Find the EIS that accepts this item type and track it
        var storage_view = registry.view(.{ Storage, Position });
        var storage_iter = storage_view.entityIterator();
        var found_eis = false;
        while (storage_iter.next()) |storage_entity| {
            const storage = storage_view.get(Storage, storage_entity);
            if (storage.role == .eis and storage.accepts == dangling_item.item_type) {
                const storage_id = engine.entityToU64(storage_entity);
                registry.set(item_entity, DanglingTarget{ .storage_id = storage_id });
                log.info("pickup_dangling_started: item {d} ({s}) -> EIS {d}", .{
                    payload.item_id,
                    @tagName(dangling_item.item_type),
                    storage_id,
                });
                found_eis = true;
                break;
            }
        }
        if (!found_eis) {
            log.err("pickup_dangling_started: no EIS found for item type {s}", .{@tagName(dangling_item.item_type)});
        }

        // Set NavigationIntent component on the worker
        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.item_id,
            .action = .pickup_dangling,
            .target_x = item_pos.x,
            .target_y = item_pos.y,
        });
    }

    /// Handle worker starting transport from EOS to destination (EIS or standalone).
    pub fn transport_started(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        // Track transport source and destination for worker_movement handlers
        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, TransportTask{
            .from_storage = payload.from_storage_id,
            .to_storage = payload.to_storage_id,
        });

        const from_entity = engine.entityFromU64(payload.from_storage_id);
        const from_pos = registry.tryGet(Position, from_entity) orelse return;

        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.from_storage_id,
            .action = .transport_pickup,
            .target_x = from_pos.x,
            .target_y = from_pos.y,
        });

        log.info("transport_started: worker={d} from={d} to={d} item={s}", .{
            payload.worker_id,
            payload.from_storage_id,
            payload.to_storage_id,
            @tagName(payload.item),
        });
    }

    /// Handle transport being rerouted to a new destination mid-flight.
    pub fn transport_rerouted(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        // Update destination tracking
        const worker_entity = engine.entityFromU64(payload.worker_id);
        if (registry.tryGet(TransportTask, worker_entity)) |task| {
            registry.set(worker_entity, TransportTask{
                .from_storage = task.from_storage,
                .to_storage = payload.to_storage_id,
            });
        }

        // Cancel any active navigation before rerouting
        navigation_orchestrator.cancelNavigation(registry, worker_entity, payload.worker_id);

        // Redirect worker to new destination
        const dest_entity = engine.entityFromU64(payload.to_storage_id);
        const dest_pos = registry.tryGet(Position, dest_entity) orelse return;

        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.to_storage_id,
            .action = .transport_deliver,
            .target_x = dest_pos.x,
            .target_y = dest_pos.y,
        });

        log.info("transport_rerouted: worker={d} new_dest={d} item={s}", .{
            payload.worker_id,
            payload.to_storage_id,
            @tagName(payload.item),
        });
    }

    /// Handle transport being cancelled.
    pub fn transport_cancelled(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        // Clean up tracking components (may already be cleaned up)
        const worker_entity = engine.entityFromU64(payload.worker_id);
        if (registry.tryGet(TransportTask, worker_entity) != null) {
            registry.remove(TransportTask, worker_entity);
        }
        if (registry.tryGet(CarriedItem, worker_entity) != null) {
            registry.remove(CarriedItem, worker_entity);
        }

        // Cancel any active navigation (removes NavigationIntent and MovementTarget)
        navigation_orchestrator.cancelNavigation(registry, worker_entity, payload.worker_id);

        log.info("transport_cancelled: worker={d} from={d} to={d}", .{
            payload.worker_id,
            payload.from_storage_id,
            payload.to_storage_id,
        });
    }

    var delivery_counter: u32 = 0;

    pub fn item_delivered(payload: anytype) void {
        log.warn("item_delivered: ENTERED worker={d} storage={d} item={d}", .{
            payload.worker_id, payload.storage_id, payload.item_id,
        });
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));
        const game_ptr = payload.game orelse return;
        const game: *engine.Game = @ptrCast(@alignCast(game_ptr));

        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        const item_entity = engine.entityFromU64(payload.item_id);

        // Remove DanglingItem component now that delivery is complete
        const DanglingItem = BoundTypes.DanglingItem;
        if (registry.tryGet(DanglingItem, item_entity) != null) {
            registry.remove(DanglingItem, item_entity);
        }

        // Detach item from worker (was attached during transport)
        game.hierarchy.removeParent(item_entity);

        // Clean up worker→item tracking (may already be cleaned up by worker_movement)
        const worker_entity = engine.entityFromU64(payload.worker_id);
        if (registry.tryGet(CarriedItem, worker_entity) != null) {
            registry.remove(CarriedItem, worker_entity);
        }

        // Track which item is at this storage (for later pickup by worker)
        std.debug.print("[DEBUG] item_delivered: about to put item {d} at storage {d}\n", .{ payload.item_id, payload.storage_id });
        registry.set(storage_entity, StoredItem{ .item_entity = payload.item_id });
        std.debug.print("[DEBUG] item_delivered: tracking item {d} at storage {d}\n", .{ payload.item_id, payload.storage_id });
        log.info("item_delivered: tracking item {d} at storage {d}", .{ payload.item_id, payload.storage_id });

        game.pos.setWorldPositionXY(item_entity, storage_pos.x, storage_pos.y);

        const storage_z: u8 = if (registry.tryGet(Shape, storage_entity)) |s| @intCast(@min(@max(s.z_index, 0), 254)) else 128;
        game.setZIndex(item_entity, storage_z +| 1);

        // Take screenshot on delivery
        delivery_counter += 1;
        var buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrintZ(&buf, "delivery-{d:0>4}.png", .{delivery_counter}) catch "delivery.png";
        game.takeScreenshot(filename);
        log.info("item_delivered: screenshot saved as {s}", .{filename});
    }

    /// Handle worker starting to process at a workstation.
    /// Always moves the worker to the workstation first; work starts
    /// when arrive_at_workstation fires in worker_movement.zig.
    pub fn process_started(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Already moving to workstation — nothing to do
        if (registry.tryGet(PendingArrival, worker_entity) != null) {
            log.info("process_started: worker={d} still moving to workstation, deferring", .{payload.worker_id});
            return;
        }

        const ws_entity = engine.entityFromU64(payload.workstation_id);
        const ws_pos = registry.tryGet(Position, ws_entity) orelse return;

        // Always move worker to workstation before starting work.
        // If already there, arrive_at_workstation fires on the next frame.
        registry.set(worker_entity, PendingArrival{});
        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.workstation_id,
            .action = .arrive_at_workstation,
            .target_x = ws_pos.x,
            .target_y = ws_pos.y,
        });
        log.info("process_started: worker={d} moving to workstation {d} at ({d},{d})", .{
            payload.worker_id, payload.workstation_id, ws_pos.x, ws_pos.y,
        });
    }

    /// Handle input item being consumed during processing.
    /// Called by the task engine when an IIS item is consumed.
    /// Remove the item's visual (Shape) so it disappears from screen.
    pub fn input_consumed(payload: anytype) void {
        const game_ptr = payload.game orelse return;
        const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const storage_id = payload.storage_id;
        const storage_entity = engine.entityFromU64(storage_id);

        // Look up the item entity at this storage and remove its visual
        if (registry.tryGet(StoredItem, storage_entity)) |stored| {
            const item_entity = engine.entityFromU64(stored.item_entity);
            // Remove Shape component - this properly untracks from render pipeline
            game.removeShape(item_entity);
            registry.remove(StoredItem, storage_entity);
            log.info("input_consumed: removed shape from item {d} at storage {d}", .{ stored.item_entity, storage_id });
        } else {
            log.warn("input_consumed: no item tracked at storage {d}", .{storage_id});
        }
    }

    /// Handle work completion at a workstation.
    /// Creates the output item entity at the IOS position.
    /// Must call Context.itemAdded to notify engine of output item type in IOS
    /// (needed for store_started to be dispatched).
    pub fn process_completed(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const ws_entity = engine.entityFromU64(payload.workstation_id);
        const workstation = registry.tryGet(Workstation, ws_entity) orelse {
            log.err("process_completed: workstation {d} has no Workstation component", .{payload.workstation_id});
            return;
        };

        // Find IOS storage and create output item entity there
        for (workstation.storages) |storage_entity| {
            const storage = registry.tryGet(Storage, storage_entity) orelse continue;
            if (storage.role == .ios) {
                const output_item = storage.accepts orelse continue;
                const storage_id = engine.entityToU64(storage_entity);
                const ios_pos = registry.tryGet(Position, storage_entity) orelse continue;

                // Create the output item entity (bread)
                // Use game.addShape() to properly track entity with render pipeline
                const game_ptr = payload.game orelse continue;
                const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
                const item_entity = game.createEntity();
                // Must add Position component BEFORE setWorldPositionXY (it requires existing Position)
                game.pos.addPosition(item_entity, .{ .x = ios_pos.x, .y = ios_pos.y });
                // Create bread shape (using prefab values as reference)
                // Note: Can't directly use prefab struct due to type coercion issues
                const bread_shape = Shape{
                    .shape = .{ .rectangle = .{ .width = 25, .height = 25 } },
                    .color = .{ .r = 210, .g = 160, .b = 90, .a = 255 }, // Golden brown
                    .z_index = 20,
                    .visible = true,
                };
                log.warn("process_completed: bread shape z_index={d}, color=({d},{d},{d},{d}), visible={}", .{
                    bread_shape.z_index,
                    bread_shape.color.r, bread_shape.color.g, bread_shape.color.b, bread_shape.color.a,
                    bread_shape.visible,
                });
                game.addShape(item_entity, bread_shape) catch |err| {
                    log.err("process_completed: failed to add shape: {}", .{err});
                    continue;
                };

                // Track the output item at IOS (ECS component)
                registry.set(storage_entity, StoredItem{ .item_entity = engine.entityToU64(item_entity) });

                // Notify task engine about the output item in IOS
                // This sets storage.item_type which is needed for store_started to be dispatched
                _ = Context.itemAdded(storage_id, output_item);

                log.info("process_completed: created {s} entity {d} at IOS {d}", .{
                    @tagName(output_item),
                    engine.entityToU64(item_entity),
                    storage_id,
                });
                break;
            }
        }

        log.info("process_completed: workstation={d} worker={d}", .{
            payload.workstation_id,
            payload.worker_id,
        });
    }
};
