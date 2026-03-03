const std = @import("std");
const pathfinder = @import("pathfinder");

const PathfinderWith = pathfinder.PathfinderWith;
const Config = pathfinder.Config;
const Position = @import("labelle-core").Position;

const test_config = Config{
    .max_connection_distance = 200.0,
    .max_stair_distance = 150.0,
    .axis_tolerance = 1.0,
};

/// Mock game context for testing
const MockCtx = struct {
    positions: std.AutoHashMap(u64, Position),
    move_calls: std.ArrayListUnmanaged(MoveCall) = .{},
    allocator: std.mem.Allocator,

    const MoveCall = struct {
        entity: u64,
        dx: f32,
        dy: f32,
    };

    fn init(allocator: std.mem.Allocator) MockCtx {
        return .{
            .positions = std.AutoHashMap(u64, Position).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *MockCtx) void {
        self.positions.deinit();
        self.move_calls.deinit(self.allocator);
    }

    pub fn getEntityPosition(self: *MockCtx, entity: u64) ?Position {
        return self.positions.get(entity);
    }

    pub fn moveEntity(self: *MockCtx, entity: u64, dx: f32, dy: f32) void {
        self.move_calls.append(self.allocator, .{ .entity = entity, .dx = dx, .dy = dy }) catch {};
        if (self.positions.getPtr(entity)) |pos| {
            pos.x += dx;
            pos.y += dy;
        }
    }
};

const NoHooks = struct {};

test "navigate returns path when route exists" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // A -- B -- C on same X
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 300 }, false);

    const path = try pf.navigate(1, 0, 2, 100.0);
    try std.testing.expect(path != null);
    try std.testing.expectEqual(@as(u32, 3), path.?.len);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), path.?.speed, 0.01);
}

test "navigate returns null when route does not exist" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // Two disconnected nodes
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 300, .y = 100 }, false);

    const path = try pf.navigate(1, 0, 1, 100.0);
    try std.testing.expect(path == null);
}

test "cancel removes active navigation" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false);

    _ = try pf.navigate(1, 0, 1, 100.0);
    try std.testing.expect(pf.isNavigating(1));

    pf.cancel(1);
    try std.testing.expect(!pf.isNavigating(1));
}

test "tick moves entity toward target" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // A(100,100) -- B(100,200) on same X
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false);

    var ctx = MockCtx.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.positions.put(42, .{ .x = 100, .y = 100 });

    _ = try pf.navigate(42, 0, 1, 100.0);

    // Tick with dt=0.5 → should move 50 units toward (100,200)
    pf.tick(&ctx, 0.5);

    try std.testing.expect(ctx.move_calls.items.len > 0);
    // Entity should have moved in the Y direction
    const last_move = ctx.move_calls.items[ctx.move_calls.items.len - 1];
    try std.testing.expectEqual(@as(u64, 42), last_move.entity);
}

test "distance and isReachable queries" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false);
    _ = try pf.addNode(.{ .x = 300, .y = 100 }, false); // disconnected

    try std.testing.expect(pf.isReachable(0, 1));
    try std.testing.expect(!pf.isReachable(0, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), pf.distance(0, 1), 0.01);
}

test "hook fires on arrival" {
    const TestHooks = struct {
        var arrived_entity: ?u64 = null;
        var arrived_goal: ?u32 = null;

        pub fn arrived(payload: anytype) void {
            arrived_entity = payload.entity;
            arrived_goal = payload.goal_node;
        }
    };

    const Pf = PathfinderWith(u64, TestHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // Two nodes very close together
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try pf.addNode(.{ .x = 100, .y = 101 }, false);

    var ctx = MockCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // Place entity right at node 0 position
    try ctx.positions.put(42, .{ .x = 100, .y = 100 });

    _ = try pf.navigate(42, 0, 1, 1000.0);

    // Reset hook state
    TestHooks.arrived_entity = null;
    TestHooks.arrived_goal = null;

    // Tick — entity should arrive quickly (distance is 1 unit, speed is 1000)
    pf.tick(&ctx, 1.0);

    try std.testing.expectEqual(@as(?u64, 42), TestHooks.arrived_entity);
    try std.testing.expectEqual(@as(?u32, 1), TestHooks.arrived_goal);
    try std.testing.expect(!pf.isNavigating(42));
}

test "path_invalidated fires when mid-path node is removed" {
    const TestHooks = struct {
        var invalidated_entity: ?u64 = null;
        var invalidated_goal: ?u32 = null;
        var invalidated_current: ?u32 = null;

        pub fn path_invalidated(payload: anytype) void {
            invalidated_entity = payload.entity;
            invalidated_goal = payload.goal_node;
            invalidated_current = payload.current_node;
        }

        fn reset() void {
            invalidated_entity = null;
            invalidated_goal = null;
            invalidated_current = null;
        }
    };

    const Pf = PathfinderWith(u64, TestHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // A(100,100) -- B(100,200) -- C(100,300) on same X axis
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false); // node 0
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false); // node 1
    _ = try pf.addNode(.{ .x = 100, .y = 300 }, false); // node 2

    var ctx = MockCtx.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.positions.put(42, .{ .x = 100, .y = 100 });

    // Navigate from node 0 to node 2 (path: 0 → 1 → 2)
    _ = try pf.navigate(42, 0, 2, 100.0);
    try std.testing.expect(pf.isNavigating(42));

    TestHooks.reset();

    // Remove middle node — this breaks the path
    pf.removeNode(1);

    // Tick triggers rebuild + validation
    pf.tick(&ctx, 0.016);

    // Hook should have fired with correct entity and goal
    try std.testing.expectEqual(@as(?u64, 42), TestHooks.invalidated_entity);
    try std.testing.expectEqual(@as(?u32, 2), TestHooks.invalidated_goal);
    // Entity should no longer be navigating
    try std.testing.expect(!pf.isNavigating(42));
}

test "navigate works after node removal creates tombstone" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // A(100,100) -- B(100,200) -- C(100,300) -- D(100,400)
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false); // node 0
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false); // node 1
    _ = try pf.addNode(.{ .x = 100, .y = 300 }, false); // node 2
    _ = try pf.addNode(.{ .x = 100, .y = 400 }, false); // node 3

    // Remove node 1 — creates tombstone. node IDs 0,2,3 remain valid.
    // nodeCount() = 3, totalSlots() = 4. Node 3 has ID >= nodeCount().
    pf.removeNode(1);

    // Navigate from node 2 to node 3 — should still work (they're connected)
    const path = try pf.navigate(42, 2, 3, 100.0);
    try std.testing.expect(path != null);
    try std.testing.expectEqual(@as(u32, 2), path.?.len);

    // Navigate from node 0 to node 3 — should fail (node 1 was the bridge)
    const no_path = try pf.navigate(43, 0, 3, 100.0);
    try std.testing.expect(no_path == null);

    // Verify node 3 (ID=3) is reachable from node 2 — exercises
    // the case where node_id (3) >= nodeCount() (3) but < totalSlots() (4)
    try std.testing.expect(pf.isReachable(2, 3));
}

test "rebuild after graph mutation produces correct results" {
    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // Build initial graph: A -- B
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false); // node 0
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false); // node 1

    // Force a build by querying
    try std.testing.expect(pf.isReachable(0, 1));

    // Mutate the graph (marks dirty again) — add node 2
    _ = try pf.addNode(.{ .x = 100, .y = 300 }, false); // node 2

    // Query triggers rebuild — now 0→2 should be reachable via 1
    try std.testing.expect(pf.isReachable(0, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), pf.distance(0, 2), 0.01);
}

test "stair navigation across floors with max_stair_distance=300" {
    const wide_config = Config{
        .max_connection_distance = 200.0,
        .max_stair_distance = 300.0,
        .axis_tolerance = 1.0,
    };

    const Pf = PathfinderWith(u64, NoHooks);
    var pf = Pf.init(std.testing.allocator, wide_config);
    defer pf.deinit();

    // Layout matching the game: three vertical axes connected by stair nodes
    // x=150: nodes at y=150, y=300 (stair)
    _ = try pf.addNode(.{ .x = 150, .y = 150 }, false); // node 0
    _ = try pf.addNode(.{ .x = 150, .y = 300 }, true); // node 1 (stair)
    // x=400: nodes at y=150 (stair), y=300 (stair)
    _ = try pf.addNode(.{ .x = 400, .y = 150 }, true); // node 2 (stair)
    _ = try pf.addNode(.{ .x = 400, .y = 300 }, true); // node 3 (stair)
    // x=600: nodes at y=300 (stair), y=450
    _ = try pf.addNode(.{ .x = 600, .y = 300 }, true); // node 4 (stair)
    _ = try pf.addNode(.{ .x = 600, .y = 450 }, false); // node 5

    // Navigate from node 0 (x=150,y=150) to node 5 (x=600,y=450)
    // Path should be: 0 → 1 → 3 → 4 → 5 (via stair connections)
    const path = try pf.navigate(1, 0, 5, 100.0);
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len >= 3); // at least start + stair hops + end
    try std.testing.expect(pf.isReachable(0, 5));
}

test "path_invalidated fires when edge is broken by graph change" {
    const TestHooks = struct {
        var invalidated_entity: ?u64 = null;

        pub fn path_invalidated(payload: anytype) void {
            invalidated_entity = payload.entity;
        }

        fn reset() void {
            invalidated_entity = null;
        }
    };

    const Pf = PathfinderWith(u64, TestHooks);
    var pf = Pf.init(std.testing.allocator, test_config);
    defer pf.deinit();

    // Three nodes: A(100,100) -- B(100,200) -- C(100,300)
    _ = try pf.addNode(.{ .x = 100, .y = 100 }, false); // node 0
    _ = try pf.addNode(.{ .x = 100, .y = 200 }, false); // node 1
    _ = try pf.addNode(.{ .x = 100, .y = 300 }, false); // node 2

    var ctx = MockCtx.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.positions.put(10, .{ .x = 100, .y = 100 });

    // Navigate from 0 to 2
    _ = try pf.navigate(10, 0, 2, 100.0);
    try std.testing.expect(pf.isNavigating(10));

    TestHooks.reset();

    // Remove goal node — path is broken
    pf.removeNode(2);

    pf.tick(&ctx, 0.016);

    try std.testing.expectEqual(@as(?u64, 10), TestHooks.invalidated_entity);
    try std.testing.expect(!pf.isNavigating(10));
}
