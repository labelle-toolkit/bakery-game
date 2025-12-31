// Camera control script
// WASD to move the camera

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

const camera_speed: f32 = 200.0; // pixels per second

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    std.log.info("[CameraControl] WASD camera controls enabled", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    var dx: f32 = 0;
    var dy: f32 = 0;

    const input = game.getInput();

    // WASD movement
    if (input.isKeyDown(.w) or input.isKeyDown(.up)) dy -= 1;
    if (input.isKeyDown(.s) or input.isKeyDown(.down)) dy += 1;
    if (input.isKeyDown(.a) or input.isKeyDown(.left)) dx -= 1;
    if (input.isKeyDown(.d) or input.isKeyDown(.right)) dx += 1;

    if (dx != 0 or dy != 0) {
        const camera = game.getCamera();

        game.setCameraPosition(
            camera.x + dx * camera_speed * dt,
            camera.y + dy * camera_speed * dt,
        );
    }
}
