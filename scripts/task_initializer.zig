// Task initializer script
//
// Initializes the task engine with workers on scene load.
// Manages a queue of dangling items to ensure workers are assigned to both
// dangling pickups AND workstation tasks in parallel (the task engine
// prioritizes dangling items over workstations, so we limit how many are
// registered at once).

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.render.Position;
const Shape = engine.render.Shape;
const Context = main.labelle_tasksContext;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;
const DanglingItem = BoundTypes.DanglingItem;

/// Max concurrent dangling item pickups. Keep below worker count so
/// remaining workers can be assigned to workstations.
const max_concurrent_dangling: usize = 3;

/// Queue of flour entities waiting to be registered as dangling items.
var queued_entities: [16]Entity = undefined;
var queued_count: usize = 0;
var next_queue_idx: usize = 0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("[TaskInitializer] Initializing task engine with scene entities", .{});

    const registry = game.getRegistry();

    // Count workers
    var worker_view = registry.view(.{Worker});
    var worker_iter = worker_view.entityIterator();
    var worker_count: u32 = 0;
    while (worker_iter.next()) |_| {
        worker_count += 1;
    }
    std.log.info("[TaskInitializer] Found {d} workers (registered via onAdd callbacks)", .{worker_count});

    // Find flour entities without DanglingItem component (queued for later registration).
    // These are entities with the flour Shape (20x20 rectangle, color 255,255,200) but
    // no DanglingItem - they're visible on screen but not yet tracked by the task engine.
    queued_count = 0;
    var shape_view = registry.view(.{ Shape, Position });
    var shape_iter = shape_view.entityIterator();
    while (shape_iter.next()) |entity| {
        if (queued_count >= queued_entities.len) break;

        // Skip entities that already have DanglingItem (already registered)
        if (registry.tryGet(DanglingItem, entity) != null) continue;

        // Check if this looks like a flour entity (matching prefab shape)
        const shape = shape_view.get(Shape, entity);
        if (shape.color.r == 255 and shape.color.g == 255 and shape.color.b == 200) {
            switch (shape.shape) {
                .rectangle => |rect| {
                    if (rect.width == 20 and rect.height == 20) {
                        queued_entities[queued_count] = entity;
                        queued_count += 1;
                    }
                },
                else => {},
            }
        }
    }

    std.log.info("[TaskInitializer] Queued {d} flour entities for deferred dangling registration", .{queued_count});

    // Evaluate workstations and assign idle workers now that all entities are registered.
    // Without this, workers sit idle until some other event triggers tryAssignWorkers.
    if (Context.getEngine()) |task_eng| {
        task_eng.reevaluateWorkstations();
        std.log.info("[TaskInitializer] Evaluated workstations and assigned idle workers", .{});
    }
}

pub fn deinit() void {
    std.log.info("[TaskInitializer] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    if (next_queue_idx >= queued_count) return;

    const registry = game.getRegistry();

    // Count currently registered dangling items (DanglingItem is removed on pickup)
    var dangling_count: usize = 0;
    var di_view = registry.view(.{DanglingItem});
    var di_iter = di_view.entityIterator();
    while (di_iter.next()) |_| {
        dangling_count += 1;
    }

    // Only register more items when current count drops below the limit
    if (dangling_count < max_concurrent_dangling) {
        const entity = queued_entities[next_queue_idx];
        next_queue_idx += 1;

        // Adding DanglingItem triggers onAdd callback which registers with the task engine
        registry.set(entity, DanglingItem{ .item_type = .Flour });
        std.log.info("[TaskInitializer] Registered queued flour entity as dangling ({d} active, queue {d}/{d})", .{
            dangling_count + 1, next_queue_idx, queued_count,
        });
    }
}
