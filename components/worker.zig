// Worker component
//
// Attach to entities that can perform tasks (e.g., bakers, farmers, craftsmen).
// Uses onAdd callback to register the worker with the task engine.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("task_state.zig");

/// Worker component - attach to entities that perform tasks
pub const Worker = struct {
    /// Called automatically when Worker component is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        const entity_id = payload.entity_id;
        std.log.warn("[Worker.onAdd] Entity {d} - worker component attached", .{entity_id});

        // Access the game and registry
        const game = payload.getGame(engine.Game);
        const registry = game.getRegistry();

        // Ensure task_state has access to the registry and game for position updates
        task_state.setRegistry(registry);
        task_state.setGame(game);

        // Register worker with task engine
        task_state.addWorker(entity_id) catch |err| {
            std.log.err("[Worker.onAdd] Entity {d} - failed to add worker: {}", .{ entity_id, err });
            return;
        };

        // Make worker available immediately
        if (task_state.getEngine()) |task_eng| {
            _ = task_eng.workerAvailable(entity_id);
        }

        std.log.info("[Worker.onAdd] Entity {d} - registered and available", .{entity_id});
    }

    /// Called when Worker component is removed from an entity
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Worker.onRemove] Entity {d} - worker removed", .{payload.entity_id});
    }
};
