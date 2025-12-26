// Movement script - demonstrates comptime workstation integration
//
// This script shows how workstation components work with the ECS.
// The prefab loader creates workstation entities with their inline storages.

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

// Import game components
const storage = @import("../components/storage.zig");
const OvenWorkstation = storage.OvenWorkstation;
const TaskWorkstationBinding = storage.TaskWorkstationBinding;
const TaskStorage = storage.TaskStorage;

var initialized: bool = false;
var workstation_count: u32 = 0;
var storage_count: u32 = 0;

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
    workstation_count = 0;
    storage_count = 0;
}
