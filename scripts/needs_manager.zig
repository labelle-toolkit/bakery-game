// Needs manager script
//
// Per-scene setup for the labelle-needs engine: configures Sleep and Drink,
// registers workers and facilities, ticks every frame.
// Engine lifecycle (init/deinit) is handled by createEngineHooks.
// Hook handlers are in hooks/needs_hooks.zig.
//
// All game-side state is stored in ECS components (no HashMaps or arrays).

const std = @import("std");
const engine = @import("labelle-engine");
const labelle_needs = @import("labelle-needs");
const labelle_tasks = @import("labelle-tasks");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");
const work_progress = @import("../components/work_progress.zig");

const log = std.log.scoped(.needs_manager);

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Color = engine.Color;
const MovementTarget = movement_target.MovementTarget;
const navigation_intent_comp = @import("../components/navigation_intent.zig");
const NavigationIntent = navigation_intent_comp.NavigationIntent;
const WorkProgress = work_progress.WorkProgress;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const Storage = BoundTypes.Storage;
const Facility = labelle_needs.Facility;
const Locked = labelle_needs.Locked;
const NeedsContext = main.labelle_needsContext;
const TaskContext = main.labelle_tasksContext;
const Need = main.Needs;
const Items = main.Items;

// ECS components for game-side state
const StoredItem = main.StoredItem;
const StoreTarget = main.StoreTarget;
const DeferredSleep = main.DeferredSleep;
const DeferredDrink = main.DeferredDrink;

// --- Public configuration for scene switching ---

/// Set before loading a scene to override the initial sleep value for workers.
/// null = use default (1.0). Reset to null after use.
pub var override_initial_sleep: ?f32 = null;

// --- Public API for worker_movement.zig ---

pub fn getEngine() ?*NeedsContext.Engine {
    return NeedsContext.getEngine();
}

// --- findWaterSource callback for item-consuming Drink need ---

fn findWaterSource(worker_id: u64, need: Need, level: labelle_needs.NeedLevel) ?NeedsContext.Engine.FindItemSourceResult {
    _ = level;
    if (need != .Drink) return null;

    // Access registry via shared pointer
    const registry = labelle_needs.getSharedRegistry(engine.EngineTypes.Registry) orelse return null;

    // Get worker position for nearest-water selection
    const worker_entity = engine.entityFromU64(worker_id);
    const worker_pos = registry.tryGet(Position, worker_entity) orelse return null;

    // Count EOS Water supply vs EIS Water demand to determine surplus.
    // Only allow drinking from EOS if there's more Water in EOS than
    // empty EIS slots that need Water (so bread production isn't starved).
    var eos_water_available: u32 = 0;
    var eis_water_demand: u32 = 0;
    {
        var count_view = registry.view(.{ Storage, Position });
        var count_iter = count_view.entityIterator();
        while (count_iter.next()) |se| {
            const s = count_view.get(Storage, se);
            const accepts = s.accepts orelse continue;
            if (accepts != .Water) continue;
            if (s.role == .eos) {
                if (registry.tryGet(StoredItem, se) != null and
                    registry.tryGet(Locked, se) == null)
                {
                    eos_water_available += 1;
                }
            } else if (s.role == .eis) {
                if (registry.tryGet(StoredItem, se) == null) {
                    eis_water_demand += 1;
                }
            }
        }
    }
    const allow_eos_drinking = eos_water_available > eis_water_demand;

    // Scan Storage entities for the nearest available Water
    var storage_view = registry.view(.{ Storage, Position });
    var iter = storage_view.entityIterator();

    var best_storage_id: ?u64 = null;
    var best_dist: f32 = std.math.floatMax(f32);

    while (iter.next()) |storage_entity| {
        const storage = storage_view.get(Storage, storage_entity);

        // Only standalone or EOS storages (water well produces Water to EOS)
        if (storage.role == .standalone) {
            // Always allowed
        } else if (storage.role == .eos) {
            // Only if there's surplus beyond what EIS needs
            if (!allow_eos_drinking) continue;
        } else {
            continue;
        }

        // Must accept Water
        const accepts = storage.accepts orelse continue;
        if (accepts != .Water) continue;

        // Must actually have an item in it
        if (registry.tryGet(StoredItem, storage_entity) == null) continue;

        // Skip storages locked by another worker
        if (registry.tryGet(Locked, storage_entity) != null) continue;

        // Distance to worker
        const storage_id = engine.entityToU64(storage_entity);
        const spos = storage_view.get(Position, storage_entity);
        const dx = spos.x - worker_pos.x;
        const dy = spos.y - worker_pos.y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < best_dist) {
            best_dist = dist;
            best_storage_id = storage_id;
        }
    }

    if (best_storage_id) |sid| {
        return .{ .storage_id = sid, .item = .Water };
    }
    return null;
}

// --- Script lifecycle ---

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    const initial_sleep = override_initial_sleep orelse 1.0;
    override_initial_sleep = null;

    log.info("Initializing needs engine (Sleep+Drink, initial_sleep={d:.2})", .{initial_sleep});

    // Set context pointers for enriched payloads and distance function
    NeedsContext.setContext(@ptrCast(game), @ptrCast(game.getRegistry()));

    // Set item source finder for item-consuming needs
    NeedsContext.setFindItemSourceFn(findWaterSource);

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

    // Configure Drink need (item-consuming: requires Water from storage)
    NeedsContext.configureNeed(.{
        .need = .Drink,
        .decay_rate = 0.02,
        .yellow_threshold = 0.5,
        .red_threshold = 0.2,
        .facility_duration = 2.0,
        .facility_restore_value = 1.0,
        .in_place_duration = 3.0,
        .in_place_restore_value = 0.8,
        .initial_value = 1.0,
        .consumes_item = true,
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

    // Seed standalone Water storages with Water items for Drink need
    var seed_view = registry.view(.{ Storage, Position });
    var seed_iter = seed_view.entityIterator();
    var seeded_count: u32 = 0;
    while (seed_iter.next()) |storage_entity| {
        const storage = seed_view.get(Storage, storage_entity);
        if (storage.role != .standalone) continue;
        const accepts = storage.accepts orelse continue;
        if (accepts != .Water) continue;

        const storage_id = engine.entityToU64(storage_entity);
        const pos = seed_view.get(Position, storage_entity);

        // Create a Water item entity at the storage position
        const water_entity = registry.createEntity();
        registry.set(water_entity, Position{ .x = pos.x, .y = pos.y });
        registry.set(water_entity, engine.render.Shape{
            .shape = .{ .rectangle = .{ .width = 20, .height = 20 } },
            .color = .{ .r = 100, .g = 150, .b = 255, .a = 255 },
        });
        const water_id = engine.entityToU64(water_entity);
        registry.set(storage_entity, StoredItem{ .item_entity = water_id });
        log.info("Seeded Water item {d} at standalone storage {d} ({d:.0},{d:.0})", .{
            water_id, storage_id, pos.x, pos.y,
        });
        seeded_count += 1;
    }
    log.info("Seeded {d} standalone Water storages", .{seeded_count});

    // Register all Facility (Bed) entities
    var facility_view = registry.view(.{ Facility, Position });
    var facility_iter = facility_view.entityIterator();
    var facility_count: u32 = 0;
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
        log.info("Registered {s} facility at ({d:.0},{d:.0}) id={d} capacity={d}", .{
            @tagName(need), pos.x, pos.y, fac_id, facility.capacity,
        });
        facility_count += 1;
    }

    log.info("Needs engine initialized: {d} facilities, {d} workers", .{
        facility_count, worker_count,
    });
}

pub fn deinit() void {
    log.info("Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    // Ensure context pointers are set (may be cleared by scene transition)
    NeedsContext.setContext(@ptrCast(game), @ptrCast(game.getRegistry()));

    NeedsContext.tick(dt);

    const registry = game.getRegistry();

    // Check for deferred sleep: workers whose work just completed
    // Snapshot worker IDs to avoid iterator invalidation during component removal
    const MAX_DEFERRED = 16;
    var ds_ids: [MAX_DEFERRED]u64 = undefined;
    var ds_count: usize = 0;
    {
        var ds_view = registry.view(.{ Worker, DeferredSleep });
        var ds_iter = ds_view.entityIterator();
        while (ds_iter.next()) |we| {
            if (ds_count < MAX_DEFERRED) {
                ds_ids[ds_count] = engine.entityToU64(we);
                ds_count += 1;
            }
        }
    }
    for (ds_ids[0..ds_count]) |wid| {
        const worker_entity = engine.entityFromU64(wid);
        const deferred = registry.tryGet(DeferredSleep, worker_entity) orelse continue;
        const facility_id = deferred.facility_id;

        // Keep deferring while worker is working OR doing post-work IOS→EOS delivery
        if (registry.tryGet(WorkProgress, worker_entity) != null or
            registry.tryGet(StoreTarget, worker_entity) != null)
        {
            continue;
        }

        log.info("Deferred sleep resolved: worker {d} work done, now seeking bed {d}", .{ wid, facility_id });
        const bed_entity = engine.entityFromU64(facility_id);
        if (registry.tryGet(Position, bed_entity)) |bed_pos| {
            // Call workerUnavailable BEFORE setting MovementTarget, because
            // workerUnavailable may trigger transport_cancelled which removes MovementTarget
            _ = TaskContext.workerUnavailable(wid);
            registry.set(worker_entity, NavigationIntent{
                .target_entity = facility_id,
                .action = .seek_bed,
                .target_x = bed_pos.x,
                .target_y = bed_pos.y,
            });
        }

        registry.remove(DeferredSleep, worker_entity);
    }

    // Check for deferred drink: workers whose work just completed
    var dd_ids: [MAX_DEFERRED]u64 = undefined;
    var dd_count: usize = 0;
    {
        var dd_view = registry.view(.{ Worker, DeferredDrink });
        var dd_iter = dd_view.entityIterator();
        while (dd_iter.next()) |we| {
            if (dd_count < MAX_DEFERRED) {
                dd_ids[dd_count] = engine.entityToU64(we);
                dd_count += 1;
            }
        }
    }
    for (dd_ids[0..dd_count]) |wid| {
        const worker_entity = engine.entityFromU64(wid);
        const deferred = registry.tryGet(DeferredDrink, worker_entity) orelse continue;
        const storage_id = deferred.storage_id;

        // Keep deferring while worker is working OR doing post-work IOS→EOS delivery
        if (registry.tryGet(WorkProgress, worker_entity) != null or
            registry.tryGet(StoreTarget, worker_entity) != null)
        {
            continue;
        }

        log.info("Deferred drink resolved: worker {d} work done, now seeking water at storage {d}", .{ wid, storage_id });

        // Lock storage now (was deferred)
        const storage_entity = engine.entityFromU64(storage_id);
        registry.set(storage_entity, Locked{ .locked_by = wid });
        log.info("Deferred drink: locked storage {d} for worker {d}", .{ storage_id, wid });
        if (registry.tryGet(Position, storage_entity)) |storage_pos| {
            // Call workerUnavailable BEFORE setting MovementTarget, because
            // workerUnavailable may trigger transport_cancelled which removes MovementTarget
            _ = TaskContext.workerUnavailable(wid);
            registry.set(worker_entity, NavigationIntent{
                .target_entity = storage_id,
                .action = .seek_water,
                .target_x = storage_pos.x,
                .target_y = storage_pos.y,
            });
        }

        registry.remove(DeferredDrink, worker_entity);
    }

    // Draw need level bars above workers
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();

    const bar_width: f32 = 50;
    const bar_height: f32 = 8;
    const bar_gap: f32 = 2;
    const bar_offset_y: f32 = 28;

    while (worker_iter.next()) |entity| {
        const pos = worker_view.get(Position, entity);
        const worker_id = engine.entityToU64(entity);

        const bar_x = pos.x - bar_width / 2;

        // Drink bar (top, blue-themed)
        if (NeedsContext.getWorkerNeedValue(worker_id, .Drink)) |drink_val| {
            const drink_y = pos.y + bar_offset_y;
            game.gizmos.drawRect(bar_x, drink_y, bar_width, bar_height, Color{ .r = 30, .g = 30, .b = 60, .a = 220 });
            const fill_w = bar_width * drink_val;
            const color: Color = if (drink_val > 0.5)
                Color{ .r = 60, .g = 140, .b = 220, .a = 255 }
            else if (drink_val > 0.2)
                Color{ .r = 220, .g = 200, .b = 40, .a = 255 }
            else
                Color{ .r = 220, .g = 40, .b = 40, .a = 255 };
            if (fill_w > 0.5) {
                game.gizmos.drawRect(bar_x, drink_y, fill_w, bar_height, color);
            }
        }

        // Sleep bar (bottom, green-themed)
        if (NeedsContext.getWorkerNeedValue(worker_id, .Sleep)) |sleep_val| {
            const sleep_y = pos.y + bar_offset_y + bar_height + bar_gap;
            game.gizmos.drawRect(bar_x, sleep_y, bar_width, bar_height, Color{ .r = 50, .g = 50, .b = 50, .a = 220 });
            const fill_w = bar_width * sleep_val;
            const color: Color = if (sleep_val > 0.5)
                Color{ .r = 60, .g = 200, .b = 60, .a = 255 }
            else if (sleep_val > 0.2)
                Color{ .r = 220, .g = 200, .b = 40, .a = 255 }
            else
                Color{ .r = 220, .g = 40, .b = 40, .a = 255 };
            if (fill_w > 0.5) {
                game.gizmos.drawRect(bar_x, sleep_y, fill_w, bar_height, color);
            }
        }
    }
}
