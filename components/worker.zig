// Worker component for task engine integration
//
// Attach to entities that can perform tasks (e.g., bakers, farmers, craftsmen).
// The worker is already registered with the task engine in scene_before_load.
// This component just associates the entity with a worker ID.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("task_state.zig");

/// Worker component - attach to entities to define task engine workers
pub const Worker = struct {
    /// Unique ID for this worker (used by task engine)
    id: u32,

    /// Called automatically when Worker component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        // Task engine temporarily disabled
        std.log.warn("[Worker.onAdd] Entity {d} - worker component attached", .{payload.entity_id});
    }

    /// Called when Worker component is removed from an entity
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Worker.onRemove] Entity {d} - worker removed", .{payload.entity_id});
    }
};
