// Storage component for task engine integration
//
// Defines storage configuration that can be used in prefabs.
// Uses onAdd callback to log when storages are added to entities.

const std = @import("std");
const engine = @import("labelle-engine");
const items = @import("items.zig");

pub const ItemType = items.ItemType;

/// Storage type for task engine
pub const StorageType = enum {
    eis, // External Input Storage (e.g., pantry)
    iis, // Internal Input Storage (workstation input buffer)
    ios, // Internal Output Storage (workstation output buffer)
    eos, // External Output Storage (e.g., shelf)
};

/// Storage component - attach to entities to define task engine storages
/// The ECS entity ID will be used as the storage ID.
pub const Storage = struct {
    /// Type of storage (EIS, IIS, IOS, EOS)
    storage_type: StorageType,
    /// Initial item in storage (null = empty)
    initial_item: ?ItemType = null,

    /// Called automatically when Storage component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.warn("[Storage.onAdd] Entity {d} - storage added", .{payload.entity_id});
    }

    /// Called when Storage component is removed
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Storage.onRemove] Entity {d} - storage removed", .{payload.entity_id});
    }
};
