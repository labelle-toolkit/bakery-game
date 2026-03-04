const std = @import("std");
const expect = @import("zspec").expect;
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

/// Factory for building common graph topologies used across specs.
const GraphFactory = struct {
    /// A -- B -- C linear chain on same X axis.
    fn linear3(allocator: std.mem.Allocator) struct { graph: Graph, a: u32, b: u32, c: u32 } {
        var g = Graph.init(allocator, test_config);
        const a = g.addNode(.{ .x = 100, .y = 100 }, false) catch unreachable;
        const b = g.addNode(.{ .x = 100, .y = 200 }, false) catch unreachable;
        const c = g.addNode(.{ .x = 100, .y = 300 }, false) catch unreachable;
        return .{ .graph = g, .a = a, .b = b, .c = c };
    }

    /// A -- B -- C -- D linear chain on same X axis.
    fn linear4(allocator: std.mem.Allocator) struct { graph: Graph, a: u32, b: u32, c: u32, d: u32 } {
        var g = Graph.init(allocator, test_config);
        const a = g.addNode(.{ .x = 100, .y = 100 }, false) catch unreachable;
        const b = g.addNode(.{ .x = 100, .y = 200 }, false) catch unreachable;
        const c = g.addNode(.{ .x = 100, .y = 300 }, false) catch unreachable;
        const d = g.addNode(.{ .x = 100, .y = 400 }, false) catch unreachable;
        return .{ .graph = g, .a = a, .b = b, .c = c, .d = d };
    }

    /// Two disconnected nodes on different X axes (no path between them).
    fn disconnected2(allocator: std.mem.Allocator) struct { graph: Graph, a: u32, b: u32 } {
        var g = Graph.init(allocator, test_config);
        const a = g.addNode(.{ .x = 100, .y = 100 }, false) catch unreachable;
        const b = g.addNode(.{ .x = 300, .y = 100 }, false) catch unreachable;
        return .{ .graph = g, .a = a, .b = b };
    }

    /// Two-floor stair graph: A--B(stair)--C(stair)--D
    fn twoFloorStair(allocator: std.mem.Allocator) struct { graph: Graph, a: u32, b: u32, c: u32, d: u32 } {
        var g = Graph.init(allocator, test_config);
        const a = g.addNode(.{ .x = 100, .y = 100 }, false) catch unreachable;
        const b = g.addNode(.{ .x = 100, .y = 300 }, true) catch unreachable;
        const c = g.addNode(.{ .x = 200, .y = 300 }, true) catch unreachable;
        const d = g.addNode(.{ .x = 200, .y = 450 }, false) catch unreachable;
        return .{ .graph = g, .a = a, .b = b, .c = c, .d = d };
    }
};

pub const FloydWarshallSpec = struct {
    pub const shortest_path = struct {
        test "computes distances for linear graph" {
            var setup = GraphFactory.linear3(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getDistance(setup.a, setup.b), 100.0);
            try expect.equal(fw.getDistance(setup.a, setup.c), 200.0);
            try expect.equal(fw.getDistance(setup.b, setup.c), 100.0);
        }

        test "reconstructs path in correct sequence" {
            var setup = GraphFactory.linear3(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            const path = (try fw.getPath(std.testing.allocator, setup.a, setup.c)).?;
            defer std.testing.allocator.free(path);

            try expect.equal(path.len, 3);
            try expect.equal(path[0], setup.a);
            try expect.equal(path[1], setup.b);
            try expect.equal(path[2], setup.c);
        }

        test "next hop gives first step toward goal" {
            var setup = GraphFactory.linear3(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getNextHop(setup.a, setup.c).?, setup.b);
            try expect.equal(fw.getNextHop(setup.b, setup.a).?, setup.a);
            try expect.equal(fw.getNextHop(setup.a, setup.b).?, setup.b);
        }
    };

    pub const unreachable_nodes = struct {
        test "returns inf distance for disconnected nodes" {
            var setup = GraphFactory.disconnected2(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getDistance(setup.a, setup.b), INF);
        }

        test "returns null next hop for disconnected nodes" {
            var setup = GraphFactory.disconnected2(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.toBeNull(fw.getNextHop(setup.a, setup.b));
        }

        test "getPath returns null without leaking for disconnected nodes" {
            // std.testing.allocator detects leaks — this test verifies
            // that getPath properly frees internal state on null return.
            var setup = GraphFactory.disconnected2(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            const path = try fw.getPath(std.testing.allocator, setup.a, setup.b);
            try expect.toBeNull(path);
        }

        test "getPath returns null without leaking after node removal breaks bridge" {
            // Regression: removing the bridge node between A and C makes them
            // unreachable. getPath must return null and free any partial state.
            var setup = GraphFactory.linear3(std.testing.allocator);
            defer setup.graph.deinit();

            setup.graph.removeNode(setup.b);

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getDistance(setup.a, setup.c), INF);

            const path = try fw.getPath(std.testing.allocator, setup.a, setup.c);
            try expect.toBeNull(path);
        }
    };

    pub const self_path = struct {
        test "self-distance is zero" {
            var g = Graph.init(std.testing.allocator, test_config);
            defer g.deinit();

            const a = try g.addNode(.{ .x = 100, .y = 100 }, false);

            var fw = try FloydWarshall.build(std.testing.allocator, &g);
            defer fw.deinit();

            try expect.equal(fw.getDistance(a, a), 0.0);
        }

        test "self-path returns single-element slice" {
            var g = Graph.init(std.testing.allocator, test_config);
            defer g.deinit();

            const a = try g.addNode(.{ .x = 100, .y = 100 }, false);

            var fw = try FloydWarshall.build(std.testing.allocator, &g);
            defer fw.deinit();

            const path = (try fw.getPath(std.testing.allocator, a, a)).?;
            defer std.testing.allocator.free(path);

            try expect.equal(path.len, 1);
            try expect.equal(path[0], a);
        }
    };

    pub const stair_connections = struct {
        test "finds path across floors via stair nodes" {
            var setup = GraphFactory.twoFloorStair(std.testing.allocator);
            defer setup.graph.deinit();

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            const path = (try fw.getPath(std.testing.allocator, setup.a, setup.d)).?;
            defer std.testing.allocator.free(path);

            try expect.equal(path.len, 4);
            try expect.equal(path[0], setup.a);
            try expect.equal(path[1], setup.b);
            try expect.equal(path[2], setup.c);
            try expect.equal(path[3], setup.d);

            // A-B=200, B-C=100, C-D=150 = 450
            try expect.equal(fw.getDistance(setup.a, setup.d), 450.0);
        }
    };

    pub const tombstones = struct {
        test "removed nodes are excluded from paths" {
            var setup = GraphFactory.linear3(std.testing.allocator);
            defer setup.graph.deinit();

            setup.graph.removeNode(setup.b);

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getDistance(setup.a, setup.c), INF);
            try expect.toBeNull(fw.getNextHop(setup.a, setup.c));
        }

        test "remaining nodes still connected after unrelated removal" {
            var setup = GraphFactory.linear4(std.testing.allocator);
            defer setup.graph.deinit();

            // Remove node D — A-B-C chain should still work
            setup.graph.removeNode(setup.d);

            var fw = try FloydWarshall.build(std.testing.allocator, &setup.graph);
            defer fw.deinit();

            try expect.equal(fw.getDistance(setup.a, setup.c), 200.0);

            const path = (try fw.getPath(std.testing.allocator, setup.a, setup.c)).?;
            defer std.testing.allocator.free(path);

            try expect.equal(path.len, 3);
        }
    };
};
