const std = @import("std");
const pathfinder = @import("pathfinder");

const Graph = pathfinder.Graph;
const Config = pathfinder.Config;
const FloydWarshall = pathfinder.FloydWarshall;
const INF = pathfinder.INF;

const test_config = Config{
    .max_connection_distance = 200.0,
    .max_stair_distance = 150.0,
    .axis_tolerance = 1.0,
};

test "shortest path on simple linear graph" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // A(100,100) -- B(100,200) -- C(100,300) on same X axis
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);
    const c = try g.addNode(.{ .x = 100, .y = 300 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    // A to C should go through B, total distance = 200
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), fw.getDistance(a, b), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), fw.getDistance(a, c), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), fw.getDistance(b, c), 0.01);
}

test "unreachable nodes return null and inf" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two disconnected nodes (different X axis)
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 300, .y = 100 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    try std.testing.expect(fw.getDistance(a, b) == INF);
    try std.testing.expect(fw.getNextHop(a, b) == null);

    const path = try fw.getPath(std.testing.allocator, a, b);
    try std.testing.expect(path == null);
}

test "path reconstruction matches expected sequence" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // A -- B -- C on same X
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);
    const c = try g.addNode(.{ .x = 100, .y = 300 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    const path = (try fw.getPath(std.testing.allocator, a, c)).?;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqual(a, path[0]);
    try std.testing.expectEqual(b, path[1]);
    try std.testing.expectEqual(c, path[2]);
}

test "single node graph" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fw.getDistance(a, a), 0.01);

    const path = (try fw.getPath(std.testing.allocator, a, a)).?;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(@as(usize, 1), path.len);
    try std.testing.expectEqual(a, path[0]);
}

test "next hop gives first step" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // A -- B -- C
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);
    const c = try g.addNode(.{ .x = 100, .y = 300 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    // Next hop from A to C should be B
    try std.testing.expectEqual(b, fw.getNextHop(a, c).?);
    // Next hop from B to A should be A
    try std.testing.expectEqual(a, fw.getNextHop(b, a).?);
    // Next hop from A to B should be B (direct neighbor)
    try std.testing.expectEqual(b, fw.getNextHop(a, b).?);
}

test "two-floor stair path" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Floor 1: A(100,100) -- B(100,300) on X=100
    // Floor 2: C(200,300) -- D(200,450) on X=200
    // Stair: B(100,300) -- C(200,300) on Y=300 (both stairs)
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 300 }, true); // stair
    const c = try g.addNode(.{ .x = 200, .y = 300 }, true); // stair
    const d = try g.addNode(.{ .x = 200, .y = 450 }, false);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    // A to D: A -> B -> C -> D
    const path = (try fw.getPath(std.testing.allocator, a, d)).?;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(@as(usize, 4), path.len);
    try std.testing.expectEqual(a, path[0]);
    try std.testing.expectEqual(b, path[1]);
    try std.testing.expectEqual(c, path[2]);
    try std.testing.expectEqual(d, path[3]);

    // Verify total distance: A-B=200, B-C=100, C-D=150 = 450
    try std.testing.expectApproxEqAbs(@as(f32, 450.0), fw.getDistance(a, d), 0.01);
}

test "removed nodes are excluded from paths" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // A -- B -- C
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try g.addNode(.{ .x = 100, .y = 200 }, false); // B
    const c = try g.addNode(.{ .x = 100, .y = 300 }, false);

    // Remove B
    g.removeNode(1);

    var fw = try FloydWarshall.build(std.testing.allocator, &g);
    defer fw.deinit();

    // A to C should be unreachable (B was the bridge)
    try std.testing.expect(fw.getDistance(a, c) == INF);
    try std.testing.expect(fw.getNextHop(a, c) == null);
}
