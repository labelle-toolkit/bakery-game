// Camera control script
// Camera follows the baker
// G to toggle gizmos
// F12 to take screenshot

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


pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;
    std.log.info("[CameraControl] Camera follows baker, G to toggle gizmos, F12 for screenshot", .{});
    frame_count = 0;
    auto_screenshot_taken = false;
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    // Auto-screenshot after 120 frames (2 seconds) for gizmos demo
    frame_count += 1;
    if (!auto_screenshot_taken and frame_count == 120) {
        game.takeScreenshot("bakery-gizmos-demo.png");
        std.log.info("[CameraControl] Auto-screenshot saved: bakery-gizmos-demo.png", .{});
        auto_screenshot_taken = true;
    }

    // Follow the baker (entity with Worker component)
    const registry = game.getRegistry();
    var view = registry.view(.{ Position, Worker });
    var iter = view.entityIterator();
    if (iter.next()) |entity| {
        const pos = view.get(Position, entity);
        // Debug: log position occasionally
        if (frame_count % 60 == 0) {
            std.log.info("[CameraControl] Baker at ({d:.1}, {d:.1})", .{ pos.x, pos.y });
        }
        // Center camera on baker position (negate y for new engine coordinate system)
        game.setCameraPosition(pos.x, -pos.y);
    } else {
        if (frame_count % 60 == 0) {
            std.log.warn("[CameraControl] No baker entity found!", .{});
        }
    }

    const input = game.getInput();

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
