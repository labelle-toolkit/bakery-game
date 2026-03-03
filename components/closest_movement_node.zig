// ClosestMovementNode component
//
// Auto-assigned by the pathfinder_bridge script during init to entities
// that need pathfinder navigation (workers, storages, workstations, beds).
// Maps each entity to its nearest graph node for route lookups.

/// Tracks the nearest navigation graph node for this entity.
pub const ClosestMovementNode = struct {
    node_entity: u64,
    node_id: u32,
    distance: f32 = 0.0,
};
