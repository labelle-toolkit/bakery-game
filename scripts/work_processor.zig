// Work processor script
//
// Ticks work progress for workers at workstations and
// calls workCompleted when processing is done.

const std = @import("std");
const log = std.log.scoped(.work_processor);
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const work_progress = @import("../components/work_progress.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const WorkProgress = work_progress.WorkProgress;
const Context = main.labelle_tasksContext;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    log.info("Work processor initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const registry = game.getRegistry();

    // Find all workers with WorkProgress component
    var view = registry.view(.{WorkProgress});
    var iter = view.entityIterator();

    while (iter.next()) |worker_entity| {
        const progress = view.get(worker_entity);
        const worker_id = engine.entityToU64(worker_entity);

        // Tick the progress
        progress.tick();

        // Check if work is complete
        if (progress.isComplete()) {
            log.info("Work complete: worker={d} workstation={d}", .{
                worker_id,
                progress.workstation_id,
            });

            // Notify task engine that work is complete
            _ = Context.workCompleted(progress.workstation_id);

            // Remove the WorkProgress component
            registry.remove(WorkProgress, worker_entity);
        }
    }
}

pub fn deinit() void {
    log.info("Work processor deinitialized", .{});
}
