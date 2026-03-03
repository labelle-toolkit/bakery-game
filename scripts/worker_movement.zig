// Worker movement script
//
// Handles worker movement towards targets.
// When idle (no MovementTarget), workers wander randomly.
// Adds TaskComplete marker when workers arrive at their destinations.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");
const movement_target = @import("../components/movement_target.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const MovementTarget = movement_target.MovementTarget;
const Worker = main.Worker;
const WorkingOn = main.WorkingOn;
const Delivering = main.Delivering;

var rng: std.Random.Xoshiro256 = undefined;
var rng_initialized: bool = false;
var wander_timer: f32 = 0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    rng = std.Random.Xoshiro256.init(42);
    rng_initialized = true;
    wander_timer = 0;
    std.log.info("[WorkerMovement] Script initialized", .{});
}

pub fn deinit() void {
    std.log.info("[WorkerMovement] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const registry = game.getRegistry();

    // Move entities that have a MovementTarget
    {
        // Collect arrived entities to avoid iterator invalidation on remove
        const Entity = engine.Entity;
        var arrived_buf: [32]Entity = undefined;
        var arrived_count: usize = 0;

        var view = registry.view(.{ MovementTarget, Position });
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const target = view.get(MovementTarget, entity);
            const pos = view.get(Position, entity);

            const dx = target.target_x - pos.x;
            const dy = target.target_y - pos.y;
            const dist = @sqrt(dx * dx + dy * dy);

            if (dist < 5.0) {
                // Mark as arrived — remove after iteration
                if (arrived_count < arrived_buf.len) {
                    arrived_buf[arrived_count] = entity;
                    arrived_count += 1;
                }
            } else {
                // Move towards target
                const move_dist = @min(target.speed * dt, dist);
                const move_x = (dx / dist) * move_dist;
                const move_y = (dy / dist) * move_dist;
                game.pos.moveLocalPosition(entity, move_x, move_y);
            }
        }

        // Remove MovementTarget from arrived entities
        for (arrived_buf[0..arrived_count]) |entity| {
            if (registry.tryGet(MovementTarget, entity)) |target| {
                std.log.info("[WorkerMovement] Entity {d} arrived (action={})", .{
                    engine.entityToU64(entity), target.action,
                });
                registry.remove(MovementTarget, entity);
            }
        }
    }

    // Wandering: assign random targets to idle workers
    wander_timer -= dt;
    if (wander_timer <= 0) {
        wander_timer = 1.5 + rng.random().float(f32) * 2.0; // 1.5-3.5s between wanders

        var worker_view = registry.view(.{ Worker, Position });
        var worker_iter = worker_view.entityIterator();

        while (worker_iter.next()) |entity| {
            // Only wander if idle (no MovementTarget, WorkingOn, or Delivering)
            if (registry.tryGet(MovementTarget, entity) != null) continue;
            if (registry.tryGet(WorkingOn, entity) != null) continue;
            if (registry.tryGet(Delivering, entity) != null) continue;

            const pos = worker_view.get(Position, entity);

            // Pick a random point within 150px of current position, clamped to scene bounds
            const rand = rng.random();
            const offset_x = (rand.float(f32) - 0.5) * 300.0;
            const offset_y = (rand.float(f32) - 0.5) * 300.0;
            const target_x = std.math.clamp(pos.x + offset_x, 50.0, 750.0);
            const target_y = std.math.clamp(pos.y + offset_y, 50.0, 700.0);

            registry.add(entity, MovementTarget{
                .target_x = target_x,
                .target_y = target_y,
                .speed = 80.0,
                .action = .pickup, // placeholder action for wandering
            });
        }
    }
}
