// ============================================================================
// WASM Main - Bakery Game
// ============================================================================
// WebAssembly version using raylib + emscripten.
// Config is embedded at compile time (no runtime file I/O in WASM).
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const labelle_tasks = @import("labelle-tasks");
const items_enum = @import("../enums/items.zig");
pub const Items = items_enum.Items;
pub const GameId = u64;
pub const labelle_tasksBindItems = labelle_tasks.bind(Items);

const oven_prefab = @import("../prefabs/oven.zon");
const water_well_prefab = @import("../prefabs/water_well.zon");
const water_prefab = @import("../prefabs/water.zon");
const baker_prefab = @import("../prefabs/baker.zon");
const flour_prefab = @import("../prefabs/flour.zon");

const movement_target_comp = @import("../components/movement_target.zig");
const work_progress_comp = @import("../components/work_progress.zig");
pub const MovementTarget = movement_target_comp.MovementTarget;
pub const WorkProgress = work_progress_comp.WorkProgress;

const worker_movement_script = @import("../scripts/worker_movement.zig");
const storage_inspector_script = @import("../scripts/storage_inspector.zig");
const work_processor_script = @import("../scripts/work_processor.zig");
const camera_control_script = @import("../scripts/camera_control.zig");
const delivery_validator_script = @import("../scripts/delivery_validator.zig");

const task_hooks_hooks = @import("../hooks/task_hooks.zig");

const main_module = @This();

pub const Prefabs = engine.PrefabRegistry(.{
    .oven = oven_prefab,
    .water_well = water_well_prefab,
    .water = water_prefab,
    .baker = baker_prefab,
    .flour = flour_prefab,
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
});

const labelle_tasks_engine_hooks = labelle_tasks.createEngineHooks(GameId, Items, task_hooks_hooks.GameHooks);
pub const labelle_tasksContext = labelle_tasks_engine_hooks.Context;

const Hooks = engine.MergeEngineHooks(.{
    labelle_tasks_engine_hooks,
});
const Game = engine.GameWith(Hooks);

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("../scenes/main.zon");

// Compile-time embedded configuration (no file I/O in WASM)
const WINDOW_WIDTH = 1024;
const WINDOW_HEIGHT = 768;
const WINDOW_TITLE = "Bakery Game";
const TARGET_FPS = 60;
const CAMERA_X: f32 = -160;
const CAMERA_Y: f32 = -20;

pub fn main() !void {
    // Use page allocator for WASM compatibility
    const allocator = std.heap.page_allocator;

    var game = try Game.init(allocator, .{
        .window = .{
            .width = WINDOW_WIDTH,
            .height = WINDOW_HEIGHT,
            .title = WINDOW_TITLE,
            .target_fps = TARGET_FPS,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    defer game.deinit();

    // Apply camera configuration
    game.setCameraPosition(CAMERA_X, CAMERA_Y);

    const ctx = engine.SceneContext.init(&game);

    // Emit scene_before_load hook
    Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = allocator } });

    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();

    // Emit scene_load hook
    Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    defer {
        if (game.getCurrentSceneName() == null) {
            Game.HookDispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
        }
    }

    // Main loop - raylib handles browser integration via emscripten
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
