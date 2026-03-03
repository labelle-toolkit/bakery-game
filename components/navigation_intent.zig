// NavigationIntent component
//
// Replaces direct MovementTarget setting for long-distance navigation.
// The navigation_orchestrator script reads this component and manages
// the pathfinder → last-mile → arrival lifecycle.
//
// Flow: caller sets NavigationIntent → orchestrator starts pathfinder →
// pathfinder arrives at nearest node → orchestrator sets MovementTarget
// for last-mile → worker_movement handles arrival.

const movement_target = @import("movement_target.zig");

pub const NavigationIntent = struct {
    /// Entity to navigate to (storage, workstation, bed, or dangling item).
    target_entity: u64,
    /// What to do when we arrive (same enum as MovementTarget).
    action: movement_target.Action,
    /// Cached world position of target (for last-mile + fallback).
    target_x: f32,
    target_y: f32,
    /// Resolved closest node of target (0xFFFFFFFF = unresolved).
    target_node: u32 = 0xFFFFFFFF,
    /// Current state in the navigation lifecycle.
    state: State = .pending,

    pub const State = enum {
        /// Just set, needs pathfinder.navigate() call.
        pending,
        /// Pathfinder is actively moving entity node-to-node.
        navigating,
        /// Pathfinder arrived at target node, MovementTarget handles remaining.
        last_mile,
        /// No path found, falling back to straight-line MovementTarget.
        fallback_linear,
    };
};
