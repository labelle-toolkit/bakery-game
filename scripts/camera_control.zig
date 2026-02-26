// Camera control script
// WASD to move camera
// G to toggle gizmos
// F12 to take screenshot
// Tab to toggle camera follow mode

const std = @import("std");
const engine = @import("labelle-engine");
const Game = engine.Game;
const Scene = engine.Scene;

var screenshot_counter: u32 = 0;
var frame_count: u32 = 0;
var auto_screenshot_taken: bool = false;
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

    // Camera control with WASD / arrow keys (Y-up: W/Up = +Y)
    if (input.isKeyDown(.w) or input.isKeyDown(.up)) {
        camera_y += camera_speed * dt;
    }
    if (input.isKeyDown(.s) or input.isKeyDown(.down)) {
        camera_y -= camera_speed * dt;
    }
    if (input.isKeyDown(.a) or input.isKeyDown(.left)) {
        camera_x -= camera_speed * dt;
    }
    if (input.isKeyDown(.d) or input.isKeyDown(.right)) {
        camera_x += camera_speed * dt;
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
