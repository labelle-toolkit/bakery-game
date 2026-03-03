const std = @import("std");
const pathfinder = @import("pathfinder");

const Graph = pathfinder.Graph;
const Config = pathfinder.Config;

const test_config = Config{
    .max_connection_distance = 200.0,
    .max_stair_distance = 150.0,
    .axis_tolerance = 1.0,
};

// --- Initialization ---

test "starts with zero nodes" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    try std.testing.expectEqual(@as(u32, 0), g.nodeCount());
}

test "starts dirty" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    try std.testing.expect(g.dirty);
}

// --- addNode ---

test "addNode returns incrementing NodeIds" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const id0 = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const id1 = try g.addNode(.{ .x = 200, .y = 200 }, false);
    const id2 = try g.addNode(.{ .x = 300, .y = 300 }, false);

    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(u32, 3), g.nodeCount());
}

test "nodes on same X axis connect automatically" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two nodes on same X=100, Y differs by 100 (within max_connection_distance=200)
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);

    // a should have edge to b
    const a_edges = g.getEdges(a);
    try std.testing.expectEqual(@as(usize, 1), a_edges.len);
    try std.testing.expectEqual(b, a_edges[0].to);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), a_edges[0].cost, 0.01);

    // b should have edge to a
    const b_edges = g.getEdges(b);
    try std.testing.expectEqual(@as(usize, 1), b_edges.len);
    try std.testing.expectEqual(a, b_edges[0].to);
}

test "nodes on different X axes do not connect" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try g.addNode(.{ .x = 250, .y = 100 }, false);

    // a should have no edges (different X, same Y doesn't connect for non-stair)
    try std.testing.expectEqual(@as(usize, 0), g.getEdges(a).len);
}

test "nearest neighbor only — no skip connections" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Three nodes on same X=100: A at y=100, B at y=200, C at y=300
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);
    const c = try g.addNode(.{ .x = 100, .y = 300 }, false);

    // A connects to B (nearest above)
    const a_edges = g.getEdges(a);
    try std.testing.expectEqual(@as(usize, 1), a_edges.len);
    try std.testing.expectEqual(b, a_edges[0].to);

    // B connects to A (below) and C (above)
    const b_edges = g.getEdges(b);
    try std.testing.expectEqual(@as(usize, 2), b_edges.len);

    // C connects to B only (nearest below), NOT to A
    const c_edges = g.getEdges(c);
    try std.testing.expectEqual(@as(usize, 1), c_edges.len);
    try std.testing.expectEqual(b, c_edges[0].to);
}

test "does not connect beyond max_connection_distance" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two nodes on same X but 250 apart (exceeds max_connection_distance=200)
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try g.addNode(.{ .x = 100, .y = 350 }, false);

    try std.testing.expectEqual(@as(usize, 0), g.getEdges(a).len);
}

test "axis_tolerance allows near-matches" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Nodes at x=100 and x=100.5 (within tolerance=1.0)
    const a = try g.addNode(.{ .x = 100.0, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100.5, .y = 200 }, false);

    const a_edges = g.getEdges(a);
    try std.testing.expectEqual(@as(usize, 1), a_edges.len);
    try std.testing.expectEqual(b, a_edges[0].to);
}

test "sets dirty flag on addNode" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    g.dirty = false;
    _ = try g.addNode(.{ .x = 100, .y = 100 }, false);
    try std.testing.expect(g.dirty);
}

test "edge re-evaluation when inserting between connected nodes" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // A at y=100, B at y=200 — they connect
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);

    // Verify A-B connected
    try std.testing.expectEqual(@as(usize, 1), g.getEdges(a).len);
    try std.testing.expectEqual(@as(usize, 1), g.getEdges(b).len);

    // Insert C at y=150 (between A and B)
    const c = try g.addNode(.{ .x = 100, .y = 150 }, false);

    // Now A should connect to C (nearest above), NOT B
    const a_edges = g.getEdges(a);
    try std.testing.expectEqual(@as(usize, 1), a_edges.len);
    try std.testing.expectEqual(c, a_edges[0].to);

    // C should connect to both A (below) and B (above)
    const c_edges = g.getEdges(c);
    try std.testing.expectEqual(@as(usize, 2), c_edges.len);

    // B should connect to C only, NOT A
    const b_edges = g.getEdges(b);
    try std.testing.expectEqual(@as(usize, 1), b_edges.len);
    try std.testing.expectEqual(c, b_edges[0].to);
}

// --- Stairs ---

test "stair nodes on same Y axis connect" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two stair nodes on same Y=300, X differs by 100
    const a = try g.addNode(.{ .x = 100, .y = 300 }, true);
    const b = try g.addNode(.{ .x = 200, .y = 300 }, true);

    // Should have Y-axis stair connection
    const a_edges = g.getEdges(a);
    try std.testing.expect(a_edges.len >= 1);

    var has_b = false;
    for (a_edges) |e| {
        if (e.to == b) has_b = true;
    }
    try std.testing.expect(has_b);
}

test "non-stair nodes on same Y do not connect" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two regular nodes on same Y=100, different X
    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try g.addNode(.{ .x = 200, .y = 100 }, false);

    // Should NOT connect (not stairs, different X)
    try std.testing.expectEqual(@as(usize, 0), g.getEdges(a).len);
}

test "stair connection respects max_stair_distance" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    // Two stair nodes on same Y but 200 apart (exceeds max_stair_distance=150)
    const a = try g.addNode(.{ .x = 100, .y = 300 }, true);
    _ = try g.addNode(.{ .x = 300, .y = 300 }, true);

    try std.testing.expectEqual(@as(usize, 0), g.getEdges(a).len);
}

test "mixed stair and non-stair on same Y only connects stairs" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const a = try g.addNode(.{ .x = 100, .y = 300 }, true); // stair
    _ = try g.addNode(.{ .x = 200, .y = 300 }, false); // NOT stair
    const c = try g.addNode(.{ .x = 180, .y = 300 }, true); // stair

    // A should connect to C (both stairs), not B
    const a_edges = g.getEdges(a);
    var has_c = false;
    for (a_edges) |e| {
        if (e.to == c) has_c = true;
    }
    try std.testing.expect(has_c);
}

// --- removeNode ---

test "removes edges when node is removed" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    const b = try g.addNode(.{ .x = 100, .y = 200 }, false);

    // Verify connected
    try std.testing.expectEqual(@as(usize, 1), g.getEdges(a).len);
    try std.testing.expectEqual(@as(usize, 1), g.getEdges(b).len);

    g.removeNode(a);

    // B should have no edges to A anymore
    try std.testing.expectEqual(@as(usize, 0), g.getEdges(b).len);
    // Node count decreases
    try std.testing.expectEqual(@as(u32, 1), g.nodeCount());
}

test "sets dirty flag on removeNode" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    _ = try g.addNode(.{ .x = 100, .y = 100 }, false);
    g.dirty = false;

    g.removeNode(0);
    try std.testing.expect(g.dirty);
}

test "removed node is skipped by addNode connections" {
    var g = Graph.init(std.testing.allocator, test_config);
    defer g.deinit();

    const a = try g.addNode(.{ .x = 100, .y = 100 }, false);
    _ = try g.addNode(.{ .x = 100, .y = 200 }, false);

    g.removeNode(a);

    // New node on same X should NOT connect to removed node
    const c = try g.addNode(.{ .x = 100, .y = 150 }, false);
    const c_edges = g.getEdges(c);

    for (c_edges) |e| {
        try std.testing.expect(e.to != a);
    }
}
