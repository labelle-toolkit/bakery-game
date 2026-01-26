// EOS to EIS Transport Script
//
// Monitors EOS storages for items and assigns idle workers to transport
// them to matching EIS storages (same item type) when available.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const task_hooks = @import("../hooks/task_hooks.zig");

// Use direct logging for visibility
const log = std.log;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const MovementTarget = movement_target.MovementTarget;
const Action = movement_target.Action;
const BoundTypes = main.labelle_tasksBindItems;
const Storage = BoundTypes.Storage;
const Worker = BoundTypes.Worker;

/// Track pending transports: eos_id -> eis_id
pub var pending_transports: std.AutoHashMap(u64, u64) = undefined;
/// Track which EOS each worker is picking from: worker_id -> eos_id
pub var worker_transport_from: std.AutoHashMap(u64, u64) = undefined;
/// Track which EIS each worker is delivering to: worker_id -> eis_id
pub var worker_transport_to: std.AutoHashMap(u64, u64) = undefined;
var initialized: bool = false;

pub fn ensureInit() void {
    if (!initialized) {
        pending_transports = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_transport_from = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        worker_transport_to = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        initialized = true;
    }
}

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    ensureInit();
    log.info("[EosTransport] Script initialized", .{});
}

pub fn deinit() void {
    log.info("[EosTransport] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    ensureInit();
    task_hooks.ensureWorkerItemsInit();

    const registry = game.getRegistry();

    // Find idle workers (workers without MovementTarget and not assigned to a workstation)
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();

    while (worker_iter.next()) |worker_entity| {
        const worker_id = engine.entityToU64(worker_entity);

        // Skip if worker has a movement target (busy)
        if (registry.tryGet(MovementTarget, worker_entity) != null) continue;

        // Skip if worker is assigned to a workstation (task engine will handle)
        if (task_hooks.worker_workstation.get(worker_id) != null) continue;

        // Skip if worker is carrying an item
        if (task_hooks.worker_carried_items.get(worker_id) != null) continue;

        // This worker is idle - try to find a transport task
        if (tryAssignTransport(registry, worker_entity, worker_id)) {
            // Transport assigned, this worker is now busy
            continue;
        }
    }
}

/// Try to find an EOS with items that can be transported to a matching EIS
fn tryAssignTransport(registry: anytype, worker_entity: anytype, worker_id: u64) bool {
    // Get worker position for distance calculations
    const worker_pos = registry.tryGet(Position, worker_entity) orelse return false;

    // Find EOS storages with items
    var storage_view = registry.view(.{ Storage, Position });
    var eos_iter = storage_view.entityIterator();

    var best_eos_entity: ?@TypeOf(worker_entity) = null;
    var best_eos_id: u64 = 0;
    var best_eos_item_type: ?main.Items = null;
    var best_eos_pos: ?Position = null;
    var best_distance: f32 = std.math.floatMax(f32);

    while (eos_iter.next()) |eos_entity| {
        const storage = storage_view.get(Storage, eos_entity);

        // Only look at EOS storages
        if (storage.role != .eos) continue;

        const eos_id = engine.entityToU64(eos_entity);

        // Skip if no item in this EOS
        if (task_hooks.storage_items.get(eos_id) == null) continue;

        // Skip if transport already pending from this EOS
        if (pending_transports.get(eos_id) != null) continue;

        // Get the item type stored here
        const item_type = storage.accepts orelse continue;

        // Calculate distance to this EOS
        const eos_pos = storage_view.get(Position, eos_entity);
        const dx = eos_pos.x - worker_pos.x;
        const dy = eos_pos.y - worker_pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        // Check if there's a matching EIS that needs this item type
        if (findMatchingEIS(registry, item_type, eos_id)) |_| {
            // Found a valid transport target
            if (dist < best_distance) {
                best_distance = dist;
                best_eos_entity = eos_entity;
                best_eos_id = eos_id;
                best_eos_item_type = item_type;
                best_eos_pos = eos_pos.*;
            }
        }
    }

    // Assign transport if we found a valid EOS
    if (best_eos_entity) |_| {
        if (best_eos_item_type) |item_type| {
            if (findMatchingEIS(registry, item_type, best_eos_id)) |eis_id| {
                // Mark this transport as pending
                pending_transports.put(best_eos_id, eis_id) catch return false;

                // Track worker transport source and destination
                worker_transport_from.put(worker_id, best_eos_id) catch return false;
                worker_transport_to.put(worker_id, eis_id) catch return false;

                // Set worker movement target to EOS
                const pos = best_eos_pos.?;
                registry.set(worker_entity, MovementTarget{
                    .target_x = pos.x,
                    .target_y = pos.y,
                    .action = .transport_pickup,
                });

                log.info("[EosTransport] Assigned worker {d} to transport {s} from EOS {d} to EIS {d}", .{
                    worker_id,
                    @tagName(item_type),
                    best_eos_id,
                    eis_id,
                });

                return true;
            }
        }
    }

    return false;
}

/// Find an EIS that accepts the given item type and doesn't already have an item
fn findMatchingEIS(registry: anytype, item_type: main.Items, exclude_eos_id: u64) ?u64 {
    _ = exclude_eos_id;

    var storage_view = registry.view(.{ Storage, Position });
    var eis_iter = storage_view.entityIterator();

    while (eis_iter.next()) |eis_entity| {
        const storage = storage_view.get(Storage, eis_entity);

        // Only look at EIS storages
        if (storage.role != .eis) continue;

        // Check if this EIS accepts the item type
        const accepts = storage.accepts orelse continue;
        if (accepts != item_type) continue;

        const eis_id = engine.entityToU64(eis_entity);

        // Skip if EIS already has an item
        if (task_hooks.storage_items.get(eis_id) != null) continue;

        // Skip if there's already a pending transport to this EIS
        var pending_iter = pending_transports.valueIterator();
        var already_targeted = false;
        while (pending_iter.next()) |target_eis| {
            if (target_eis.* == eis_id) {
                already_targeted = true;
                break;
            }
        }
        if (already_targeted) continue;

        return eis_id;
    }

    return null;
}
