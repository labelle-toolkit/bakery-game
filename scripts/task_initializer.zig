// Task initializer script
//
// Initializes the task engine with workers on scene load.
// Notifies the engine about all idle workers so they can be assigned tasks.
// Dangling items are automatically registered via their DanglingItem component's
// onAdd callback, so no manual registration is needed.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Context = main.labelle_tasksContext;
const BoundTypes = main.labelle_tasksBindItems;
const Worker = BoundTypes.Worker;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("[TaskInitializer] Initializing task engine with scene entities", .{});

    const registry = game.getRegistry();

    // 1. Register and notify engine about all workers
    var worker_view = registry.view(.{Worker});
    var worker_iter = worker_view.entityIterator();

    var worker_count: u32 = 0;
    while (worker_iter.next()) |entity| {
        const worker_id = engine.entityToU64(entity);
        _ = Context.workerAvailable(worker_id);
        worker_count += 1;
        std.log.info("[TaskInitializer] Registered worker {d} with task engine", .{worker_id});
    }

    std.log.info("[TaskInitializer] Initialized {d} workers for task engine", .{worker_count});

    // Note: Dangling items are automatically registered with the task engine via
    // DanglingItem component's onAdd callback. When workerAvailable() is called above,
    // the task engine's evaluateDanglingItems() will assign idle workers to pick up
    // any registered dangling items. No manual assignment is needed here.
}

pub fn deinit() void {
    std.log.info("[TaskInitializer] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
