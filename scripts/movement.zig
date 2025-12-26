// Movement script - camera controls and scene interaction
//
// Provides WASD camera movement for the bakery demo.

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

var initialized: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;

    std.log.info("[BAKERY] Movement script initialized", .{});
    std.log.info("[BAKERY] Workstation components loaded via prefabs", .{});

    initialized = true;
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    if (!initialized) return;

    // WASD camera control
    const input = game.getInput();
    const camera_speed: f32 = 200.0;
    const camera = game.getCamera();

    if (input.isKeyDown(.w)) camera.pan(0, -camera_speed * dt);
    if (input.isKeyDown(.s)) camera.pan(0, camera_speed * dt);
    if (input.isKeyDown(.a)) camera.pan(-camera_speed * dt, 0);
    if (input.isKeyDown(.d)) camera.pan(camera_speed * dt, 0);
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    initialized = false;
}
