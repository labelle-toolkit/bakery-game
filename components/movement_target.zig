// MovementTarget component
//
// When attached to a worker entity, the worker_movement script will
// move the entity towards the target position and perform the action
// when it arrives.

/// Action to perform when the worker arrives at the target
pub const Action = enum {
    pickup,
    store,
    pickup_dangling,
};

/// Component that directs a worker to move towards a target position
pub const MovementTarget = struct {
    target_x: f32,
    target_y: f32,
    speed: f32 = 60.0, // pixels per second
    action: Action,
};
