// Camera control script
// WASD to move camera
// G to toggle gizmos
// F12 to take screenshot
// Tab to toggle camera follow mode

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Worker = main.labelle_tasksBindItems.Worker;

var screenshot_counter: u32 = 0;
var frame_count: u32 = 0;
var auto_screenshot_taken: bool = false;
var follow_baker: bool = true; // Start following baker (no keyboard on mobile)
var camera_x: f32 = 400.0;
var camera_y: f32 = 300.0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    std.log.info("[CameraControl] WASD to move camera, Tab to follow baker, G for gizmos, F12 for screenshot", .{});
    frame_count = 0;
    auto_screenshot_taken = false;
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const input = game.getInput();
    const camera_speed: f32 = 300.0; // pixels per second

    // Auto-screenshot after 120 frames (2 seconds) for gizmos demo
    frame_count += 1;
    if (!auto_screenshot_taken and frame_count == 120) {
        game.takeScreenshot("bakery-gizmos-demo.png");
        std.log.info("[CameraControl] Auto-screenshot saved: bakery-gizmos-demo.png", .{});
        auto_screenshot_taken = true;
    }

    // Tab - Toggle follow mode
    if (input.isKeyPressed(.tab)) {
        follow_baker = !follow_baker;
        std.log.info("[CameraControl] Camera mode: {s}", .{if (follow_baker) "following baker" else "manual control (WASD)"});
    }

    // Camera control
    if (follow_baker) {
        // Follow the baker (entity with Worker component)
        const registry = game.getRegistry();
        var view = registry.view(.{ Position, Worker });
        var iter = view.entityIterator();
        if (iter.next()) |entity| {
            const pos = view.get(Position, entity);
            // Set camera directly to baker position (camera target = center of view)
            camera_x = pos.x;
            camera_y = pos.y;
        }
    } else {
        // Manual camera control with WASD
        if (input.isKeyDown(.w)) {
            camera_y -= camera_speed * dt;
        }
        if (input.isKeyDown(.s)) {
            camera_y += camera_speed * dt;
        }
        if (input.isKeyDown(.a)) {
            camera_x -= camera_speed * dt;
        }
        if (input.isKeyDown(.d)) {
            camera_x += camera_speed * dt;
        }
    }

    // Apply camera position (transform Y: camera Y=0 is at screen bottom)
    game.setCameraPosition(camera_x, 768 - camera_y);

    // G - Toggle gizmos
    if (input.isKeyPressed(.g)) {
        const enabled = game.gizmos.areEnabled();
        game.gizmos.setEnabled(!enabled);
        std.log.info("[CameraControl] Gizmos {s}", .{if (!enabled) "enabled" else "disabled"});
    }

    // F12 - Take screenshot
    if (input.isKeyPressed(.f12)) {
        screenshot_counter += 1;
        var buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrintZ(&buf, "/tmp/bakery-screenshot-{d:0>4}.png", .{screenshot_counter}) catch "/tmp/bakery-screenshot.png";
        game.takeScreenshot(filename);
        std.log.info("[CameraControl] Screenshot saved: {s}", .{filename});
    }
}
