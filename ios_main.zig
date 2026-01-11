// ============================================================================
// iOS Main Entry Point for Bakery Game
// ============================================================================
// This file provides the sokol_app callbacks for iOS:
// - init: Initialize graphics and game
// - frame: Update and render each frame
// - event: Handle touch and keyboard input
// - cleanup: Free resources on app termination
//
// Uses sokol backend with Metal rendering for iOS.
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("labelle-engine");
const ProjectConfig = engine.ProjectConfig;

// Sokol bindings - imported via labelle-engine/labelle-gfx
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

// iOS bundle path helper - changes working directory to bundle resources on iOS
fn setupBundlePath() void {
    if (builtin.os.tag != .ios) return;

    // On iOS, use CoreFoundation to get the bundle resources path
    const c = @cImport({
        @cInclude("CoreFoundation/CoreFoundation.h");
        @cInclude("unistd.h");
    });

    const bundle = c.CFBundleGetMainBundle();
    if (bundle == null) {
        std.debug.print("Warning: Could not get main bundle\n", .{});
        return;
    }

    const resources_url = c.CFBundleCopyResourcesDirectoryURL(bundle);
    if (resources_url == null) {
        std.debug.print("Warning: Could not get resources URL\n", .{});
        return;
    }
    defer c.CFRelease(resources_url);

    var path_buf: [1024:0]u8 = undefined;
    if (c.CFURLGetFileSystemRepresentation(resources_url, 1, &path_buf, path_buf.len) == 0) {
        std.debug.print("Warning: Could not get file system representation\n", .{});
        return;
    }

    std.debug.print("Bundle resources path: {s}\n", .{@as([*:0]u8, &path_buf)});

    // Change working directory to bundle resources
    if (c.chdir(&path_buf) != 0) {
        std.debug.print("Warning: Could not change to bundle directory\n", .{});
    } else {
        std.debug.print("Changed working directory to bundle resources\n", .{});
    }
}

// Plugin imports
const labelle_tasks = @import("labelle-tasks");

// Game-specific imports
const items_enum = @import("enums/items.zig");
pub const Items = items_enum.Items;
pub const GameId = u64;
pub const labelle_tasksBindItems = labelle_tasks.bind(Items);

// Prefab imports
const oven_prefab = @import("prefabs/oven.zon");
const water_well_prefab = @import("prefabs/water_well.zon");
const water_prefab = @import("prefabs/water.zon");
const baker_prefab = @import("prefabs/baker.zon");
const flour_prefab = @import("prefabs/flour.zon");

// Component imports
const movement_target_comp = @import("components/movement_target.zig");
const work_progress_comp = @import("components/work_progress.zig");
pub const MovementTarget = movement_target_comp.MovementTarget;
pub const WorkProgress = work_progress_comp.WorkProgress;

// Script imports
const worker_movement_script = @import("scripts/worker_movement.zig");
const storage_inspector_script = @import("scripts/storage_inspector.zig");
const work_processor_script = @import("scripts/work_processor.zig");
const camera_control_script = @import("scripts/camera_control.zig");
const delivery_validator_script = @import("scripts/delivery_validator.zig");

// Hook imports
const task_hooks_hooks = @import("hooks/task_hooks.zig");

const main_module = @This();

// Registries
pub const Prefabs = engine.PrefabRegistry(.{
    .oven = oven_prefab,
    .water_well = water_well_prefab,
    .water = water_prefab,
    .baker = baker_prefab,
    .flour = flour_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    // Engine built-in components
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    // Project components
    pub const MovementTarget = main_module.MovementTarget;
    pub const WorkProgress = main_module.WorkProgress;
    pub const Storage = labelle_tasksBindItems.Storage;
    pub const Worker = labelle_tasksBindItems.Worker;
    pub const DanglingItem = labelle_tasksBindItems.DanglingItem;
    pub const Workstation = labelle_tasksBindItems.Workstation;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const worker_movement = worker_movement_script;
    pub const storage_inspector = storage_inspector_script;
    pub const work_processor = work_processor_script;
    pub const camera_control = camera_control_script;
    pub const delivery_validator = delivery_validator_script;
});

// Engine hooks from labelle-tasks
const labelle_tasks_engine_hooks = labelle_tasks.createEngineHooks(GameId, Items, task_hooks_hooks.GameHooks);
pub const labelle_tasksContext = labelle_tasks_engine_hooks.Context;
const Hooks = engine.MergeEngineHooks(.{
    labelle_tasks_engine_hooks,
});
const Game = engine.GameWith(Hooks);

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/main.zon");

// ============================================================================
// Global State for Sokol Callback Pattern
// ============================================================================
// Sokol uses callbacks, so we need global state accessible from init/frame/cleanup

const State = struct {
    allocator: std.mem.Allocator = undefined,
    game: ?*Game = null,
    scene: ?*engine.Scene = null,
    project: ?ProjectConfig = null,
    title: ?[:0]u8 = null,
    initialized: bool = false,
    should_quit: bool = false,
    ci_test: bool = false,
    frame_count: u32 = 0,
};

var state: State = .{};

// Allocated storage for game and scene (needed because sokol callbacks can't return errors)
var game_storage: Game = undefined;
var scene_storage: engine.Scene = undefined;

// ============================================================================
// Sokol App Callbacks
// ============================================================================

export fn init() callconv(.c) void {
    state.ci_test = std.posix.getenv("CI_TEST") != null;

    // On iOS, change working directory to bundle resources
    // This must be done first so all relative paths work correctly
    setupBundlePath();

    // Initialize sokol_gfx with sokol_app's rendering context
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Initialize sokol_gl for 2D drawing (must be after sg.setup)
    sgl.setup(.{
        .logger = .{ .func = sokol.log.func },
    });

    // Use page allocator for simplicity in callback context
    state.allocator = std.heap.page_allocator;

    // Load project config
    // On iOS, try to load from bundle but fall back to defaults if not found
    // (iOS code signing has issues with resource files)
    const project_file = if (builtin.os.tag == .ios) "project.json" else "project.labelle";
    state.project = ProjectConfig.load(state.allocator, project_file) catch |err| blk: {
        if (builtin.os.tag == .ios) {
            // Use default config for iOS if file not found
            std.debug.print("Using default config for iOS (file load error: {})\n", .{err});
            break :blk ProjectConfig{
                .version = 1,
                .name = "bakery-game",
                .initial_scene = "main",
                .window = .{
                    .width = 1024,
                    .height = 768,
                    .title = "Bakery Game",
                    .target_fps = 60,
                },
                .camera = .{
                    .x = -160,
                    .y = -20,
                    .zoom = 1.0,
                },
                .resources = .{ .atlases = &.{} },
            };
        } else {
            std.debug.print("Failed to load project config: {}\n", .{err});
            sapp.quit();
            return;
        }
    };

    // Convert title to sentinel-terminated string
    state.title = state.allocator.dupeZ(u8, state.project.?.window.title) catch {
        std.debug.print("Failed to allocate title\n", .{});
        sapp.quit();
        return;
    };

    // Initialize game (sokol backend handles its own window via sokol_app)
    game_storage = Game.init(state.allocator, .{
        .window = .{
            .width = state.project.?.window.width,
            .height = state.project.?.window.height,
            .title = state.title.?,
            .target_fps = state.project.?.window.target_fps,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    }) catch |err| {
        std.debug.print("Failed to initialize game: {}\n", .{err});
        sapp.quit();
        return;
    };
    state.game = &game_storage;
    state.game.?.fixPointers();

    // Load atlases from project config
    if (state.project) |project| {
        for (project.resources.atlases) |atlas| {
            state.game.?.loadAtlas(atlas.name, atlas.json, atlas.texture) catch |err| {
                std.debug.print("Failed to load atlas {s}: {any}\n", .{ atlas.name, err });
            };
        }

        // Apply camera configuration from project
        if (project.camera.x != null or project.camera.y != null) {
            state.game.?.setCameraPosition(project.camera.x orelse 0, project.camera.y orelse 0);
        }
        if (project.camera.zoom != 1.0) {
            state.game.?.setCameraZoom(project.camera.zoom);
        }
    }

    const ctx = engine.SceneContext.init(state.game.?);

    // Emit scene_before_load hook for initial scene
    Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = state.allocator } });

    // Load initial scene
    scene_storage = Loader.load(initial_scene, ctx) catch |err| {
        std.debug.print("Failed to load scene: {}\n", .{err});
        sapp.quit();
        return;
    };
    state.scene = &scene_storage;

    // Emit scene_load hook for initial scene
    Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    state.initialized = true;
    std.debug.print("Bakery Game iOS initialized!\n", .{});
    std.debug.print("Window size: {}x{}\n", .{ sapp.width(), sapp.height() });
}

export fn frame() callconv(.c) void {
    if (!state.initialized or state.game == null or state.scene == null) return;

    // CI test mode: exit after 10 frames
    state.frame_count += 1;
    if (state.ci_test) {
        if (state.frame_count > 10) {
            state.should_quit = true;
            sapp.quit();
            return;
        }
    }

    // Begin input frame (clears per-frame pressed/released state)
    state.game.?.getInput().beginFrame();

    // Get delta time from sokol
    const dt: f32 = @floatCast(sapp.frameDuration());

    // Update scene (runs scripts, etc.)
    state.scene.?.update(dt);

    // Sync ECS components to graphics
    state.game.?.getPipeline().sync(state.game.?.getRegistry());

    // Begin sokol render pass (required for sokol backend)
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.118, .g = 0.137, .b = 0.176, .a = 1.0 },
    };
    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    });

    // Render using the retained engine
    const re = state.game.?.getRetainedEngine();
    re.beginFrame();
    re.render();
    re.endFrame();

    // End sokol render pass and commit
    sg.endPass();
    sg.commit();
}

export fn cleanup() callconv(.c) void {
    // Emit scene_unload hook if we still have the initial scene
    if (state.initialized and state.game != null) {
        if (state.game.?.getCurrentSceneName() == null) {
            Game.HookDispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
        }
    }

    // Cleanup scene
    if (state.scene) |scene| {
        scene.deinit();
        state.scene = null;
    }

    // Cleanup game
    if (state.game) |game| {
        game.deinit();
        state.game = null;
    }

    // Cleanup project config
    if (state.project) |project| {
        project.deinit(state.allocator);
        state.project = null;
    }

    // Free title
    if (state.title) |title| {
        state.allocator.free(title);
        state.title = null;
    }

    // Cleanup sokol in reverse order of initialization
    sgl.shutdown();
    sg.shutdown();

    std.debug.print("Bakery Game iOS cleanup complete.\n", .{});
}

export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;

    // Forward all input events to the engine's input system
    // This handles keyboard, mouse, and touch events via processEvent()
    if (state.game) |game| {
        game.getInput().processEvent(e);
    }

    // Handle app-specific events
    switch (e.type) {
        // Keyboard (for simulator testing)
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.quit();
            }
        },

        // Window resize (device rotation)
        .RESIZED => {
            std.debug.print("Screen resized to {}x{}\n", .{ sapp.width(), sapp.height() });
        },

        // App lifecycle
        .SUSPENDED => {
            std.debug.print("App suspended\n", .{});
            // TODO: Pause audio, save state
        },
        .RESUMED => {
            std.debug.print("App resumed\n", .{});
            // TODO: Resume audio
        },

        else => {},
    }
}

// ============================================================================
// Entry Point
// ============================================================================

/// C-callable entry point for iOS - called from main.m
/// This allows Xcode to compile Objective-C source code (satisfying code signing)
/// while still using the Zig engine.
export fn labelle_ios_main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Bakery Game",
        .high_dpi = true,
        .fullscreen = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}

comptime {
    // Only export main for non-iOS builds (avoids duplicate main symbol when linking with main.m)
    if (builtin.os.tag != .ios) {
        @export(&mainImpl, .{ .name = "main" });
    }
}

fn mainImpl() callconv(.c) c_int {
    labelle_ios_main();
    return 0;
}
