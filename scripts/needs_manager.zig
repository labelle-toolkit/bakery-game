// Needs manager script
//
// Owns the labelle-needs engine instance, configures Sleep,
// registers workers and bed facilities, ticks every frame.
// Hooks bridge between the needs engine and the ECS/task engine.

const std = @import("std");
const engine = @import("labelle-engine");
const labelle_needs = @import("labelle-needs");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const bed_comp = @import("../components/bed.zig");
const work_progress = @import("../components/work_progress.zig");
const Facility = labelle_needs.Facility;

const log = std.log.scoped(.needs_manager);

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Color = engine.Color;
const MovementTarget = movement_target.MovementTarget;
const WorkProgress = work_progress.WorkProgress;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const Context = main.labelle_tasksContext;
const task_hooks = @import("../hooks/task_hooks.zig");

// --- Need types ---

const Need = enum { Sleep };
const Item = enum { Unused };

// --- Engine type ---

pub const NeedsEngine = labelle_needs.Engine(u64, Need, Item, NeedsHooks);

// --- Module-level globals (same pattern as task_hooks.zig) ---

var game_ref: ?*Game = null;
var needs_engine_ref: ?*NeedsEngine = null;

// --- Public configuration for scene switching ---

/// Set before loading a scene to override the initial sleep value for workers.
/// null = use default (1.0). Reset to null after use.
pub var override_initial_sleep: ?f32 = null;

// --- Deferred sleep state ---
// When a worker is actively working (has WorkProgress) and sleep hits Yellow,
// we defer the bed-seeking until work completes.

const MAX_WORKERS = 16;
var pending_sleep_workers: [MAX_WORKERS]u64 = undefined;
var pending_sleep_facilities: [MAX_WORKERS]u64 = undefined;
var pending_sleep_count: usize = 0;

fn storePendingSleep(worker_id: u64, facility_id: u64) void {
    // Check if already pending
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

fn removePendingSleep(worker_id: u64) void {
    for (0..pending_sleep_count) |i| {
        if (pending_sleep_workers[i] == worker_id) {
            // Swap-remove
            pending_sleep_count -= 1;
            if (i < pending_sleep_count) {
                pending_sleep_workers[i] = pending_sleep_workers[pending_sleep_count];
                pending_sleep_facilities[i] = pending_sleep_facilities[pending_sleep_count];
            }
            return;
        }
    }
}

fn clearPendingSleep() void {
    pending_sleep_count = 0;
}

// --- Distance function for facility selection ---

fn distanceFn(a: u64, b: u64) f32 {
    const game = game_ref orelse return std.math.inf(f32);
    const registry = game.getRegistry();

    const entity_a = engine.entityFromU64(a);
    const entity_b = engine.entityFromU64(b);

    const pos_a = registry.tryGet(Position, entity_a) orelse return std.math.inf(f32);
    const pos_b = registry.tryGet(Position, entity_b) orelse return std.math.inf(f32);

    const dx = pos_a.x - pos_b.x;
    const dy = pos_a.y - pos_b.y;
    return @sqrt(dx * dx + dy * dy);
}

// --- Helper: drop carried item at worker's current position ---

fn dropCarriedItem(worker_id: u64) void {
    const game = game_ref orelse return;
    const registry = game.getRegistry();
    const worker_entity = engine.entityFromU64(worker_id);

    task_hooks.ensureWorkerItemsInit();
    const item_id = task_hooks.worker_carried_items.get(worker_id) orelse return;
    const item_entity = engine.entityFromU64(item_id);

    // Get worker's current world position before detaching
    const worker_pos = registry.tryGet(Position, worker_entity) orelse return;
    const drop_x = worker_pos.x;
    const drop_y = worker_pos.y;

    // Detach item from worker
    game.hierarchy.removeParent(item_entity);

    // Place item at worker's world position
    game.pos.setWorldPositionXY(item_entity, drop_x, drop_y);

    // Clean up tracking
    _ = task_hooks.worker_carried_items.remove(worker_id);

    log.info("dropCarriedItem: worker {d} dropped item {d} at ({d:.0},{d:.0})", .{
        worker_id, item_id, drop_x, drop_y,
    });
}

// --- Hook implementations ---

const NeedsHooks = struct {
    pub fn seek_facility(payload: anytype) void {
        const game = game_ref orelse return;
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);

        // Check if worker is actively working (has WorkProgress component)
        if (registry.tryGet(WorkProgress, worker_entity) != null) {
            log.info("seek_facility: worker={d} is WORKING, deferring sleep (bed={d})", .{
                payload.worker_id,
                payload.facility_id,
            });
            // Defer: store pending sleep, don't set movement target yet
            storePendingSleep(payload.worker_id, payload.facility_id);
            // Still mark unavailable for NEW task assignment after current work
            // (workerUnavailable is called by worker_interrupted hook, not here)
            return;
        }

        log.info("seek_facility: worker={d} bed={d} need={s}", .{
            payload.worker_id,
            payload.facility_id,
            @tagName(payload.need),
        });

        // Drop any carried item at worker's current position
        dropCarriedItem(payload.worker_id);

        // Look up bed position
        const bed_entity = engine.entityFromU64(payload.facility_id);
        const bed_pos = registry.tryGet(Position, bed_entity) orelse {
            log.err("seek_facility: bed {d} has no Position", .{payload.facility_id});
            return;
        };

        // Set MovementTarget to move worker to bed
        registry.set(worker_entity, MovementTarget{
            .target_x = bed_pos.x,
            .target_y = bed_pos.y,
            .action = .seek_bed,
        });

        // Tell task engine worker is busy (prevent reassignment)
        _ = Context.workerUnavailable(payload.worker_id);
    }

    pub fn fulfill_in_place(payload: anytype) void {
        log.info("fulfill_in_place: worker={d} need={s} (no bed available)", .{
            payload.worker_id,
            @tagName(payload.need),
        });

        // Drop any carried item at worker's current position
        dropCarriedItem(payload.worker_id);

        // Remove any movement target so worker stays put
        const game = game_ref orelse return;
        const registry = game.getRegistry();
        const worker_entity = engine.entityFromU64(payload.worker_id);
        if (registry.tryGet(MovementTarget, worker_entity) != null) {
            registry.remove(MovementTarget, worker_entity);
        }

        // Worker sleeps in place; engine handles the timer internally
        _ = Context.workerUnavailable(payload.worker_id);
    }

    pub fn worker_interrupted(payload: anytype) void {
        log.info("worker_interrupted: worker={d} need={s}", .{
            payload.worker_id,
            @tagName(payload.need),
        });
        _ = Context.workerUnavailable(payload.worker_id);
    }

    pub fn worker_restored(payload: anytype) void {
        log.info("worker_restored: worker={d}", .{payload.worker_id});
        // Clear any stale pending sleep entry
        removePendingSleep(payload.worker_id);
        _ = Context.workerAvailable(payload.worker_id);
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

// --- Script lifecycle ---

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    game_ref = game;
    clearPendingSleep();

    // Use override if set, otherwise default to 1.0
    const initial_sleep = override_initial_sleep orelse 1.0;
    override_initial_sleep = null; // consume the override

    log.info("Initializing needs engine (Sleep only, initial_value={d:.2})", .{initial_sleep});

    // Create needs engine on heap (using c_allocator for WASM compat)
    const eng = std.heap.c_allocator.create(NeedsEngine) catch {
        log.err("Failed to allocate needs engine", .{});
        return;
    };
    eng.* = NeedsEngine.init(std.heap.c_allocator, .{}, .{
        .distance_fn = &distanceFn,
    });
    needs_engine_ref = eng;

    // Configure Sleep need
    eng.configureNeed(.{
        .need = .Sleep,
        .decay_rate = 0.015, // 1.5%/s → Yellow in ~33s, Red in ~53s
        .yellow_threshold = 0.5,
        .red_threshold = 0.2,
        .facility_duration = 3.0, // 3s at bed
        .facility_restore_value = 1.0,
        .in_place_duration = 5.0, // 5s in-place (penalty)
        .in_place_restore_value = 0.6,
        .initial_value = initial_sleep,
    });

    // Register all Worker entities
    const registry = game.getRegistry();
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();
    var worker_count: u32 = 0;
    while (worker_iter.next()) |entity| {
        const worker_id = engine.entityToU64(entity);
        eng.addWorker(worker_id) catch {
            log.err("Failed to register worker {d}", .{worker_id});
            continue;
        };
        worker_count += 1;
    }
    log.info("Registered {d} workers with needs engine", .{worker_count});

    // Scan for Facility component entities and register with the needs engine.
    // The Facility.need field is a u8 index into the Need enum.
    var facility_view = registry.view(.{ Facility, Position });
    var facility_iter = facility_view.entityIterator();
    var bed_count: u32 = 0;
    while (facility_iter.next()) |entity| {
        const facility = facility_view.get(Facility, entity);
        const fac_pos = facility_view.get(Position, entity);
        const fac_id = engine.entityToU64(entity);

        // Convert u8 index to Need enum
        const need = std.enums.values(Need)[facility.need];

        eng.addFacility(fac_id, .{
            .need = need,
            .capacity = facility.capacity,
            .max_uses = facility.max_uses,
        }) catch {
            log.err("Failed to register facility {d}", .{fac_id});
            continue;
        };
        log.info("Registered {s} facility at ({d:.0},{d:.0}) id={d} capacity={d}", .{
            @tagName(need), fac_pos.x, fac_pos.y, fac_id, facility.capacity,
        });
        bed_count += 1;
    }

    log.info("Needs engine initialized: {d} beds, {d} workers, Sleep configured (initial={d:.2})", .{ bed_count, worker_count, initial_sleep });
}

pub fn deinit() void {
    if (needs_engine_ref) |eng| {
        eng.deinit();
        std.heap.c_allocator.destroy(eng);
        needs_engine_ref = null;
    }
    game_ref = null;
    clearPendingSleep();
    log.info("Needs engine deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    game_ref = game;

    const eng = needs_engine_ref orelse return;
    eng.tick(dt);

    // Check for deferred sleep: workers whose work just completed
    if (pending_sleep_count > 0) {
        const registry = game.getRegistry();
        // Iterate pending list (copy count since we may modify during iteration)
        var i: usize = 0;
        while (i < pending_sleep_count) {
            const worker_id = pending_sleep_workers[i];
            const facility_id = pending_sleep_facilities[i];
            const worker_entity = engine.entityFromU64(worker_id);

            // Check if worker is still working
            if (registry.tryGet(WorkProgress, worker_entity) != null) {
                // Still working, keep waiting
                i += 1;
                continue;
            }

            // Work completed! Now send worker to bed
            log.info("Deferred sleep resolved: worker {d} work done, now seeking bed {d}", .{ worker_id, facility_id });

            const bed_entity = engine.entityFromU64(facility_id);
            if (registry.tryGet(Position, bed_entity)) |bed_pos| {
                registry.set(worker_entity, MovementTarget{
                    .target_x = bed_pos.x,
                    .target_y = bed_pos.y,
                    .action = .seek_bed,
                });
                _ = Context.workerUnavailable(worker_id);
            }

            // Remove from pending (swap-remove)
            pending_sleep_count -= 1;
            if (i < pending_sleep_count) {
                pending_sleep_workers[i] = pending_sleep_workers[pending_sleep_count];
                pending_sleep_facilities[i] = pending_sleep_facilities[pending_sleep_count];
            }
            // Don't increment i — the swapped element needs checking too
        }
    }

    // Draw sleep level bars above workers
    const registry = game.getRegistry();
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();

    const bar_width: f32 = 50;
    const bar_height: f32 = 12;
    const bar_offset_y: f32 = 30;

    while (worker_iter.next()) |entity| {
        const pos = worker_view.get(Position, entity);
        const worker_id = engine.entityToU64(entity);

        const sleep_val = eng.getWorkerNeedValue(worker_id, .Sleep) orelse continue;

        const bar_x = pos.x - bar_width / 2;
        const bar_y = pos.y + bar_offset_y;

        // Background (dark gray)
        game.gizmos.drawRect(bar_x, bar_y, bar_width, bar_height, Color{ .r = 50, .g = 50, .b = 50, .a = 220 });

        // Foreground: green → yellow → red based on value
        const fill_w = bar_width * sleep_val;
        const color: Color = if (sleep_val > 0.5)
            Color{ .r = 60, .g = 200, .b = 60, .a = 255 }
        else if (sleep_val > 0.2)
            Color{ .r = 220, .g = 200, .b = 40, .a = 255 }
        else
            Color{ .r = 220, .g = 40, .b = 40, .a = 255 };

        if (fill_w > 0.5) {
            game.gizmos.drawRect(bar_x, bar_y, fill_w, bar_height, color);
        }
    }
}

// --- Public API for worker_movement.zig ---

pub fn getEngine() ?*NeedsEngine {
    return needs_engine_ref;
}
