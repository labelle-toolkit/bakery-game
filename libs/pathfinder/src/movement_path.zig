const types = @import("types.zig");
const NodeId = types.NodeId;
const Vec2 = types.Vec2;

/// Component set on an entity while it is navigating.
/// Managed internally by the pathfinder — the game reads it but
/// may modify `speed` at runtime (e.g. slow down when carrying heavy items).
pub const MovementPath = struct {
    /// Full sequence of world positions from start to goal.
    positions: []const Vec2,
    /// Index of the waypoint the entity is currently moving toward.
    current_index: u32 = 0,
    /// Total number of waypoints.
    len: u32,
    /// Movement speed (world units per second).
    /// Set at navigate() time, but the game can modify it at any point.
    /// The pathfinder reads this value each tick, so changes take effect immediately.
    speed: f32,
    /// Goal node ID (for the game to identify the destination).
    goal_node: NodeId,
};
