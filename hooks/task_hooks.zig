// Task hooks for the bakery game
//
// These hooks are automatically detected by the generator and wired up
// to the TaskEngine. Each hook fires when the corresponding task step begins.

const std = @import("std");
const tasks = @import("labelle_tasks");
const items = @import("../components/items.zig");

const HookPayload = tasks.hooks.HookPayload(u32, items.ItemType);

// Import movement script for pathfinding control
const movement = @import("../scripts/movement.zig");

// Global state for visual feedback
pub var last_event: []const u8 = "Waiting for activity...";
pub var pickup_count: u32 = 0;
pub var process_count: u32 = 0;
pub var store_count: u32 = 0;
pub var bread_produced: u32 = 0;

/// Called when a worker starts picking up ingredients from storage
pub fn pickup_started(payload: HookPayload) void {
    const info = payload.pickup_started;
    pickup_count += 1;
    last_event = "Baker walking to pantry...";

    // Move baker to pantry
    movement.sendToStation(info.worker_id, movement.Stations.pantry);

    std.log.info("[BAKERY] Pickup started: baker={d} -> pantry", .{info.worker_id});
}

/// Called when a worker starts processing at the workstation
pub fn process_started(payload: HookPayload) void {
    const info = payload.process_started;
    process_count += 1;
    last_event = "Baker walking to oven...";

    // Move baker to oven
    movement.sendToStation(info.worker_id, movement.Stations.oven);

    std.log.info("[BAKERY] Processing: baker={d} -> oven", .{info.worker_id});
}

/// Called when a worker starts storing the output
pub fn store_started(payload: HookPayload) void {
    const info = payload.store_started;
    store_count += 1;
    last_event = "Baker carrying bread to shelf...";

    // Move baker to shelf
    movement.sendToStation(info.worker_id, movement.Stations.shelf);

    std.log.info("[BAKERY] Storing: baker={d} -> shelf", .{info.worker_id});
}

/// Called when a worker completes a task and is released
pub fn worker_released(payload: HookPayload) void {
    const info = payload.worker_released;
    bread_produced += 1;
    last_event = "Fresh bread ready! Baker returning to counter...";

    // Move baker back to counter
    movement.sendToStation(info.worker_id, movement.Stations.counter);

    std.log.info("[BAKERY] Cycle complete! baker={d} -> counter, total bread={d}", .{
        info.worker_id,
        bread_produced,
    });
}
