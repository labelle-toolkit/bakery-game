// Task hooks for the bakery game
//
// Game-specific task event handlers for labelle-tasks.
// Engine hooks (game_init, scene_load, game_deinit) are automatically
// provided by createEngineHooks via project.labelle configuration.
//
// Hook payloads are enriched with .registry and .game pointers,
// so handlers can access the ECS directly.

const std = @import("std");
const log = std.log.scoped(.task_hooks);
const engine = @import("labelle-engine");
const labelle_tasks = @import("labelle-tasks");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const items = @import("../enums/items.zig");

const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const WorkProgress = work_progress.WorkProgress;
const Position = engine.render.Position;
const Shape = engine.render.Shape;
const render = engine.render;
const BoundTypes = labelle_tasks.bind(items.Items, engine.Entity);
const Workstation = BoundTypes.Workstation;
const Storage = BoundTypes.Storage;
const Items = items.Items;
const main = @import("../main.zig");
const Context = main.labelle_tasksContext;

/// Track which item entity each worker is carrying (worker_id -> item_id)
pub var worker_carried_items: std.AutoHashMap(u64, u64) = undefined;
/// Track which EIS each dangling item should be delivered to (item_id -> eis_id)
pub var dangling_item_targets: std.AutoHashMap(u64, u64) = undefined;
/// Track which item entity is at each storage (storage_id -> item_id)
pub var storage_items: std.AutoHashMap(u64, u64) = undefined;
/// Track which storage the worker is currently picking from (worker_id -> storage_id)
pub var worker_pickup_storage: std.AutoHashMap(u64, u64) = undefined;
/// Track which workstation each worker is assigned to (worker_id -> workstation_id)
pub var worker_workstation: std.AutoHashMap(u64, u64) = undefined;
/// Track target EOS for store step (worker_id -> eos_id)
pub var worker_store_target: std.AutoHashMap(u64, u64) = undefined;
var worker_items_initialized: bool = false;

pub fn ensureWorkerItemsInit() void {
    if (!worker_items_initialized) {
        // Use c_allocator for WASM compatibility (page_allocator doesn't work in WASM)
        worker_carried_items = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        dangling_item_targets = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        storage_items = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_pickup_storage = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_workstation = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_store_target = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_items_initialized = true;
    }
}

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
    /// Track the assignment so we can find IIS storages during pickup.
    pub fn worker_assigned(payload: anytype) void {
        log.info("worker_assigned: worker={d} workstation={d}", .{ payload.worker_id, payload.workstation_id });
        ensureWorkerItemsInit();
        worker_workstation.put(payload.worker_id, payload.workstation_id) catch {};
    }

    /// Handle worker being released from a workstation.
    pub fn worker_released(payload: anytype) void {
        log.info("worker_released: worker={d} workstation={d}", .{ payload.worker_id, payload.workstation_id });
        ensureWorkerItemsInit();
        _ = worker_workstation.remove(payload.worker_id);
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
        log.info("movement_started: setting MovementTarget for worker to workstation {d} at ({d},{d})", .{
            payload.target,
            target_pos.x,
            target_pos.y,
        });
        registry.set(worker_entity, MovementTarget{
            .target_x = target_pos.x,
            .target_y = target_pos.y,
            .action = .arrive_at_workstation,
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
        ensureWorkerItemsInit();
        worker_pickup_storage.put(payload.worker_id, payload.storage_id) catch {};
        log.info("pickup_started: tracking worker {d} picking from storage {d}", .{ payload.worker_id, payload.storage_id });

        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, MovementTarget{
            .target_x = storage_pos.x,
            .target_y = storage_pos.y,
            .action = .pickup,
        });

        log.info("pickup_started: set MovementTarget for worker {d} to ({d},{d})", .{
            payload.worker_id,
            storage_pos.x,
            storage_pos.y,
        });
    }

    pub fn store_started(payload: anytype) void {
        log.info("store_started: worker={d} target_eos={d}", .{ payload.worker_id, payload.storage_id });

        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Save the target EOS for later (when worker arrives at IOS and needs to go to EOS)
        ensureWorkerItemsInit();
        worker_store_target.put(payload.worker_id, payload.storage_id) catch {};

        // Find the workstation this worker is assigned to
        const workstation_id = worker_workstation.get(payload.worker_id) orelse {
            log.err("store_started: worker {d} has no assigned workstation", .{payload.worker_id});
            return;
        };

        // Find the IOS storage in the workstation
        const ws_entity = engine.entityFromU64(workstation_id);
        const workstation = registry.tryGet(Workstation, ws_entity) orelse {
            log.err("store_started: workstation {d} not found", .{workstation_id});
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
                registry.set(worker_entity, MovementTarget{
                    .target_x = ios_pos.x,
                    .target_y = ios_pos.y,
                    .action = .pickup_from_ios,
                });
                return;
            }
        }

        log.err("store_started: no IOS found in workstation {d}", .{workstation_id});
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
            ensureWorkerItemsInit();
            worker_carried_items.put(payload.worker_id, payload.item_id) catch {};
            // Set MovementTarget anyway
            const worker_entity = engine.entityFromU64(payload.worker_id);
            registry.set(worker_entity, MovementTarget{
                .target_x = item_pos.x,
                .target_y = item_pos.y,
                .action = .pickup_dangling,
            });
            return;
        };

        log.info("pickup_dangling_started: item type is {s}", .{@tagName(dangling_item.item_type)});

        // Track which item this worker will pick up
        ensureWorkerItemsInit();
        worker_carried_items.put(payload.worker_id, payload.item_id) catch {};

        // Find the EIS that accepts this item type and track it
        var storage_view = registry.view(.{ Storage, Position });
        var storage_iter = storage_view.entityIterator();
        var found_eis = false;
        while (storage_iter.next()) |storage_entity| {
            const storage = storage_view.get(Storage, storage_entity);
            if (storage.role == .eis and storage.accepts == dangling_item.item_type) {
                const storage_id = engine.entityToU64(storage_entity);
                dangling_item_targets.put(payload.item_id, storage_id) catch {};
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

        // Set MovementTarget component on the worker
        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, MovementTarget{
            .target_x = item_pos.x,
            .target_y = item_pos.y,
            .action = .pickup_dangling,
        });
    }

    /// Handle worker starting transport from EOS to EIS.
    pub fn transport_started(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const from_entity = engine.entityFromU64(payload.from_storage_id);
        const from_pos = registry.tryGet(Position, from_entity) orelse return;

        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, MovementTarget{
            .target_x = from_pos.x,
            .target_y = from_pos.y,
            .action = .transport_pickup,
        });

        log.info("transport_started: worker={d} from={d} to={d} item={s}", .{
            payload.worker_id,
            payload.from_storage_id,
            payload.to_storage_id,
            @tagName(payload.item),
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
        game.removeParent(item_entity);

        // Clean up worker→item tracking
        ensureWorkerItemsInit();
        _ = worker_carried_items.remove(payload.worker_id);

        // Track which item is at this storage (for later pickup by worker)
        std.debug.print("[DEBUG] item_delivered: about to put item {d} at storage {d}\n", .{ payload.item_id, payload.storage_id });
        storage_items.put(payload.storage_id, payload.item_id) catch |err| {
            std.debug.print("[DEBUG] item_delivered: storage_items.put failed: {}\n", .{err});
        };
        std.debug.print("[DEBUG] item_delivered: tracking item {d} at storage {d}\n", .{ payload.item_id, payload.storage_id });
        log.info("item_delivered: tracking item {d} at storage {d}", .{ payload.item_id, payload.storage_id });

        game.setWorldPositionXY(item_entity, storage_pos.x, storage_pos.y);

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
    /// Sets up WorkProgress component to track work time.
    pub fn process_started(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const ws_entity = engine.entityFromU64(payload.workstation_id);
        const workstation = registry.tryGet(Workstation, ws_entity) orelse {
            log.err("process_started: workstation {d} has no Workstation component", .{payload.workstation_id});
            return;
        };

        const worker_entity = engine.entityFromU64(payload.worker_id);
        registry.set(worker_entity, WorkProgress{
            .workstation_id = payload.workstation_id,
            .duration = @floatFromInt(workstation.process_duration),
        });

        log.info("process_started: worker={d} workstation={d} duration={d}s", .{
            payload.worker_id,
            payload.workstation_id,
            workstation.process_duration,
        });
    }

    /// Handle input item being consumed during processing.
    /// Called by the task engine when an IIS item is consumed.
    /// Hide the item entity (don't destroy, as it may be scene-managed).
    pub fn input_consumed(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));
        const game_ptr = payload.game orelse return;
        const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
        _ = game;

        const storage_id = payload.storage_id;

        // Look up the item entity at this storage and hide it
        // (don't destroy, as scene-managed entities would cause crash on scene deinit)
        ensureWorkerItemsInit();
        if (storage_items.get(storage_id)) |item_id| {
            const item_entity = engine.entityFromU64(item_id);
            // Hide the item by setting its Shape to invisible
            if (registry.tryGet(Shape, item_entity)) |shape| {
                var new_shape = shape.*;
                new_shape.visible = false;
                registry.set(item_entity, new_shape);
            }
            _ = storage_items.remove(storage_id);
            log.info("input_consumed: hid item {d} from storage {d}", .{ item_id, storage_id });
        } else {
            log.warn("input_consumed: no item tracked at storage {d}", .{storage_id});
        }
    }

    /// Handle work completion at a workstation.
    /// Creates the output item entity at the IOS position.
    /// Note: Don't call Context.itemAdded - the engine already knows about the output.
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
                // Use registry.add() to trigger onAdd callback which tracks entity with render pipeline
                const game_ptr = payload.game orelse continue;
                const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
                const item_entity = game.createEntity();
                game.setWorldPositionXY(item_entity, ios_pos.x, ios_pos.y);
                registry.add(item_entity, Shape{
                    .shape = .{ .rectangle = .{ .width = 25, .height = 25 } },
                    .color = .{ .r = 210, .g = 160, .b = 90, .a = 255 }, // Bread color (golden brown)
                    .z_index = 20,
                    .visible = true,
                });
                // Mark as dangling item so it can be picked up for store step
                registry.add(item_entity, main.labelle_tasksBindItems.DanglingItem{
                    .item_type = output_item,
                });

                // Track the output item at IOS
                ensureWorkerItemsInit();
                storage_items.put(storage_id, engine.entityToU64(item_entity)) catch {};

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
