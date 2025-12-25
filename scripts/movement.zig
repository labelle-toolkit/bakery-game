// Movement script - manages baker pathfinding in the bakery
//
// Sets up a grid of waypoints representing the bakery floor and
// moves bakers between stations (pantry, oven, shelf, counter).

const std = @import("std");
const engine = @import("labelle-engine");
const pathfinding = @import("labelle-pathfinding");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;

// Pathfinding engine with simplified config
const PFEngine = pathfinding.PathfindingEngineSimple(u32, void);

// Station node IDs
pub const Stations = struct {
    pub const counter: u32 = 0; // Starting position
    pub const pantry: u32 = 1; // Pick up ingredients
    pub const oven: u32 = 2; // Process/bake
    pub const shelf: u32 = 3; // Store finished goods
};

// Global pathfinding engine
var pf_engine: ?PFEngine = null;
var baker_visual: ?engine.Entity = null;
var initialized: bool = false;

/// Initialize the pathfinding engine with bakery waypoints
pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    const allocator = game.allocator;

    pf_engine = PFEngine.init(allocator) catch |err| {
        std.log.err("Failed to init pathfinding: {}", .{err});
        return;
    };

    var pe = &pf_engine.?;

    // Create bakery waypoints
    // Layout:
    //
    //   [Pantry]         [Oven]
    //      (200,150)        (600,150)
    //          \            /
    //           \          /
    //            \        /
    //   [Counter]----------[Shelf]
    //      (200,450)        (600,450)

    pe.addNode(Stations.counter, 200, 450) catch {};
    pe.addNode(Stations.pantry, 200, 150) catch {};
    pe.addNode(Stations.oven, 600, 150) catch {};
    pe.addNode(Stations.shelf, 600, 450) catch {};

    // Connect all stations
    pe.connectNodes(.{
        .omnidirectional = .{
            .max_distance = 500,
            .max_connections = 4,
        },
    }) catch {};

    pe.rebuildPaths() catch {};

    // Register the baker (id=1 at counter with speed 150)
    pe.registerEntity(1, 200, 450, 150.0) catch |err| {
        std.log.err("Failed to register baker: {}", .{err});
    };

    // Create the baker visual (circle) - scene entities with Baker component don't work
    // because Baker isn't in the component registry
    baker_visual = game.createEntity();
    game.addPosition(baker_visual.?, Position{ .x = 200, .y = 450 });
    game.addShape(baker_visual.?, Shape.circle(20)) catch {};
    if (game.getComponent(Shape, baker_visual.?)) |shape| {
        shape.color = engine.Color{ .r = 255, .g = 200, .b = 150, .a = 255 };
    }

    initialized = true;
    std.log.info("[MOVEMENT] Bakery pathfinding initialized", .{});
}

/// Send a baker to a specific station
pub fn sendToStation(baker_id: u32, station: u32) void {
    if (pf_engine) |*pe| {
        pe.requestPath(baker_id, station) catch |err| {
            std.log.err("Failed to request path: {}", .{err});
        };
        std.log.info("[MOVEMENT] Baker {d} moving to station {d}", .{ baker_id, station });
    }
}

/// Get the current position of a baker
pub fn getPosition(baker_id: u32) ?pathfinding.Vec2 {
    if (pf_engine) |*pe| {
        return pe.getPosition(baker_id);
    }
    return null;
}

/// Check if a baker is currently moving
pub fn isMoving(baker_id: u32) bool {
    if (pf_engine) |*pe| {
        return pe.isMoving(baker_id);
    }
    return false;
}

/// Update script - called every frame
pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized) return;

    var pe = &(pf_engine orelse return);
    const baker = baker_visual orelse return;

    // Tick the pathfinding engine
    pe.tick({}, dt);

    // Update baker position in ECS from pathfinding
    if (pe.getPosition(1)) |pos| {
        game.setPosition(baker, Position{ .x = pos.x, .y = pos.y });
    }

    // Handle input - press SPACE to cycle through stations
    const input = game.getInput();
    if (input.isKeyPressed(.space)) {
        const stations = [_]u32{ Stations.pantry, Stations.oven, Stations.shelf, Stations.counter };
        const current = pe.getCurrentNode(1) orelse 0;

        // Find current index and move to next
        var next_idx: usize = 0;
        for (stations, 0..) |s, i| {
            if (s == current) {
                next_idx = (i + 1) % stations.len;
                break;
            }
        }

        sendToStation(1, stations[next_idx]);
        std.log.info("[MOVEMENT] SPACE pressed - moving to next station", .{});
    }
}

/// Cleanup
pub fn deinit(game: *Game, scene: *Scene) void {
    _ = scene;

    if (pf_engine) |*pe| {
        pe.deinit();
        pf_engine = null;
    }

    if (baker_visual) |baker| {
        game.getRegistry().destroy(baker);
        baker_visual = null;
    }

    initialized = false;
}
