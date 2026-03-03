// Pathfinder hooks for the bakery game
//
// Game-specific pathfinder event handlers.
// Hook payloads include .entity (u64) and .goal_node (u32).
// Initially lightweight — just logging. Full game logic integration
// comes when worker_movement.zig is migrated to use pathfinder.

const std = @import("std");
const log = std.log.scoped(.pathfinder_hooks);

pub const PathfinderGameHooks = struct {
    /// Entity arrived at its final navigation destination.
    pub fn arrived(payload: anytype) void {
        log.info("arrived: entity={d} goal_node={d}", .{ payload.entity, payload.goal_node });
    }

    /// Entity's path was invalidated by a graph change.
    pub fn path_invalidated(payload: anytype) void {
        log.info("path_invalidated: entity={d} goal_node={d}", .{ payload.entity, payload.goal_node });
    }
};
