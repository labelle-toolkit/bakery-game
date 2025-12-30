// Task hooks for the bakery game
//
// Initializes the task engine on game_init and cleans up on game_deinit.
// Using game_init ensures the task engine is ready before the initial scene loads,
// so Workstation.onAdd can register workstations during entity creation.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("../components/task_state.zig");

/// Initialize task engine during game initialization
pub fn game_init(payload: engine.HookPayload) void {
    const info = payload.game_init;

    task_state.init(info.allocator) catch |err| {
        std.log.err("[TaskHooks] Failed to initialize task engine: {}", .{err});
        return;
    };

    std.log.info("[TaskHooks] game_init: task engine ready", .{});
}

/// Clean up task engine on game deinit
pub fn game_deinit(payload: engine.HookPayload) void {
    _ = payload;
    task_state.deinit();
    std.log.info("[TaskHooks] game_deinit: task engine cleaned up", .{});
}
