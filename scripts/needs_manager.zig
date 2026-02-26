// Needs manager script
//
// Per-scene setup for the labelle-needs engine: configures Sleep,
// registers workers and bed facilities, ticks every frame.
// Engine lifecycle (init/deinit) is handled by createEngineHooks.
// Hook handlers are in hooks/needs_hooks.zig.

const std = @import("std");
const engine = @import("labelle-engine");
const labelle_needs = @import("labelle-needs");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");
const needs_hooks = @import("../hooks/needs_hooks.zig");

const log = std.log.scoped(.needs_manager);

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Color = engine.Color;
const MovementTarget = movement_target.MovementTarget;
const WorkProgress = work_progress.WorkProgress;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const Facility = labelle_needs.Facility;
const NeedsContext = main.labelle_needsContext;
const TaskContext = main.labelle_tasksContext;
const Need = main.Needs;

// --- Public configuration for scene switching ---

/// Set before loading a scene to override the initial sleep value for workers.
/// null = use default (1.0). Reset to null after use.
pub var override_initial_sleep: ?f32 = null;

// --- Public API for worker_movement.zig ---

pub fn getEngine() ?*NeedsContext.Engine {
    return NeedsContext.getEngine();
}

// --- Script lifecycle ---

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    needs_hooks.clearPendingSleep();

    const initial_sleep = override_initial_sleep orelse 1.0;
    override_initial_sleep = null;

    log.info("Initializing needs engine (Sleep only, initial_value={d:.2})", .{initial_sleep});

    // Set context pointers for enriched payloads and distance function
    NeedsContext.setContext(@ptrCast(game), @ptrCast(game.getRegistry()));

    // Configure Sleep need
    NeedsContext.configureNeed(.{
        .need = .Sleep,
        .decay_rate = 0.015,
        .yellow_threshold = 0.5,
        .red_threshold = 0.2,
        .facility_duration = 3.0,
        .facility_restore_value = 1.0,
        .in_place_duration = 5.0,
        .in_place_restore_value = 0.6,
        .initial_value = initial_sleep,
    });

    const registry = game.getRegistry();

    // Register all Worker entities
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();
    var worker_count: u32 = 0;
    while (worker_iter.next()) |entity| {
        const worker_id = engine.entityToU64(entity);
        NeedsContext.addWorker(worker_id) catch {
            log.err("Failed to register worker {d}", .{worker_id});
            continue;
        };
        worker_count += 1;
    }
    log.info("Registered {d} workers with needs engine", .{worker_count});

    // Register all Facility (Bed) entities
    var facility_view = registry.view(.{ Facility, Position });
    var facility_iter = facility_view.entityIterator();
    var bed_count: u32 = 0;
    while (facility_iter.next()) |entity| {
        const facility = facility_view.get(Facility, entity);
        const fac_id = engine.entityToU64(entity);
        const need = std.enums.values(Need)[facility.need];
        NeedsContext.addFacility(fac_id, .{
            .need = need,
            .capacity = facility.capacity,
            .max_uses = facility.max_uses,
        }) catch {
            log.err("Failed to register facility {d}", .{fac_id});
            continue;
        };
        const pos = facility_view.get(Position, entity);
        log.info("Registered Sleep facility at ({d:.0},{d:.0}) id={d} capacity={d}", .{
            pos.x, pos.y, fac_id, facility.capacity,
        });
        bed_count += 1;
    }

    log.info("Needs engine initialized: {d} beds, {d} workers, Sleep configured (initial={d:.2})", .{
        bed_count, worker_count, initial_sleep,
    });
}

pub fn deinit() void {
    needs_hooks.clearPendingSleep();
    log.info("Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    // Ensure context pointers are set (may be cleared by scene transition)
    NeedsContext.setContext(@ptrCast(game), @ptrCast(game.getRegistry()));

    NeedsContext.tick(dt);

    // Check for deferred sleep: workers whose work just completed
    const registry = game.getRegistry();
    var i: usize = 0;
    while (i < needs_hooks.getPendingCount()) {
        const worker_id = needs_hooks.getPendingWorker(i);
        const facility_id = needs_hooks.getPendingFacility(i);
        const worker_entity = engine.entityFromU64(worker_id);

        if (registry.tryGet(WorkProgress, worker_entity) != null) {
            i += 1;
            continue;
        }

        log.info("Deferred sleep resolved: worker {d} work done, now seeking bed {d}", .{ worker_id, facility_id });
        const bed_entity = engine.entityFromU64(facility_id);
        if (registry.tryGet(Position, bed_entity)) |bed_pos| {
            registry.set(worker_entity, MovementTarget{
                .target_x = bed_pos.x,
                .target_y = bed_pos.y,
                .action = .seek_bed,
            });
            _ = TaskContext.workerUnavailable(worker_id);
        }

        needs_hooks.removePendingAtIndex(i);
    }

    // Draw sleep level bars above workers
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();

    const bar_width: f32 = 50;
    const bar_height: f32 = 12;
    const bar_offset_y: f32 = 30;

    while (worker_iter.next()) |entity| {
        const pos = worker_view.get(Position, entity);
        const worker_id = engine.entityToU64(entity);

        const sleep_val = NeedsContext.getWorkerNeedValue(worker_id, .Sleep) orelse continue;

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
