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
const BoundTypes = labelle_tasks.bind(items.Items);
const Workstation = BoundTypes.Workstation;
const Storage = BoundTypes.Storage;
const Items = items.Items;
const main = @import("../main.zig");
const Context = main.labelle_tasksContext;

/// Track which item entity each worker is carrying (worker_id -> item_id)
pub var worker_carried_items: std.AutoHashMap(u64, u64) = undefined;
/// Track which EIS each dangling item should be delivered to (item_id -> eis_id)
pub var dangling_item_targets: std.AutoHashMap(u64, u64) = undefined;
var worker_items_initialized: bool = false;

pub fn ensureWorkerItemsInit() void {
    if (!worker_items_initialized) {
        // Use c_allocator for WASM compatibility (page_allocator doesn't work in WASM)
        worker_carried_items = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        dangling_item_targets = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
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
        const Position = engine.render.Position;

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
        const Position = engine.render.Position;

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
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));
        const game_ptr = payload.game orelse return;
        const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
        const Position = engine.render.Position;

        const storage_entity = engine.entityFromU64(payload.storage_id);
        const storage_pos = registry.tryGet(Position, storage_entity) orelse return;

        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Attach carried item to worker (item follows worker during transport)
        ensureWorkerItemsInit();
        if (worker_carried_items.get(payload.worker_id)) |item_id| {
            const item_entity = engine.entityFromU64(item_id);
            game.setParent(item_entity, worker_entity) catch |err| {
                log.warn("store_started: failed to attach item to worker: {}", .{err});
            };
            // Position item at worker's location (offset slightly)
            game.setLocalPositionXY(item_entity, 0, 10);
            log.info("store_started: attached item {d} to worker {d}", .{ item_id, payload.worker_id });
        }

        // Set MovementTarget component on the worker
        registry.set(worker_entity, MovementTarget{
            .target_x = storage_pos.x,
            .target_y = storage_pos.y,
            .action = .store,
        });
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        std.debug.print("[HOOK] pickup_dangling_started: worker={d} item={d}\n", .{ payload.worker_id, payload.item_id });
        log.info("pickup_dangling_started: worker={d} item={d}", .{ payload.worker_id, payload.item_id });

        const registry_ptr = payload.registry orelse {
            log.err("pickup_dangling_started: registry is null", .{});
            return;
        };
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));
        const Position = engine.render.Position;

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
        const Position = engine.render.Position;

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
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));
        const game_ptr = payload.game orelse return;
        const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
        const Position = engine.render.Position;
        const Shape = engine.render.Shape;

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
            .duration = workstation.process_duration,
        });

        log.info("process_started: worker={d} workstation={d} duration={d}", .{
            payload.worker_id,
            payload.workstation_id,
            workstation.process_duration,
        });
    }

    /// Handle work completion at a workstation.
    /// For producer workstations (no IIS inputs), this creates the output item
    /// and notifies the engine so it can proceed with the store step.
    pub fn process_completed(payload: anytype) void {
        const registry_ptr = payload.registry orelse return;
        const registry: *engine.Registry = @ptrCast(@alignCast(registry_ptr));

        const ws_entity = engine.entityFromU64(payload.workstation_id);
        const workstation = registry.tryGet(Workstation, ws_entity) orelse {
            log.err("process_completed: workstation {d} has no Workstation component", .{payload.workstation_id});
            return;
        };

        // Find IOS storage and set output item based on what the IOS accepts
        for (workstation.storages) |storage_entity| {
            const storage = registry.tryGet(Storage, storage_entity) orelse continue;
            if (storage.role == .ios) {
                const output_item = storage.accepts orelse continue;
                const storage_id = engine.entityToU64(storage_entity);
                _ = Context.itemAdded(storage_id, output_item);
                log.info("process_completed: set IOS {d} item to {s}", .{ storage_id, @tagName(output_item) });
                break;
            }
        }

        log.info("process_completed: workstation={d} worker={d}", .{
            payload.workstation_id,
            payload.worker_id,
        });
    }
};
