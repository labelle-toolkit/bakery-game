// Movement script - uses labelle-tasks with EIS/IIS/IOS/EOS storages
//
// The task engine automatically manages the baking workflow:
// - EIS (Pantry): External Input Storage - holds raw ingredients
// - IIS (Oven Input): Internal Input Storage - recipe requirements
// - IOS (Oven Output): Internal Output Storage - produced items
// - EOS (Shelf): External Output Storage - finished products
//
// Hooks in hooks/task_hooks.zig fire on each step and move the baker.

const std = @import("std");
const engine = @import("labelle-engine");
const pathfinding = @import("labelle-pathfinding");
const tasks = @import("labelle-tasks");
const items = @import("../components/items.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;
const ItemType = items.ItemType;

// Pathfinding engine
const PFEngine = pathfinding.PathfindingEngineSimple(u32, void);

// Task engine (basic, without hooks dispatcher for simplicity)
const TaskEngine = tasks.Engine(u32, ItemType);

// Station/Storage IDs
pub const Stations = struct {
    // Pathfinding nodes
    pub const counter: u32 = 0;
    pub const pantry: u32 = 1; // EIS location
    pub const oven: u32 = 2; // Workstation location
    pub const shelf: u32 = 3; // EOS location

    // Task engine storage IDs
    pub const eis: u32 = 100; // External Input Storage (pantry)
    pub const iis: u32 = 101; // Internal Input Storage (oven input)
    pub const ios: u32 = 102; // Internal Output Storage (oven output)
    pub const eos: u32 = 103; // External Output Storage (shelf)
    pub const workstation: u32 = 200;
    pub const worker: u32 = 1;
};

// Global state
var pf_engine: ?PFEngine = null;
var task_engine: ?TaskEngine = null;
var baker_visual: ?engine.Entity = null;
var item_visuals: [12]?engine.Entity = .{null} ** 12;
var initialized: bool = false;
var game_ptr: ?*Game = null;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    game_ptr = game;

    // Initialize pathfinding
    pf_engine = PFEngine.init(game.allocator) catch |err| {
        std.log.err("Failed to init pathfinding: {}", .{err});
        return;
    };

    var pe = &pf_engine.?;

    // Create bakery waypoints
    pe.addNode(Stations.counter, 200, 450) catch {};
    pe.addNode(Stations.pantry, 200, 150) catch {};
    pe.addNode(Stations.oven, 600, 150) catch {};
    pe.addNode(Stations.shelf, 600, 450) catch {};

    pe.connectNodes(.{ .omnidirectional = .{ .max_distance = 500, .max_connections = 4 } }) catch {};
    pe.rebuildPaths() catch {};
    pe.registerEntity(Stations.worker, 200, 450, 150.0) catch {};

    // Initialize task engine
    task_engine = TaskEngine.init(game.allocator);
    var te = &task_engine.?;

    // === STORAGE SETUP ===

    // EIS - External Input Storage (Pantry) - holds raw ingredients
    _ = te.addStorage(Stations.eis, .{ .slots = &.{
        .{ .item = .Flour, .capacity = 10 },
        .{ .item = .Water, .capacity = 10 },
        .{ .item = .Yeast, .capacity = 10 },
    } });
    // Stock the pantry
    _ = te.addToStorage(Stations.eis, .Flour, 5);
    _ = te.addToStorage(Stations.eis, .Water, 5);
    _ = te.addToStorage(Stations.eis, .Yeast, 5);

    // IIS - Internal Input Storage (Oven's input buffer) - recipe: 1 of each
    _ = te.addStorage(Stations.iis, .{ .slots = &.{
        .{ .item = .Flour, .capacity = 1 },
        .{ .item = .Water, .capacity = 1 },
        .{ .item = .Yeast, .capacity = 1 },
    } });

    // IOS - Internal Output Storage (Oven's output buffer) - produces bread
    _ = te.addStorage(Stations.ios, .{ .slots = &.{
        .{ .item = .Bread, .capacity = 1 },
    } });

    // EOS - External Output Storage (Shelf) - holds finished bread
    _ = te.addStorage(Stations.eos, .{ .slots = &.{
        .{ .item = .Bread, .capacity = 10 },
    } });

    // === WORKSTATION SETUP ===
    _ = te.addWorkstation(Stations.workstation, .{
        .eis = &.{Stations.eis}, // Pull from pantry
        .iis = Stations.iis, // Into oven input
        .ios = Stations.ios, // Out of oven output
        .eos = &.{Stations.eos}, // Store on shelf
        .process_duration = 120, // 2 seconds at 60fps
    });

    // Set up callbacks BEFORE adding worker (so initial assignment triggers callback)
    te.setOnPickupStarted(onPickupStarted);
    te.setOnProcessStarted(onProcessStarted);
    te.setOnStoreStarted(onStoreStarted);
    te.setOnWorkerReleased(onWorkerReleased);

    // === WORKER SETUP === (triggers pickup_started callback)
    _ = te.addWorker(Stations.worker, .{});

    // Create baker visual
    baker_visual = game.createEntity();
    game.addPosition(baker_visual.?, Position{ .x = 200, .y = 450 });
    game.addShape(baker_visual.?, Shape.circle(20)) catch {};
    if (game.getComponent(Shape, baker_visual.?)) |shape| {
        shape.color = engine.Color{ .r = 255, .g = 200, .b = 150, .a = 255 };
    }

    // Create item visuals
    createItemVisuals(game);

    initialized = true;
    std.log.info("[BAKERY] Task engine initialized with EIS/IIS/IOS/EOS", .{});
}

// === TASK ENGINE CALLBACKS ===
// Signatures: pickup(worker, ws, eis), process(worker, ws), store(worker, ws, eos), released(worker, ws)

fn onPickupStarted(worker_id: u32, _: u32, _: u32) void {
    std.log.info("[HOOK] pickup_started: worker {d} -> pantry (EIS)", .{worker_id});
    sendToStation(worker_id, Stations.pantry);
}

fn onProcessStarted(worker_id: u32, _: u32) void {
    std.log.info("[HOOK] process_started: worker {d} -> oven", .{worker_id});
    sendToStation(worker_id, Stations.oven);
}

fn onStoreStarted(worker_id: u32, _: u32, _: u32) void {
    std.log.info("[HOOK] store_started: worker {d} -> shelf (EOS)", .{worker_id});
    sendToStation(worker_id, Stations.shelf);
}

fn onWorkerReleased(worker_id: u32, _: u32) void {
    std.log.info("[HOOK] worker_released: worker {d} -> counter", .{worker_id});
    sendToStation(worker_id, Stations.counter);

    // Update bread visuals
    if (task_engine) |*te| {
        const bread = te.getStorageQuantity(Stations.eos, .Bread);
        if (game_ptr) |game| {
            updateBreadVisuals(game, bread);
        }
    }
}

fn createItemVisuals(game: *Game) void {
    // Ingredients at pantry (EIS)
    item_visuals[0] = game.createEntity();
    game.addPosition(item_visuals[0].?, Position{ .x = 160, .y = 120 });
    game.addShape(item_visuals[0].?, Shape.rectangle(12, 16)) catch {};
    if (game.getComponent(Shape, item_visuals[0].?)) |s| s.color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    item_visuals[1] = game.createEntity();
    game.addPosition(item_visuals[1].?, Position{ .x = 200, .y = 120 });
    game.addShape(item_visuals[1].?, Shape.rectangle(12, 16)) catch {};
    if (game.getComponent(Shape, item_visuals[1].?)) |s| s.color = .{ .r = 100, .g = 150, .b = 255, .a = 255 };

    item_visuals[2] = game.createEntity();
    game.addPosition(item_visuals[2].?, Position{ .x = 240, .y = 120 });
    game.addShape(item_visuals[2].?, Shape.rectangle(12, 16)) catch {};
    if (game.getComponent(Shape, item_visuals[2].?)) |s| s.color = .{ .r = 255, .g = 220, .b = 100, .a = 255 };

    std.log.info("[BAKERY] EIS (Pantry): Flour(white), Water(blue), Yeast(yellow)", .{});
}

pub fn sendToStation(entity_id: u32, station: u32) void {
    if (pf_engine) |*pe| {
        pe.requestPath(entity_id, station) catch {};
    }
}

pub fn notifyArrival(worker_id: u32) void {
    if (task_engine) |*te| {
        const pe = &(pf_engine orelse return);
        const current = pe.getCurrentNode(worker_id) orelse return;

        // Notify task engine based on where we arrived
        if (current == Stations.pantry) {
            te.notifyPickupComplete(worker_id);
        } else if (current == Stations.shelf) {
            te.notifyStoreComplete(worker_id);
        }
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    if (!initialized) return;

    var pe = &(pf_engine orelse return);
    var te = &(task_engine orelse return);
    const baker = baker_visual orelse return;

    // Tick pathfinding
    pe.tick({}, dt);

    // Update baker visual
    if (pe.getPosition(Stations.worker)) |pos| {
        game.setPosition(baker, Position{ .x = pos.x, .y = pos.y });
    }

    // Check if baker arrived at destination
    const was_moving = pe.isMoving(Stations.worker);
    if (!was_moving) {
        const current = pe.getCurrentNode(Stations.worker) orelse Stations.counter;

        // Notify task engine of arrival
        if (current == Stations.pantry) {
            te.notifyPickupComplete(Stations.worker);
        } else if (current == Stations.shelf) {
            te.notifyStoreComplete(Stations.worker);
        }
    }

    // Update task engine
    te.update();

    // Update visuals
    updateStorageVisuals(game, te);

    // WASD camera
    const input = game.getInput();
    const camera_speed: f32 = 200.0;
    const camera = game.getCamera();
    if (input.isKeyDown(.w)) camera.pan(0, -camera_speed * dt);
    if (input.isKeyDown(.s)) camera.pan(0, camera_speed * dt);
    if (input.isKeyDown(.a)) camera.pan(-camera_speed * dt, 0);
    if (input.isKeyDown(.d)) camera.pan(camera_speed * dt, 0);
}

var last_bread: u32 = 0;

fn updateStorageVisuals(game: *Game, te: *TaskEngine) void {
    const bread = te.getStorageQuantity(Stations.eos, .Bread);
    if (bread != last_bread) {
        updateBreadVisuals(game, bread);
        last_bread = bread;
    }
}

fn updateBreadVisuals(game: *Game, count: u32) void {
    var i: u32 = 0;
    while (i < count and i < 5) : (i += 1) {
        const idx: usize = 3 + i;
        if (item_visuals[idx] == null) {
            item_visuals[idx] = game.createEntity();
            const x_off: f32 = @as(f32, @floatFromInt(i % 3)) * 30.0;
            game.addPosition(item_visuals[idx].?, Position{ .x = 560 + x_off, .y = 420 });
            game.addShape(item_visuals[idx].?, Shape.rectangle(16, 12)) catch {};
            if (game.getComponent(Shape, item_visuals[idx].?)) |s| {
                s.color = .{ .r = 200, .g = 150, .b = 80, .a = 255 };
            }
            std.log.info("[BAKERY] Bread #{d} added to EOS (Shelf)", .{i + 1});
        }
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = scene;

    if (pf_engine) |*pe| {
        pe.deinit();
        pf_engine = null;
    }

    if (task_engine) |*te| {
        te.deinit();
        task_engine = null;
    }

    if (baker_visual) |b| {
        game.getRegistry().destroy(b);
        baker_visual = null;
    }

    for (&item_visuals) |*v| {
        if (v.*) |e| {
            game.getRegistry().destroy(e);
            v.* = null;
        }
    }

    game_ptr = null;
    initialized = false;
}
