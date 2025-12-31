// DanglingItem component for task engine integration
//
// A dangling item is an item that exists in the scene but is NOT stored in any storage.
// When added to an entity, it registers with the task engine which can then assign
// workers to pick it up and deliver it to an appropriate EIS.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("task_state.zig");
const items = @import("items.zig");

pub const ItemType = items.ItemType;

/// DanglingItem component - attach to entities representing loose items in the scene
/// The ECS entity ID will be used as the item ID.
pub const DanglingItem = struct {
    /// The type of item this represents
    item_type: ItemType,

    /// Called automatically when DanglingItem component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        const entity_id = payload.entity_id;

        // Access the game and registry to query component data
        const game = payload.getGame(engine.Game);
        const registry = game.getRegistry();

        // Ensure task_state has access to the registry for distance calculations
        task_state.setRegistry(registry);

        // Get the DanglingItem component to access the item type
        const entity = engine.entityFromU64(entity_id);
        const dangling = registry.tryGet(DanglingItem, entity) orelse {
            std.log.err("[DanglingItem.onAdd] Entity {d} - could not get DanglingItem component", .{entity_id});
            return;
        };

        // Register with task engine
        task_state.addDanglingItem(entity_id, dangling.item_type) catch |err| {
            std.log.err("[DanglingItem.onAdd] Entity {d} - failed to add dangling item: {}", .{ entity_id, err });
            return;
        };

        std.log.info("[DanglingItem.onAdd] Entity {d} - registered dangling item: {}", .{ entity_id, dangling.item_type });
    }

    /// Called when DanglingItem component is removed
    pub fn onRemove(payload: engine.ComponentPayload) void {
        const entity_id = payload.entity_id;

        // Unregister from task engine
        task_state.removeDanglingItem(entity_id);

        std.log.info("[DanglingItem.onRemove] Entity {d} - unregistered dangling item", .{entity_id});
    }
};
