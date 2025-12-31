// Storage component for task engine integration
//
// Defines storage configuration that can be used in prefabs.
// Uses onAdd callback to register the storage with the task engine.

const std = @import("std");
const engine = @import("labelle-engine");
const items = @import("items.zig");
const task_state = @import("task_state.zig");

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
    /// Item type this storage accepts (null = accepts any)
    accepts: ?ItemType = null,
    /// Whether this storage is standalone (not part of a workstation)
    /// Standalone storages are registered directly with task engine
    standalone: bool = false,

    /// Called automatically when Storage component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        const entity_id = payload.entity_id;
        std.log.warn("[Storage.onAdd] Entity {d} - storage added", .{entity_id});

        // Access the game and registry
        const game = payload.getGame(engine.Game);
        const registry = game.getRegistry();

        // Ensure task_state has access to the registry and game for position updates
        task_state.setRegistry(registry);
        task_state.setGame(game);

        // Get the Storage component
        const entity = engine.entityFromU64(entity_id);
        const storage = registry.tryGet(Storage, entity) orelse {
            std.log.err("[Storage.onAdd] Entity {d} - could not get Storage component", .{entity_id});
            return;
        };

        // Only register standalone storages here
        // Workstation-owned storages are registered by Workstation.onAdd
        if (storage.standalone) {
            // Convert StorageType to StorageRole
            const StorageRole = task_state.StorageRole;
            const role: StorageRole = switch (storage.storage_type) {
                .eis => .eis,
                .iis => .iis,
                .ios => .ios,
                .eos => .eos,
            };

            task_state.addStorage(entity_id, .{
                .role = role,
                .initial_item = storage.initial_item,
                .accepts = storage.accepts,
            }) catch |err| {
                std.log.err("[Storage.onAdd] Entity {d} - failed to add storage: {}", .{ entity_id, err });
                return;
            };

            std.log.info("[Storage.onAdd] Entity {d} - registered standalone storage: type={}, accepts={?}", .{
                entity_id,
                storage.storage_type,
                storage.accepts,
            });
        }
    }

    /// Called when Storage component is removed
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Storage.onRemove] Entity {d} - storage removed", .{payload.entity_id});
    }
};
