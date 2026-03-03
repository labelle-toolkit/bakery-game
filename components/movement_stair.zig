// MovementStair component
//
// Marker component placed alongside MovementNode on stair waypoints.
// When present, the pathfinder connects this node horizontally (same Y axis)
// to other stair nodes, enabling cross-axis navigation.

/// Marker: this MovementNode is a stair connection point.
pub const MovementStair = struct {
    _marker: u8 = 0,
};
