const types = @import("types.zig");
const NodeId = types.NodeId;

/// Navigation hook events dispatched by the pathfinder.
/// The game provides a hook struct with functions matching the tag names.
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
            /// The node the entity was nearest to when the path broke.
            current_node: NodeId,
            registry: ?*anyopaque,
        },
    };
}
