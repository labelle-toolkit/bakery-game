// Worker movement script
//
// Handles worker movement towards targets (dangling items, storages).
// Consumes pending movements from task_state (queued by task engine hooks)
// and notifies task engine when workers arrive at their destinations.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("../components/task_state.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;

const MovementTarget = struct {
    target_x: f32,
    target_y: f32,
    speed: f32,
    action: task_state.MovementAction,
};

var active_movements: std.AutoHashMap(u64, MovementTarget) = undefined;
var initialized: bool = false;
var script_allocator: std.mem.Allocator = std.heap.page_allocator;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;

    active_movements = std.AutoHashMap(u64, MovementTarget).init(script_allocator);
    initialized = true;

    std.log.info("[WorkerMovement] Script initialized", .{});
}

pub fn deinit() void {
    if (initialized) {
        active_movements.deinit();
        initialized = false;
        std.log.info("[WorkerMovement] Script deinitialized", .{});
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized) return;

    const registry = game.getRegistry();

    // Process pending movements from task_state (queued by hooks)
    const pending = task_state.takePendingMovements();
    defer task_state.freePendingMovements(pending);

    for (pending) |movement| {
        active_movements.put(movement.worker_id, .{
            .target_x = movement.target_x,
            .target_y = movement.target_y,
            .speed = 60.0, // pixels per second
            .action = movement.action,
        }) catch |err| {
            std.log.err("[WorkerMovement] Failed to add movement: {}", .{err});
            continue;
        };

        std.log.info("[WorkerMovement] Started movement: worker={d}, target=({d:.1}, {d:.1}), action={}", .{
            movement.worker_id,
            movement.target_x,
            movement.target_y,
            movement.action,
        });
    }

    // Collect workers that have arrived (can't modify HashMap while iterating)
    var to_remove = std.ArrayListUnmanaged(u64){};
    defer to_remove.deinit(script_allocator);

    var iter = active_movements.iterator();
    while (iter.next()) |entry| {
        const worker_id = entry.key_ptr.*;
        const target = entry.value_ptr.*;

        const worker_entity = engine.entityFromU64(worker_id);
        const pos = registry.tryGet(Position, worker_entity) orelse {
            // Entity doesn't exist anymore, remove it
            to_remove.append(script_allocator, worker_id) catch continue;
            continue;
        };

        const dx = target.target_x - pos.x;
        const dy = target.target_y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist < 5.0) {
            // Arrived at target
            std.log.info("[WorkerMovement] Worker {d} arrived at target, action={}", .{ worker_id, target.action });

            switch (target.action) {
                .pickup, .pickup_dangling => _ = task_state.pickupCompleted(worker_id),
                .store => _ = task_state.storeCompleted(worker_id),
            }

            to_remove.append(script_allocator, worker_id) catch continue;
        } else {
            // Move towards target using game.movePosition (auto-syncs to graphics)
            const move_dist = @min(target.speed * dt, dist);
            const move_x = (dx / dist) * move_dist;
            const move_y = (dy / dist) * move_dist;
            game.movePosition(worker_entity, move_x, move_y);
        }
    }

    // Remove completed movements
    for (to_remove.items) |worker_id| {
        _ = active_movements.remove(worker_id);
    }
}
