// Simple ball movement script for debugging
// Moves the first shape entity from left to right

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Shape = engine.Shape;
const Position = engine.render.Position;

const speed: f32 = 100.0; // pixels per second
const target_x: f32 = 500.0;

var ball_entity: ?engine.ecs.Entity = null;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    const registry = game.getRegistry();

    // Find the ball (leftmost shape - starts at x=100)
    var view = registry.view(.{ Shape, Position });
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const pos = view.getConst(Position, entity);
        // Ball starts at x=100, target is at x=500
        if (pos.x < 200) {
            ball_entity = entity;
            std.log.info("[BallMovement] Found ball at ({d:.1}, {d:.1})", .{ pos.x, pos.y });
            break;
        }
    }
    if (ball_entity == null) {
        std.log.err("[BallMovement] No ball entity found!", .{});
    }
}

var frame_count: u32 = 0;

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    frame_count += 1;

    const entity = ball_entity orelse return;

    const pos = game.getPosition(entity) orelse return;

    if (pos.x < target_x) {
        const move_amount = @min(speed * dt, target_x - pos.x);
        // Use game.movePosition to auto-sync to graphics
        game.movePosition(entity, move_amount, 0);

        // Log every 30 frames
        if (frame_count % 30 == 0) {
            std.log.info("[BallMovement] Ball at x={d:.1}", .{pos.x});
        }
    } else if (frame_count == 1 or (pos.x >= target_x and frame_count % 60 == 0)) {
        std.log.info("[BallMovement] Ball reached target at x={d:.1}", .{pos.x});
    }
}
