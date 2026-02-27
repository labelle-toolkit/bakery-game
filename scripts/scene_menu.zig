// Scene menu script
//
// Handles keyboard input and back button for scene selection.
// Press 1, 2 to load test scenes, 0 for full bakery, ESC to return to menu.
// On test scenes, a clickable "Back" button appears in the top-left.

const std = @import("std");
const engine = @import("labelle-engine");
const needs_manager = @import("needs_manager.zig");

const log = std.log.scoped(.scene_menu);
const Game = engine.Game;
const Scene = engine.Scene;
const gui = engine.gui;

var auto_switch: bool = true;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    log.info("Scene menu script initialized", .{});

    // Auto-switch to first test scene on startup
    if (auto_switch) {
        auto_switch = false;
        log.info("Auto-switching to: sleep_yellow_working", .{});
        needs_manager.override_initial_sleep = 0.70;
        game.queueSceneChange("sleep_yellow_working");
    }
}

pub fn deinit() void {
    log.info("Scene menu script deinitialized", .{});
}

fn isOnMenu(game: *Game) bool {
    const name = game.getCurrentSceneName() orelse return false;
    return std.mem.eql(u8, name, "menu");
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const input = game.getInput();
    const on_menu = isOnMenu(game);

    // Show scene selection buttons on menu
    if (on_menu) {
        if (game.gui.button(.{
            .text = "Yellow While Working",
            .position = .{ .x = 387, .y = 310 },
            .size = .{ .width = 250, .height = 35 },
        })) {
            log.info("Switching to: sleep_yellow_working", .{});
            needs_manager.override_initial_sleep = 0.70;
            game.queueSceneChange("sleep_yellow_working");
            return;
        }

        if (game.gui.button(.{
            .text = "Red No Beds",
            .position = .{ .x = 387, .y = 400 },
            .size = .{ .width = 250, .height = 35 },
        })) {
            log.info("Switching to: sleep_red_no_beds", .{});
            needs_manager.override_initial_sleep = 0.25;
            game.queueSceneChange("sleep_red_no_beds");
            return;
        }

        if (game.gui.button(.{
            .text = "Full Bakery",
            .position = .{ .x = 387, .y = 490 },
            .size = .{ .width = 250, .height = 35 },
        })) {
            log.info("Switching to: main (full bakery)", .{});
            needs_manager.override_initial_sleep = null;
            game.queueSceneChange("main");
            return;
        }
    }

    // Show back button on non-menu scenes
    if (!on_menu) {
        if (game.gui.button(.{
            .text = "Back",
            .position = .{ .x = 10, .y = 10 },
            .size = .{ .width = 80, .height = 30 },
        })) {
            log.info("Back button clicked, returning to menu", .{});
            needs_manager.override_initial_sleep = null;
            game.queueSceneChange("menu");
            return;
        }
    }

    // Press 1: Yellow While Working
    if (input.isKeyPressed(.one)) {
        log.info("Switching to: sleep_yellow_working", .{});
        needs_manager.override_initial_sleep = 0.70;
        game.queueSceneChange("sleep_yellow_working");
        return;
    }

    // Press 2: Red No Beds
    if (input.isKeyPressed(.two)) {
        log.info("Switching to: sleep_red_no_beds", .{});
        needs_manager.override_initial_sleep = 0.25;
        game.queueSceneChange("sleep_red_no_beds");
        return;
    }

    // Press 0: Full Bakery (original scene)
    if (input.isKeyPressed(.zero)) {
        log.info("Switching to: main (full bakery)", .{});
        needs_manager.override_initial_sleep = null;
        game.queueSceneChange("main");
        return;
    }

    // Press ESC: Return to menu
    if (input.isKeyPressed(.escape)) {
        log.info("Switching to: menu", .{});
        needs_manager.override_initial_sleep = null;
        game.queueSceneChange("menu");
        return;
    }
}
