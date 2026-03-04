// Work processor script
//
// Ticks WorkProgress timers on workers. When work completes,
// removes WorkProgress component. In the future, TaskCompletionSystem
// will handle the state transition.

const std = @import("std");
const engine = @import("labelle-engine");
const work_progress = @import("../components/work_progress.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const WorkProgress = work_progress.WorkProgress;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
}

pub fn deinit() void {}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const registry = game.getRegistry();
    var view = registry.view(.{WorkProgress});
    var iter = view.entityIterator();

    while (iter.next()) |worker_entity| {
        const progress = view.get(worker_entity);

        var updated_progress = progress.*;
        updated_progress.update(dt);

        if (updated_progress.isComplete()) {
            const worker_id = engine.entityToU64(worker_entity);
            std.log.info("[WorkProcessor] Worker {d} completed work at workstation {d}", .{
                worker_id,
                updated_progress.workstation_id,
            });
            registry.remove(WorkProgress, worker_entity);
        } else {
            registry.set(worker_entity, updated_progress);
        }
    }
}
