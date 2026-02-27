// Needs hooks for the bakery game
//
// Game-specific needs event handlers for labelle-needs.
// Engine hooks (game_init, scene_before_load, game_deinit) are automatically
// provided by createEngineHooks via project.labelle configuration.
//
// Hook payloads are enriched with .registry and .game pointers,
// so handlers can access the ECS directly.

const std = @import("std");
const log = std.log.scoped(.needs_hooks);
const engine = @import("labelle-engine");
const labelle_needs = @import("labelle-needs");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const task_hooks = @import("task_hooks.zig");
const main = @import("../main.zig");

const Locked = labelle_needs.Locked;

const MovementTarget = movement_target.MovementTarget;
const WorkProgress = work_progress.WorkProgress;
const Position = engine.render.Position;
const Game = engine.Game;
const TaskContext = main.labelle_tasksContext;

// --- Deferred sleep state ---
// When a worker is actively working (has WorkProgress) and sleep hits Yellow,
// we defer the bed-seeking until work completes.

const MAX_WORKERS = 16;
var pending_sleep_workers: [MAX_WORKERS]u64 = undefined;
var pending_sleep_facilities: [MAX_WORKERS]u64 = undefined;
var pending_sleep_count: usize = 0;

pub fn storePendingSleep(worker_id: u64, facility_id: u64) void {
    for (pending_sleep_workers[0..pending_sleep_count]) |id| {
        if (id == worker_id) return;
    }
    if (pending_sleep_count < MAX_WORKERS) {
        pending_sleep_workers[pending_sleep_count] = worker_id;
        pending_sleep_facilities[pending_sleep_count] = facility_id;
        pending_sleep_count += 1;
        log.info("Deferred sleep for worker {d} (working, will seek bed {d} after)", .{ worker_id, facility_id });
    }
}

pub fn removePendingSleep(worker_id: u64) void {
    for (0..pending_sleep_count) |i| {
        if (pending_sleep_workers[i] == worker_id) {
            pending_sleep_count -= 1;
            if (i < pending_sleep_count) {
                pending_sleep_workers[i] = pending_sleep_workers[pending_sleep_count];
                pending_sleep_facilities[i] = pending_sleep_facilities[pending_sleep_count];
            }
            return;
        }
    }
}

// --- Deferred drink state ---
// When a worker is actively working (has WorkProgress) and drink hits Yellow,
// we defer the item-seeking until work completes.

var pending_drink_workers: [MAX_WORKERS]u64 = undefined;
var pending_drink_storages: [MAX_WORKERS]u64 = undefined;
var pending_drink_count: usize = 0;

pub fn storePendingDrink(worker_id: u64, storage_id: u64) void {
    for (pending_drink_workers[0..pending_drink_count]) |id| {
        if (id == worker_id) return;
    }
    if (pending_drink_count < MAX_WORKERS) {
        pending_drink_workers[pending_drink_count] = worker_id;
        pending_drink_storages[pending_drink_count] = storage_id;
        pending_drink_count += 1;
        log.info("Deferred drink for worker {d} (working, will seek water {d} after)", .{ worker_id, storage_id });
    }
}

pub fn removePendingDrink(worker_id: u64) void {
    for (0..pending_drink_count) |i| {
        if (pending_drink_workers[i] == worker_id) {
            pending_drink_count -= 1;
            if (i < pending_drink_count) {
                pending_drink_workers[i] = pending_drink_workers[pending_drink_count];
                pending_drink_storages[i] = pending_drink_storages[pending_drink_count];
            }
            return;
        }
    }
}

pub fn getDrinkPendingCount() usize {
    return pending_drink_count;
}

pub fn getDrinkPendingWorker(i: usize) u64 {
    return pending_drink_workers[i];
}

pub fn getDrinkPendingStorage(i: usize) u64 {
    return pending_drink_storages[i];
}

pub fn removeDrinkPendingAtIndex(i: usize) void {
    pending_drink_count -= 1;
    if (i < pending_drink_count) {
        pending_drink_workers[i] = pending_drink_workers[pending_drink_count];
        pending_drink_storages[i] = pending_drink_storages[pending_drink_count];
    }
}

pub fn clearPendingSleep() void {
    pending_sleep_count = 0;
    pending_drink_count = 0;
}

pub fn getPendingCount() usize {
    return pending_sleep_count;
}

pub fn getPendingWorker(i: usize) u64 {
    return pending_sleep_workers[i];
}

pub fn getPendingFacility(i: usize) u64 {
    return pending_sleep_facilities[i];
}

pub fn removePendingAtIndex(i: usize) void {
    pending_sleep_count -= 1;
    if (i < pending_sleep_count) {
        pending_sleep_workers[i] = pending_sleep_workers[pending_sleep_count];
        pending_sleep_facilities[i] = pending_sleep_facilities[pending_sleep_count];
    }
}

// --- Helper: drop carried item at worker's current position ---

fn dropCarriedItem(worker_id: u64, game: *Game) void {
    const registry = game.getRegistry();
    const worker_entity = engine.entityFromU64(worker_id);

    task_hooks.ensureWorkerItemsInit();
    const item_id = task_hooks.worker_carried_items.get(worker_id) orelse return;
    const item_entity = engine.entityFromU64(item_id);

    const worker_pos = registry.tryGet(Position, worker_entity) orelse return;
    const drop_x = worker_pos.x;
    const drop_y = worker_pos.y;

    game.hierarchy.removeParent(item_entity);
    game.pos.setWorldPositionXY(item_entity, drop_x, drop_y);
    _ = task_hooks.worker_carried_items.remove(worker_id);

    log.info("dropCarriedItem: worker {d} dropped item {d} at ({d:.0},{d:.0})", .{
        worker_id, item_id, drop_x, drop_y,
    });
}

// --- Hook implementations ---

pub const NeedsGameHooks = struct {
    pub fn seek_facility(payload: anytype) void {
        const game: *Game = payload.game orelse return;
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Check if worker is actively working (has WorkProgress component)
        if (registry.tryGet(WorkProgress, worker_entity) != null) {
            log.info("seek_facility: worker={d} is WORKING, deferring sleep (bed={d})", .{
                payload.worker_id,
                payload.facility_id,
            });
            storePendingSleep(payload.worker_id, payload.facility_id);
            return;
        }

        log.info("seek_facility: worker={d} bed={d} need={s}", .{
            payload.worker_id,
            payload.facility_id,
            @tagName(payload.need),
        });

        dropCarriedItem(payload.worker_id, game);

        const bed_entity = engine.entityFromU64(payload.facility_id);
        const bed_pos = registry.tryGet(Position, bed_entity) orelse {
            log.err("seek_facility: bed {d} has no Position", .{payload.facility_id});
            return;
        };

        // Call workerUnavailable BEFORE setting MovementTarget, because
        // workerUnavailable may trigger transport_cancelled which removes MovementTarget
        _ = TaskContext.workerUnavailable(payload.worker_id);

        registry.set(worker_entity, MovementTarget{
            .target_x = bed_pos.x,
            .target_y = bed_pos.y,
            .action = .seek_bed,
        });
    }

    pub fn fulfill_in_place(payload: anytype) void {
        log.info("fulfill_in_place: worker={d} need={s} (no facility available)", .{
            payload.worker_id,
            @tagName(payload.need),
        });

        const game: *Game = payload.game orelse return;

        dropCarriedItem(payload.worker_id, game);

        // Note: we do NOT remove MovementTarget here because this hook may be
        // called during a MovementTarget view iteration (via seek_water → item_picked_up).
        // The caller (worker_movement.zig) handles removal after the engine call returns.

        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn worker_interrupted(payload: anytype) void {
        log.info("worker_interrupted: worker={d} need={s}", .{
            payload.worker_id,
            @tagName(payload.need),
        });
        // If worker has deferred sleep or drink (still working), don't release from
        // workstation yet — workerUnavailable will be called when the
        // deferred need resolves in needs_manager.update().
        for (pending_sleep_workers[0..pending_sleep_count]) |id| {
            if (id == payload.worker_id) {
                log.info("worker_interrupted: worker={d} has deferred sleep, skipping workerUnavailable", .{payload.worker_id});
                return;
            }
        }
        for (pending_drink_workers[0..pending_drink_count]) |id| {
            if (id == payload.worker_id) {
                log.info("worker_interrupted: worker={d} has deferred drink, skipping workerUnavailable", .{payload.worker_id});
                return;
            }
        }
        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn worker_restored(payload: anytype) void {
        log.info("worker_restored: worker={d}", .{payload.worker_id});
        removePendingSleep(payload.worker_id);
        removePendingDrink(payload.worker_id);
        _ = TaskContext.workerAvailable(payload.worker_id);
    }

    pub fn fulfillment_started(payload: anytype) void {
        log.info("fulfillment_started: worker={d} need={s} mode={s}", .{
            payload.worker_id,
            @tagName(payload.need),
            @tagName(payload.mode),
        });
    }

    pub fn fulfillment_completed(payload: anytype) void {
        log.info("fulfillment_completed: worker={d} need={s} mode={s}", .{
            payload.worker_id,
            @tagName(payload.need),
            @tagName(payload.mode),
        });
    }

    pub fn need_yellow(payload: anytype) void {
        log.info("need_yellow: worker={d} need={s} value={d:.2}", .{
            payload.worker_id,
            @tagName(payload.need),
            payload.value,
        });
    }

    pub fn need_red(payload: anytype) void {
        log.warn("need_red: worker={d} need={s} value={d:.2}", .{
            payload.worker_id,
            @tagName(payload.need),
            payload.value,
        });
    }

    pub fn seek_item(payload: anytype) void {
        log.info("seek_item: worker={d} storage={d} item={s} need={s}", .{
            payload.worker_id,
            payload.storage_id,
            @tagName(payload.item),
            @tagName(payload.need),
        });

        const game: *Game = payload.game orelse return;
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);
        const storage_entity = engine.entityFromU64(payload.storage_id);

        // Check if worker is actively working — defer drink until work completes
        if (registry.tryGet(WorkProgress, worker_entity) != null) {
            log.info("seek_item: worker={d} is WORKING, deferring drink (storage={d})", .{
                payload.worker_id,
                payload.storage_id,
            });
            storePendingDrink(payload.worker_id, payload.storage_id);
            return;
        }

        dropCarriedItem(payload.worker_id, game);

        // Lock storage so other systems (EOS transport, other workers) skip it
        registry.set(storage_entity, Locked{ .locked_by = payload.worker_id });
        log.info("seek_item: locked storage {d} for worker {d}", .{
            payload.storage_id, payload.worker_id,
        });

        const storage_pos = registry.tryGet(Position, storage_entity) orelse {
            log.err("seek_item: storage {d} has no Position", .{payload.storage_id});
            return;
        };

        // Call workerUnavailable BEFORE setting MovementTarget, because
        // workerUnavailable may trigger transport_cancelled which removes MovementTarget
        _ = TaskContext.workerUnavailable(payload.worker_id);

        registry.set(worker_entity, MovementTarget{
            .target_x = storage_pos.x,
            .target_y = storage_pos.y,
            .action = .seek_water,
        });
    }

    pub fn item_consumed(payload: anytype) void {
        log.info("item_consumed: worker={d} storage={d} item={s} need={s}", .{
            payload.worker_id,
            payload.storage_id,
            @tagName(payload.item),
            @tagName(payload.need),
        });

        const game: *Game = payload.game orelse return;
        const registry = game.getRegistry();
        const storage_entity = engine.entityFromU64(payload.storage_id);

        // Unlock storage
        registry.remove(Locked, storage_entity);
        log.info("item_consumed: unlocked storage {d}", .{payload.storage_id});

        // Notify task engine that this storage is now empty
        _ = TaskContext.itemRemoved(payload.storage_id);
        log.info("item_consumed: notified task engine storage {d} is empty", .{payload.storage_id});

        // Despawn the consumed item entity (still tracked in storage_items)
        task_hooks.ensureWorkerItemsInit();
        if (task_hooks.storage_items.get(payload.storage_id)) |item_entity_id| {
            const item_entity = engine.entityFromU64(item_entity_id);
            registry.destroyEntity(item_entity);
            log.info("item_consumed: despawned item entity {d}", .{item_entity_id});
        }
        _ = task_hooks.storage_items.remove(payload.storage_id);
    }

    pub fn need_unfulfillable(payload: anytype) void {
        log.warn("need_unfulfillable: worker={d} need={s} (no item available)", .{
            payload.worker_id,
            @tagName(payload.need),
        });
    }

    pub fn need_depleted(payload: anytype) void {
        log.err("need_depleted: worker={d} need={s}", .{
            payload.worker_id,
            @tagName(payload.need),
        });
    }
};
