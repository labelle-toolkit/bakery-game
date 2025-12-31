// Worker component
//
// Attach to entities that can perform tasks (e.g., bakers, farmers, craftsmen).

const std = @import("std");
const engine = @import("labelle-engine");

/// Worker component - attach to entities that perform tasks
pub const Worker = struct {
    /// Unique ID for this worker
    id: u32 = 0,

    /// Called automatically when Worker component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.warn("[Worker.onAdd] Entity {d} - worker component attached", .{payload.entity_id});
    }

    /// Called when Worker component is removed from an entity
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Worker.onRemove] Entity {d} - worker removed", .{payload.entity_id});
    }
};
