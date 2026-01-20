// ============================================================================
// WASM Main - Bakery Game
// ============================================================================
// WebAssembly version using raylib + emscripten.
// Uses emscripten_set_main_loop for proper browser integration.
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("labelle-engine");

// Detect if we're building for emscripten/WASM
const is_wasm = builtin.os.tag == .emscripten;

const labelle_tasks = @import("labelle-tasks");
const items_enum = @import("enums/items.zig");
pub const Items = items_enum.Items;
pub const GameId = u64;
pub const labelle_tasksBindItems = labelle_tasks.bind(Items, engine.Entity);

const oven_prefab = @import("prefabs/oven.zon");
const water_well_prefab = @import("prefabs/water_well.zon");
const water_prefab = @import("prefabs/water.zon");
const baker_prefab = @import("prefabs/baker.zon");
const flour_prefab = @import("prefabs/flour.zon");
const bread_prefab = @import("prefabs/bread.zon");

const movement_target_comp = @import("components/movement_target.zig");
const work_progress_comp = @import("components/work_progress.zig");
pub const MovementTarget = movement_target_comp.MovementTarget;
pub const WorkProgress = work_progress_comp.WorkProgress;

const worker_movement_script = @import("scripts/worker_movement.zig");
const storage_inspector_script = @import("scripts/storage_inspector.zig");
const work_processor_script = @import("scripts/work_processor.zig");
const camera_control_script = @import("scripts/camera_control.zig");
const delivery_validator_script = @import("scripts/delivery_validator.zig");
const task_initializer_script = @import("scripts/task_initializer.zig");

const task_hooks_hooks = @import("hooks/task_hooks.zig");

const main_module = @This();

pub const Prefabs = engine.PrefabRegistry(.{
    .oven = oven_prefab,
    .water_well = water_well_prefab,
    .water = water_prefab,
    .baker = baker_prefab,
    .flour = flour_prefab,
    .bread = bread_prefab,
});

pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
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
    pub const task_initializer = task_initializer_script;
});

const labelle_tasks_engine_hooks = labelle_tasks.createEngineHooks(GameId, Items, task_hooks_hooks.GameHooks);
pub const labelle_tasksContext = labelle_tasks_engine_hooks.Context;

const Hooks = engine.MergeEngineHooks(.{
    labelle_tasks_engine_hooks,
});
const Game = engine.GameWith(Hooks);

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/main.zon");

/// Instantiate bread prefab at the given position. Returns the entity.
pub fn instantiateBread(x: f32, y: f32) ?engine.Entity {
    const scene = global_scene orelse return null;
    const game = global_game orelse return null;
    const ctx = engine.SceneContext.init(game);
    return Loader.instantiatePrefab("bread", scene, ctx, x, y) catch |err| {
        std.log.err("Failed to instantiate bread prefab: {}", .{err});
        return null;
    };
}

// Get the scene type from Loader.load's return type using compile-time introspection
const SceneType = blk: {
    const load_fn_type = @TypeOf(Loader.load);
    const fn_info = @typeInfo(load_fn_type).@"fn";
    const return_type = fn_info.return_type.?;
    // It's an error union, get the payload type
    break :blk @typeInfo(return_type).error_union.payload;
};

// Compile-time embedded configuration
const WINDOW_WIDTH = 1024;
const WINDOW_HEIGHT = 768;
const WINDOW_TITLE = "Bakery Game";
const TARGET_FPS = 60;
// Camera starts at baker position (400, 300) - Y transformed: 768 - bakerY
const CAMERA_X: f32 = 400;
const CAMERA_Y: f32 = 768 - 300; // = 468

// Emscripten C interop (only for WASM)
const emscripten = if (is_wasm) struct {
    extern fn emscripten_set_main_loop(
        func: *const fn () callconv(.c) void,
        fps: c_int,
        simulate_infinite_loop: c_int,
    ) void;
} else struct {};

// Global state - must be heap-allocated to survive across emscripten callbacks
var global_game: ?*Game = null;
var global_scene: ?*SceneType = null;
var global_allocator: std.mem.Allocator = undefined;

// Frame callback for emscripten
fn frameCallback() callconv(.c) void {
    if (global_game) |game| {
        if (global_scene) |scene| {
            const dt = game.getDeltaTime();
            scene.update(dt);
            game.getPipeline().sync(game.getRegistry());

            const re = game.getRetainedEngine();
            re.beginFrame();
            re.render();
            re.endFrame();
        }
    }
}

pub fn main() !void {
    // Use C allocator for WASM (works with emscripten's malloc)
    // page_allocator can cause OutOfMemory issues in WASM
    global_allocator = if (is_wasm) std.heap.c_allocator else std.heap.page_allocator;

    if (is_wasm) {
        // WASM: Allocate game on heap so it survives after main() returns
        const game = try global_allocator.create(Game);
        game.* = try Game.init(global_allocator, .{
            .window = .{
                .width = WINDOW_WIDTH,
                .height = WINDOW_HEIGHT,
                .title = WINDOW_TITLE,
                .target_fps = TARGET_FPS,
            },
            .clear_color = .{ .r = 30, .g = 35, .b = 45 },
        });
        game.fixPointers();
        global_game = game;

        // Apply camera configuration
        game.setCameraPosition(CAMERA_X, CAMERA_Y);

        const ctx = engine.SceneContext.init(game);

        // Emit scene_before_load hook
        Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = global_allocator } });

        // Allocate scene on heap
        const scene = try global_allocator.create(SceneType);
        scene.* = try Loader.load(initial_scene, ctx);
        global_scene = scene;

        // Emit scene_load hook
        Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

        // Use emscripten's main loop - this never returns in WASM
        // fps=0 means use requestAnimationFrame, simulate_infinite_loop=1 prevents return
        emscripten.emscripten_set_main_loop(frameCallback, 0, 1);
    } else {
        // Native: Use stack allocation and traditional game loop
        var game = try Game.init(global_allocator, .{
            .window = .{
                .width = WINDOW_WIDTH,
                .height = WINDOW_HEIGHT,
                .title = WINDOW_TITLE,
                .target_fps = TARGET_FPS,
            },
            .clear_color = .{ .r = 30, .g = 35, .b = 45 },
        });
        defer game.deinit();
        game.fixPointers();

        // Apply camera configuration
        game.setCameraPosition(CAMERA_X, CAMERA_Y);

        const ctx = engine.SceneContext.init(&game);

        // Emit scene_before_load hook
        Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = global_allocator } });

        var scene = try Loader.load(initial_scene, ctx);
        defer scene.deinit();

        // Emit scene_load hook
        Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

        // Native: Use traditional game loop
        while (game.isRunning()) {
            const dt = game.getDeltaTime();
            scene.update(dt);
            game.getPipeline().sync(game.getRegistry());

            const re = game.getRetainedEngine();
            re.beginFrame();
            re.render();
            re.endFrame();
        }
    }
}
