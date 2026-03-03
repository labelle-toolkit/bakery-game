# RFC: Pathfinder Plugin

**Issue:** #15
**Branch:** `feature/pathfinder-plugin`
**Status:** Draft

---

## Motivation

The bakery-game currently uses straight-line movement — workers move directly from point A to point B via linear interpolation in `worker_movement.zig`. There is no obstacle avoidance and no pathfinding. As the game world grows with more workstations, walls, or layout constraints, workers need to navigate around obstacles rather than clipping through them.

The `labelle-engine` already references a `labelle-pathfinding` API in its example code (`usage/example_3/scripts/pathfinding.zig`), but no actual implementation exists in the toolkit. This RFC proposes building that implementation as a local plugin in `libs/pathfinder/`.

## Goals

- Provide Floyd-Warshall all-pairs shortest path navigation using **scene-placed waypoint entities**
- Three ECS components: **MovementNode** (waypoints, auto-connect on same X axis), **MovementStair** (marker enabling vertical connections on same Y axis), and **ClosestMovementNode** (auto-assigned to nearby entities)
- Precompute all-pairs shortest paths so path queries are O(1) per hop
- Dirty flag + lazy rebuild: adding/removing nodes only marks the graph dirty — Floyd-Warshall runs once on the next `tick()` or path query
- Integrate cleanly with the existing `MovementTarget` + `worker_movement.zig` pattern
- Depend on `labelle-engine` core for ECS access — the pathfinder sets components directly on entities

## Non-Goals

- Uniform grid pathfinding — nodes are designer-placed, not auto-generated
- Per-request pathfinding (A*, Dijkstra) — Floyd-Warshall precomputes everything

## Design

### Directory Structure

```
libs/pathfinder/
  build.zig
  build.zig.zon
  src/
    root.zig            # Public API re-exports
    graph.zig           # Node/edge graph, adjacency management
    floyd_warshall.zig  # Floyd-Warshall all-pairs shortest paths
    engine.zig          # PathfindingEngine: entity tracking, path requests, tick simulation
    types.zig           # Shared types (NodeId, Vec2, etc.)
  tests/
    graph_test.zig
    floyd_warshall_test.zig
    engine_test.zig
  RFC.md
```

### Configuration (`pathfinder.zon`)

The pathfinder is configured via a `.zon` file placed in the game project root alongside `project.labelle`. This keeps the graph parameters designer-tunable without recompiling the library.

```zig
// bakery-game/pathfinder.zon
.{
    /// Max distance (in world units) for auto-connecting MovementNodes on the same X axis.
    .max_connection_distance = 200.0,

    /// Max distance (in world units) for auto-connecting MovementStair nodes on the same Y axis.
    .max_stair_distance = 150.0,

    /// Float tolerance for "same axis" comparison.
    /// Nodes with coordinate values within this tolerance are considered axis-aligned.
    .axis_tolerance = 1.0,
}
```

The init script reads this file at scene load and passes the values to `Graph.init()`. This means designers can tweak connection distances per-project without touching library code.

### ECS Components

These are game-side components (defined in bakery-game's `components/` folder), not part of the library itself. The library operates on abstract NodeIds — the game maps ECS entities to NodeIds.

#### MovementNode

Placed on entities that act as **waypoints** in the pathfinding graph. Designers place these in the scene — no manual neighbor wiring needed. Edges are **auto-computed**: MovementNodes on the **same X axis** within `max_connection_distance` are connected.

```zig
// components/movement_node.zig
pub const MovementNode = struct {
    /// Unique node index assigned at registration time.
    node_id: u32 = 0,
};
```

A room can have up to 8 MovementNodes. In the scene `.zon`, designers only need to place them with a position:
```zig
.{ .id = "kitchen_node_1", .components = .{ .Position = .{ .x = 200, .y = 150 }, .MovementNode = .{} } },
.{ .id = "kitchen_node_2", .components = .{ .Position = .{ .x = 200, .y = 300 }, .MovementNode = .{} } },
.{ .id = "kitchen_node_3", .components = .{ .Position = .{ .x = 350, .y = 150 }, .MovementNode = .{} } },
```

`kitchen_node_1` and `kitchen_node_2` share `x=200` and are within max distance → connected. `kitchen_node_3` is on a different X → **not** connected to them (unless via a stair).

#### MovementStair

A marker component added **alongside** MovementNode on entities that act as stair waypoints. Enables vertical connections: MovementStair nodes on the **same Y axis** within `max_stair_distance` are connected to each other.

```zig
// components/movement_stair.zig
pub const MovementStair = struct {};
```

In the scene `.zon`:
```zig
// Floor 1 stair entrance
.{ .id = "stair_bottom", .components = .{ .Position = .{ .x = 400, .y = 150 }, .MovementNode = .{}, .MovementStair = .{} } },
// Floor 2 stair exit — same Y, different X (different floor)
.{ .id = "stair_top",    .components = .{ .Position = .{ .x = 500, .y = 150 }, .MovementNode = .{}, .MovementStair = .{} } },
```

`stair_bottom` and `stair_top` both have `MovementStair`, share `y=150`, and are within `max_stair_distance` → connected. Regular MovementNodes without `MovementStair` on the same Y axis are **not** connected.

```
Example: Two floors with a stair connecting them

  Floor 2:   C(200,300) ------- D(200,450)    C-D: same X=200, dist=150 ✓
                  |
                  | stair (same Y=300)
                  |
  Floor 1:   A(100,300) ------- B(100,150)    A-B: same X=100, dist=150 ✓

  A has MovementStair, C has MovementStair.
  A(100,300) and C(200,300): same Y=300, both have MovementStair,
  dist=100 ≤ max_stair_distance → connected ✓
```

#### ClosestMovementNode

Auto-assigned to entities that are near a MovementNode (workers, storages, workstations). This tells the pathfinder which node an entity "belongs to" — its entry/exit point in the graph.

```zig
// components/closest_movement_node.zig
pub const ClosestMovementNode = struct {
    /// Entity ID of the nearest MovementNode entity.
    node_entity: u64,
    /// Cached node_id for fast lookup (avoids extra ECS query).
    node_id: u32,
    /// Distance to the node (for debugging / tie-breaking).
    distance: f32 = 0.0,
};
```

Assignment happens once at scene load (or when a room is created): a script iterates all entities with Position but without ClosestMovementNode, finds the nearest MovementNode, and assigns it.

### Graph (`graph.zig`)

An adjacency-based graph built from MovementNode positions. Edges are **auto-computed** — no manual wiring.

**Two auto-connection rules:**

1. **Same X axis** (MovementNode): Nodes sharing the same X coordinate (within `axis_tolerance`) connect to their **nearest neighbor** above and below on that axis, provided the distance is ≤ `max_connection_distance`. This creates floor paths without skipping intermediate nodes.

2. **Same Y axis** (MovementStair): Stair nodes sharing the same Y coordinate (within `axis_tolerance`) connect to their **nearest neighbor** left and right on that axis, provided both nodes have `MovementStair` and the distance is ≤ `max_stair_distance`. This creates vertical stair connections between floors.

```
Example: Two-floor bakery with a stair

  Floor 2:   C(200,300) ------- D(200,450)    C-D: same X=200, dist=150 ✓
                  |
                  | stair (same Y=300)
                  |
  Floor 1:   A(100,300) ------- B(100,150)    A-B: same X=100, dist=150 ✓

  A↔C: both have MovementStair, same Y=300, dist=100 ≤ max_stair_distance ✓
  B↔D: different X, different Y, no stair → not connected ✗
```

```zig
pub const Graph = struct {
    allocator: Allocator,
    /// Node positions indexed by NodeId.
    positions: std.ArrayList(Vec2),
    /// Whether each node is a stair node.
    is_stair: std.ArrayList(bool),
    /// Adjacency list: edges[node_id] = list of { neighbor_id, cost }.
    edges: std.ArrayList(std.ArrayList(Edge)),
    /// Config loaded from pathfinder.zon.
    config: Config,
    /// Dirty flag — set on any mutation, cleared after Floyd-Warshall rebuild.
    dirty: bool = true,

    pub const Config = struct {
        max_connection_distance: f32,
        max_stair_distance: f32,
        axis_tolerance: f32 = 1.0,
    };

    pub const Edge = struct {
        to: NodeId,
        cost: f32,
    };

    /// Register a new node. Returns its NodeId.
    /// Auto-connects to existing nodes on the same X axis within max_connection_distance.
    /// If is_stair=true, also auto-connects to existing stair nodes on the same Y axis
    /// within max_stair_distance.
    /// Sets dirty = true.
    pub fn addNode(self: *Graph, position: Vec2, is_stair: bool) NodeId

    /// Remove a node and all its edges. Sets dirty = true.
    pub fn removeNode(self: *Graph, node_id: NodeId) void

    /// Number of registered nodes.
    pub fn nodeCount(self: *const Graph) u32
};
```

`addNode` logic:
1. Appends the node to the positions list (and `is_stair` to the stair list)
2. Finds the **nearest neighbor** on the same X axis in each direction (above/below):
   - Scans all existing nodes with same X (within `axis_tolerance`)
   - Of those within `max_connection_distance`, picks the closest above and closest below
   - Creates bidirectional edges to those two neighbors (cost = Euclidean distance)
   - **Re-evaluates** existing edges between neighbors on the same X — if the new node sits between two previously-connected nodes, the old direct edge is replaced by two shorter edges through the new node
3. If `is_stair`, finds the **nearest stair neighbor** on the same Y axis in each direction (left/right):
   - Same logic as above but filtered to stair nodes, using `max_stair_distance`

Every mutation sets `dirty = true`. No Floyd-Warshall rebuild happens until the next `tick()` or path query.

### Floyd-Warshall (`floyd_warshall.zig`)

All-pairs shortest paths precomputed from the graph. Trades upfront O(V³) computation and O(V²) memory for O(1) next-hop lookups at runtime.

**Data structures:**
```zig
const FloydWarshall = struct {
    /// dist[i * n + j] = shortest distance from node i to node j
    dist: []f32,
    /// next[i * n + j] = first node on shortest path from i to j
    next: []?NodeId,
    node_count: u32,
};
```

**Core operations:**

```zig
/// Build distance and next-hop matrices from the graph's adjacency.
/// O(V³) time, O(V²) space where V = graph.nodeCount().
pub fn build(allocator: Allocator, graph: *const Graph) !FloydWarshall

/// Reconstruct full path from start to goal by following the next-hop matrix.
/// Returns null if unreachable. O(path_length).
pub fn getPath(self: *const FloydWarshall, allocator: Allocator, start: NodeId, goal: NodeId) !?[]NodeId

/// O(1) — lookup next hop without reconstructing full path.
pub fn getNextHop(self: *const FloydWarshall, from: NodeId, to: NodeId) ?NodeId

/// O(1) — precomputed shortest distance.
pub fn getDistance(self: *const FloydWarshall, from: NodeId, to: NodeId) f32
```

**Why Floyd-Warshall:**
- Node count is small (a few dozen MovementNodes per scene). Floyd-Warshall on 50 nodes is ~125K operations — trivial.
- Workers request paths constantly (pickup, deliver, transport, seek needs). Precomputing avoids repeated per-request overhead.
- `getNextHop()` enables a lazy approach: instead of reconstructing the full path upfront, the engine can query one hop at a time during `tick()`, reducing memory per entity.

### Dirty Flag + Lazy Rebuild

When a room is created, it may add up to 8 MovementNodes in a single frame. Each `addNode` / `addEdge` call only sets `dirty = true` — Floyd-Warshall is **not** recomputed until needed.

The rebuild is triggered lazily:
- At the start of `tick()`: if `dirty`, rebuild then clear the flag
- On `getNextHop()` / `getDistance()`: if `dirty`, rebuild first

```
Room creation (single frame):
  addNode(n1) → dirty = true  (auto-connects to existing axis-aligned nodes)
  addNode(n2) → dirty = true  (already true, no-op)
  ...
  addNode(n8) → dirty = true

Next tick():
  if (dirty) rebuild()   ← runs once for all 8 nodes
  dirty = false
  ... process entity movement ...
```

### MovementPath Component

The pathfinder manages this component internally. It is set on an entity when `navigate()` is called, updated every `tick()`, and removed on arrival. The game reads it but never writes to it.

```zig
// Defined in the pathfinder library (src/movement_path.zig)
pub const MovementPath = struct {
    /// Full sequence of world positions from start to goal.
    positions: []const Vec2,
    /// Index of the node the entity is currently moving toward.
    current_index: u32 = 0,
    /// Total number of waypoints.
    len: u32,
    /// Movement speed (world units per second).
    /// Set at navigate() time, but the game can modify it at any point
    /// (e.g. slow down when carrying a heavy item). The pathfinder reads
    /// this value each tick, so changes take effect immediately.
    speed: f32,
    /// Goal node ID (for the game to identify the destination).
    goal_node: NodeId,
};
```

### Navigation Hooks

Following the engine's comptime hook pattern (tagged union + `HookDispatcher`), the pathfinder defines a `NavigationHookPayload` union. The game provides a hook struct with functions matching the tag names. Dispatch is comptime-validated — typos are caught at compile time, zero runtime overhead.

```zig
// Defined in the pathfinder library (src/hooks.zig)
const engine = @import("labelle-engine");
const Entity = engine.Entity;

pub fn NavigationHookPayload(comptime GameId: type) type {
    return union(enum) {
        /// Entity arrived at its final destination.
        arrived: struct {
            entity: GameId,
            goal_node: NodeId,
            registry: ?*anyopaque,
        },
        /// Graph changed and the entity's path is no longer valid.
        /// The entity has been stopped at its current position.
        path_invalidated: struct {
            entity: GameId,
            goal_node: NodeId,
            /// The node the entity was at when the path broke.
            current_node: NodeId,
            registry: ?*anyopaque,
        },
    };
}
```

**Game-side hook handler** (same pattern as `task_hooks.zig`):

```zig
// bakery-game/hooks/pathfinder_hooks.zig
pub const PathfinderGameHooks = struct {
    pub fn arrived(payload: anytype) void {
        const registry: *engine.Registry = @ptrCast(@alignCast(payload.registry orelse return));
        const entity = engine.entityFromU64(payload.entity);
        // e.g. call pickupCompleted, storeCompleted based on goal_node
        handleArrival(registry, entity, payload.goal_node);
    }

    pub fn path_invalidated(payload: anytype) void {
        const registry: *engine.Registry = @ptrCast(@alignCast(payload.registry orelse return));
        const entity = engine.entityFromU64(payload.entity);
        // Re-navigate, assign a different task, or idle the entity
        handlePathBroken(registry, entity, payload.current_node);
    }
};
```

### Pathfinder (`engine.zig`) — Game-Facing Interface

The `Pathfinder` is parameterized on `GameId` and the game's hook struct at comptime. It owns the `Graph`, `FloydWarshall`, and the full movement loop internally. Hooks are dispatched via the engine's `HookDispatcher` — same pattern as `labelle-tasks`.

```zig
const engine = @import("labelle-engine");

/// Create a Pathfinder type parameterized on game types and hooks.
/// Called from createEngineHooks (wired via project.labelle plugin config).
pub fn PathfinderWith(
    comptime GameId: type,
    comptime GameHooks: type,
) type {
    const Payload = NavigationHookPayload(GameId);
    const Dispatcher = engine.HookDispatcher(Payload, GameHooks, .{});

    return struct {
        graph: Graph,
        fw: ?FloydWarshall = null,
        allocator: Allocator,
        hooks: Dispatcher,

        const Self = @This();

        /// Initialize with config loaded from pathfinder.zon.
        pub fn init(allocator: Allocator, config: Graph.Config) Self

        pub fn deinit(self: *Self) void

        // --- Graph building (called at scene load / room creation) ---

        /// Register a node. Auto-connects to nearest axis-aligned neighbors.
        /// Does NOT trigger a rebuild — just marks dirty.
        pub fn addNode(self: *Self, position: Vec2, is_stair: bool) NodeId

        /// Remove a node and all its edges. Marks dirty.
        pub fn removeNode(self: *Self, node_id: NodeId) void

        // --- Navigation (main game interface) ---

        /// Compute the shortest path and start moving the entity.
        /// If a path exists:
        ///   - Sets a MovementPath component on the entity
        ///   - Returns a pointer to the component
        /// If no path exists:
        ///   - Returns null, no component is added
        /// Triggers a lazy Floyd-Warshall rebuild if the graph is dirty.
        pub fn navigate(
            self: *Self,
            game: *engine.Game,
            entity: engine.Entity,
            from_node: NodeId,
            to_node: NodeId,
            speed: f32,
        ) ?*const MovementPath

        /// Cancel navigation — removes MovementPath from the entity.
        /// Does NOT fire a hook.
        pub fn cancel(self: *Self, game: *engine.Game, entity: engine.Entity) void

        // --- Tick (called once per frame) ---

        /// Advance all navigating entities.
        /// Uses game.pos.moveLocalPosition() to update entity positions.
        /// Handles movement interpolation, waypoint advancement,
        /// arrival detection, and path re-validation on graph changes.
        /// Fires hooks via HookDispatcher.
        pub fn tick(self: *Self, game: *engine.Game, dt: f32) void

        // --- Utility queries ---

        /// Precomputed shortest distance between two nodes. Returns inf if unreachable.
        pub fn distance(self: *Self, from: NodeId, to: NodeId) f32

        /// Check if a path exists between two nodes.
        pub fn isReachable(self: *Self, from: NodeId, to: NodeId) bool

        /// Get the world position of a node.
        pub fn nodePosition(self: *Self, node_id: NodeId) Vec2
    };
}
```

**`tick()` internal loop:**

`tick` receives `*Game` and `dt: f32`. It uses `game.pos.moveLocalPosition(entity, dx, dy)` to update positions — this is the engine's standard way to move entities (handles render pipeline dirty tracking).

1. If `graph.dirty`:
   a. Rebuild Floyd-Warshall matrices, clear dirty flag
   b. **Re-validate active paths**: for each entity with `MovementPath`, check if `isReachable(current_node, goal_node)` still holds. If not:
      - Remove `MovementPath` from the entity
      - Dispatch `.path_invalidated` hook (with entity, goal_node, current_node, registry)
2. For each entity with `MovementPath` + `Position`:
   a. Compute direction toward `path.positions[current_index]`, move by `path.speed * dt` using `game.pos.moveLocalPosition(entity, dx, dy)`
   b. If within arrival threshold of waypoint, increment `current_index`
   c. If `current_index >= path.len` (arrived at final destination):
      - Remove `MovementPath` from the entity
      - Dispatch `.arrived` hook (with entity, goal_node, registry)

**Plugin wiring** (same pattern as labelle-tasks in `project.labelle`):

```zig
// project.labelle
.plugins = .{
    .{
        .name = "pathfinder",
        .path = "libs/pathfinder",
        .engine_hooks = .{
            .create = "createEngineHooks",
            .hooks = "pathfinder_hooks.PathfinderGameHooks",
        },
    },
},
```

**Usage from game scripts:**

```zig
// --- Requesting navigation (e.g. in task_hooks or eos_transport) ---
const worker_node = game.getRegistry().get(entity, ClosestMovementNode).node_id;
const target_node = game.getRegistry().get(target_entity, ClosestMovementNode).node_id;

if (pathfinder.navigate(game, entity, worker_node, target_node, 200.0)) |path| {
    std.log.info("Navigating: {d} waypoints", .{path.len});
} else {
    std.log.warn("No path to node {d}", .{target_node});
}

// --- Tick (called once per frame in a script update) ---
pathfinder.tick(game, dt);
// Pathfinder moves entities via game.pos.moveLocalPosition()
// Arrivals and path invalidations are handled via hooks
```

### Integration with Bakery Game

The pathfinder depends on `labelle-engine` core for ECS types and registry access. It does not depend on the game itself — game-side components like `ClosestMovementNode` are handled by game scripts, not by the library.

**Scene setup flow:**

1. Designer places `MovementNode` (and optionally `MovementStair`) entities in the scene `.zon` — just position, no neighbor wiring
2. On scene load, an init script (`pathfinder_init.zig`):
   - Reads `pathfinder.zon` config, initializes `Pathfinder` with `Config`
   - Queries all entities with `MovementNode` + `Position` components
   - For each, checks if entity also has `MovementStair`
   - Calls `pathfinder.addNode(position, has_stair)` — edges auto-computed by axis alignment using config values
   - Stores the returned `NodeId` back into the `MovementNode` component
   - Queries all entities with `Position` but no `MovementNode` (workers, storages, etc.)
   - Finds nearest `MovementNode` and assigns `ClosestMovementNode` component
3. Graph is dirty after setup — first `navigate()` call triggers a single Floyd-Warshall rebuild

**Movement flow:**

1. Game calls `pathfinder.navigate(game, entity, from_node, to_node, speed)` → `*const MovementPath` or `null`
2. Game calls `pathfinder.tick(game, dt)` once per frame
3. Pathfinder moves all navigating entities via `game.pos.moveLocalPosition(entity, dx, dy)` using `dt` for frame-rate independent movement
4. On arrival → `.arrived` hook fires — game handles completion (e.g. `pickupCompleted`)
5. If a graph change invalidates an active path → `.path_invalidated` hook fires — game can re-navigate or reassign the entity

### Build Integration

The library depends on `labelle-engine` and is consumed as a Zig package:

```zig
// libs/pathfinder/build.zig.zon
.dependencies = .{
    .@"labelle-engine" = .{ .path = "../../labelle-engine" },
},
```

```zig
// bakery-game/.labelle/raylib_desktop/build.zig.zon
.dependencies = .{
    .pathfinder = .{ .path = "../../libs/pathfinder" },
    // ...
},
```

And exposed to game scripts:
```zig
// build.zig
const pathfinder = b.dependency("pathfinder", .{});
exe.root_module.addImport("pathfinder", pathfinder.module("pathfinder"));
```

## Implementation Plan

1. **Scaffold** — `types.zig`, `graph.zig` with node/edge management, dirty flag
2. **Floyd-Warshall** — `floyd_warshall.zig` with tests for all-pairs shortest paths, unreachable nodes
3. **Engine** — `engine.zig` with entity registration, lazy rebuild on tick, hop-by-hop movement
4. **Public API** — `root.zig` re-exports, `build.zig` / `build.zig.zon` package setup
5. **Game components** — `MovementNode`, `MovementStair`, `ClosestMovementNode` component definitions
6. **Game integration** — `pathfinder_init.zig` (scene setup), `pathfinder_bridge.zig` (movement bridge)

## Open Questions

1. **ClosestMovementNode reassignment**: When a new room is created at runtime (new MovementNodes added), should nearby entities have their `ClosestMovementNode` recalculated? Or is it only assigned once at scene load?
2. **Node removal**: When a room is destroyed, should its MovementNodes be removed from the graph (triggering a lazy rebuild), or just marked as disabled?
