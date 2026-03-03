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
