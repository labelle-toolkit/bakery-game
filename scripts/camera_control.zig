// Camera control script
// WASD to move the camera
// G to toggle gizmos
// F12 to take screenshot

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

const camera_speed: f32 = 200.0; // pixels per second
var screenshot_counter: u32 = 0;
var frame_count: u32 = 0;
var auto_screenshot_taken: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    // Center camera on the bakery scene
    // Scene spans roughly x: 100-750, y: 150-650
    // Screen is 1024x768, so center at (400, 400) with offset for screen center
    game.setCameraPosition(400 - 512, 350 - 384);
    std.log.info("[CameraControl] WASD camera controls, G to toggle gizmos, F12 for screenshot", .{});
    frame_count = 0;
    auto_screenshot_taken = false;
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    // Auto-screenshot after 60 frames (1 second) for gizmos demo
    frame_count += 1;
    if (!auto_screenshot_taken and frame_count == 60) {
        game.takeScreenshot("/tmp/bakery-gizmos-demo.png");
        std.log.info("[CameraControl] Auto-screenshot saved: /tmp/bakery-gizmos-demo.png", .{});
        auto_screenshot_taken = true;
    }

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

    // G - Toggle gizmos
    if (input.isKeyPressed(.g)) {
        const enabled = game.areGizmosEnabled();
        game.setGizmosEnabled(!enabled);
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
