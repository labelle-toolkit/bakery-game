// MovementNode component
//
// Placed on waypoint entities in the scene. The pathfinder_bridge script
// populates `node_id` during init after registering the node with the
// pathfinder graph.

/// A navigation graph node. The entity's Position determines the node's
/// world coordinates; `node_id` is assigned at runtime by the pathfinder.
pub const MovementNode = struct {
    node_id: u32 = 0,
};
