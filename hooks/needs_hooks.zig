// Needs hooks for the bakery game
//
// Game-specific needs event handlers for labelle-needs.
// Engine hooks (game_init, scene_before_load, game_deinit) are automatically
// provided by createEngineHooks via project.labelle configuration.
//
// Hook payloads are enriched with .registry and .game pointers,
// so handlers can access the ECS directly.
//
// All game-side state is stored in ECS components (no HashMaps or arrays).

const std = @import("std");
const log = std.log.scoped(.needs_hooks);
const engine = @import("labelle-engine");
const labelle_needs = @import("labelle-needs");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const main = @import("../main.zig");

const Locked = labelle_needs.Locked;

const MovementTarget = movement_target.MovementTarget;
const navigation_intent_comp = @import("../components/navigation_intent.zig");
const NavigationIntent = navigation_intent_comp.NavigationIntent;
const WorkProgress = work_progress.WorkProgress;
const Position = engine.render.Position;
const Game = engine.Game;
const TaskContext = main.labelle_tasksContext;

// ECS components for game-side state
const CarriedItem = main.CarriedItem;
const StoredItem = main.StoredItem;
const DeferredSleep = main.DeferredSleep;
const DeferredDrink = main.DeferredDrink;

// --- Helper: drop carried item at worker's current position ---

fn dropCarriedItem(worker_id: u64, game: *Game) void {
    const registry = game.getRegistry();
    const worker_entity = engine.entityFromU64(worker_id);

    const carried = registry.tryGet(CarriedItem, worker_entity) orelse return;
    const item_id = carried.item_entity;
    const item_entity = engine.entityFromU64(item_id);

    const worker_pos = registry.tryGet(Position, worker_entity) orelse return;
    const drop_x = worker_pos.x;
    const drop_y = worker_pos.y;

    game.hierarchy.removeParent(item_entity);
    game.pos.setWorldPositionXY(item_entity, drop_x, drop_y);
    registry.remove(CarriedItem, worker_entity);

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
            registry.set(worker_entity, DeferredSleep{ .facility_id = payload.facility_id });
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

        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.facility_id,
            .action = .seek_bed,
            .target_x = bed_pos.x,
            .target_y = bed_pos.y,
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

        const game: *Game = payload.game orelse {
            _ = TaskContext.workerUnavailable(payload.worker_id);
            return;
        };
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);

        // If worker has deferred sleep or drink (still working), don't release from
        // workstation yet — workerUnavailable will be called when the
        // deferred need resolves in needs_manager.update().
        if (registry.tryGet(DeferredSleep, worker_entity) != null) {
            log.info("worker_interrupted: worker={d} has deferred sleep, skipping workerUnavailable", .{payload.worker_id});
            return;
        }
        if (registry.tryGet(DeferredDrink, worker_entity) != null) {
            log.info("worker_interrupted: worker={d} has deferred drink, skipping workerUnavailable", .{payload.worker_id});
            return;
        }
        _ = TaskContext.workerUnavailable(payload.worker_id);
    }

    pub fn worker_restored(payload: anytype) void {
        log.info("worker_restored: worker={d}", .{payload.worker_id});

        const game: *Game = payload.game orelse {
            _ = TaskContext.workerAvailable(payload.worker_id);
            return;
        };
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);

        if (registry.tryGet(DeferredSleep, worker_entity) != null) {
            registry.remove(DeferredSleep, worker_entity);
        }
        if (registry.tryGet(DeferredDrink, worker_entity) != null) {
            registry.remove(DeferredDrink, worker_entity);
        }
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
            registry.set(worker_entity, DeferredDrink{ .storage_id = payload.storage_id });
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

        registry.set(worker_entity, NavigationIntent{
            .target_entity = payload.storage_id,
            .action = .seek_water,
            .target_x = storage_pos.x,
            .target_y = storage_pos.y,
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

        // Unlock storage (may already be unlocked)
        if (registry.tryGet(Locked, storage_entity) != null) {
            registry.remove(Locked, storage_entity);
        }
        log.info("item_consumed: unlocked storage {d}", .{payload.storage_id});

        // Notify task engine that this storage is now empty
        _ = TaskContext.itemRemoved(payload.storage_id);
        log.info("item_consumed: notified task engine storage {d} is empty", .{payload.storage_id});

        // Despawn the consumed item entity
        if (registry.tryGet(StoredItem, storage_entity)) |stored| {
            const item_entity = engine.entityFromU64(stored.item_entity);
            registry.destroyEntity(item_entity);
            log.info("item_consumed: despawned item entity {d}", .{stored.item_entity});
            registry.remove(StoredItem, storage_entity);
        }
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
