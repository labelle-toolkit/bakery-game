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
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const task_hooks = @import("task_hooks.zig");
const main = @import("../main.zig");

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

pub fn clearPendingSleep() void {
    pending_sleep_count = 0;
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

        registry.set(worker_entity, MovementTarget{
            .target_x = bed_pos.x,
            .target_y = bed_pos.y,
            .action = .seek_bed,
        });

        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn fulfill_in_place(payload: anytype) void {
        log.info("fulfill_in_place: worker={d} need={s} (no bed available)", .{
            payload.worker_id,
            @tagName(payload.need),
        });

        const game: *Game = payload.game orelse return;
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);

        dropCarriedItem(payload.worker_id, game);

        if (registry.tryGet(MovementTarget, worker_entity) != null) {
            registry.remove(MovementTarget, worker_entity);
        }

        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn worker_interrupted(payload: anytype) void {
        log.info("worker_interrupted: worker={d} need={s}", .{
            payload.worker_id,
            @tagName(payload.need),
        });
        // If worker has deferred sleep (still working), don't release from
        // workstation yet — workerUnavailable will be called when the
        // deferred sleep resolves in needs_manager.update().
        for (pending_sleep_workers[0..pending_sleep_count]) |id| {
            if (id == payload.worker_id) {
                log.info("worker_interrupted: worker={d} has deferred sleep, skipping workerUnavailable", .{payload.worker_id});
                return;
            }
        }
        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn worker_restored(payload: anytype) void {
        log.info("worker_restored: worker={d}", .{payload.worker_id});
        removePendingSleep(payload.worker_id);
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

    pub fn need_depleted(payload: anytype) void {
        log.err("need_depleted: worker={d} need={s}", .{
            payload.worker_id,
            @tagName(payload.need),
        });
    }
};
