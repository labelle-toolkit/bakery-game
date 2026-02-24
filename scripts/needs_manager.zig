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
const Facility = labelle_needs.Facility;

const log = std.log.scoped(.needs_manager);

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Color = engine.Color;
const MovementTarget = movement_target.MovementTarget;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const Context = main.labelle_tasksContext;

// --- Need types ---

const Need = enum { Sleep };
const Item = enum { Unused };

// --- Engine type ---

pub const NeedsEngine = labelle_needs.Engine(u64, Need, Item, NeedsHooks);

// --- Module-level globals (same pattern as task_hooks.zig) ---

var game_ref: ?*Game = null;
var needs_engine_ref: ?*NeedsEngine = null;

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

// --- Hook implementations ---

const NeedsHooks = struct {
    pub fn seek_facility(payload: anytype) void {
        log.info("seek_facility: worker={d} bed={d} need={s}", .{
            payload.worker_id,
            payload.facility_id,
            @tagName(payload.need),
        });

        const game = game_ref orelse return;
        const registry = game.getRegistry();

        // Look up bed position
        const bed_entity = engine.entityFromU64(payload.facility_id);
        const bed_pos = registry.tryGet(Position, bed_entity) orelse {
            log.err("seek_facility: bed {d} has no Position", .{payload.facility_id});
            return;
        };

        // Set MovementTarget to move worker to bed
        const worker_entity = engine.entityFromU64(payload.worker_id);
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

    log.info("Initializing needs engine (Sleep only)", .{});

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
        .initial_value = 1.0,
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

    log.info("Needs engine initialized: {d} beds, {d} workers, Sleep configured", .{ bed_count, worker_count });
}

pub fn deinit() void {
    if (needs_engine_ref) |eng| {
        eng.deinit();
        std.heap.c_allocator.destroy(eng);
        needs_engine_ref = null;
    }
    game_ref = null;
    log.info("Needs engine deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    game_ref = game;

    const eng = needs_engine_ref orelse return;
    eng.tick(dt);

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
