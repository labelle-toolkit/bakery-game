// Delivery cycle validation script
//
// Validates that the dangling item delivery cycle completes:
// 1. Worker picks up dangling item
// 2. Worker delivers to EIS
// 3. EIS receives item
// 4. Worker becomes idle

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("../components/task_state.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Worker = task_state.Worker;
const DanglingItem = task_state.DanglingItem;
const Storage = task_state.Storage;

var frame_count: u32 = 0;
var test_passed: bool = false;
var test_failed: bool = false;
var initial_worker_id: ?u64 = null;
var initial_dangling_id: ?u64 = null;
var initial_eis_id: ?u64 = null;
var eis_was_empty: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("[DeliveryValidator] Starting delivery cycle validation", .{});

    const registry = game.getRegistry();

    // Find worker
    {
        var view = registry.view(.{Worker});
        var iter = view.entityIterator();
        if (iter.next()) |entity| {
            initial_worker_id = engine.entityToU64(entity);
            std.log.info("[DeliveryValidator] Found worker: {d}", .{initial_worker_id.?});
        }
    }

    // Find dangling item
    {
        var view = registry.view(.{DanglingItem});
        var iter = view.entityIterator();
        if (iter.next()) |entity| {
            initial_dangling_id = engine.entityToU64(entity);
            std.log.info("[DeliveryValidator] Found dangling item: {d}", .{initial_dangling_id.?});
        }
    }

    // Find standalone EIS that accepts Flour
    {
        var view = registry.view(.{Storage});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const storage = view.getConst(entity);
            if (storage.role == .eis and storage.accepts == .Flour) {
                initial_eis_id = engine.entityToU64(entity);
                // Check if EIS is empty (it should be for this test)
                if (storage.initial_item == null) {
                    eis_was_empty = true;
                }
                std.log.info("[DeliveryValidator] Found target EIS: {d}, initially empty: {}", .{ initial_eis_id.?, eis_was_empty });
                break;
            }
        }
    }

    if (initial_worker_id == null or initial_dangling_id == null or initial_eis_id == null) {
        std.log.err("[DeliveryValidator] FAIL: Missing entities for test", .{});
        test_failed = true;
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    if (test_passed or test_failed) return;

    frame_count += 1;

    // Give it up to 500 frames (~8 seconds at 60fps) to complete
    if (frame_count > 500) {
        std.log.err("[DeliveryValidator] FAIL: Delivery cycle did not complete in time", .{});
        test_failed = true;
        return;
    }

    // Check every 10 frames
    if (frame_count % 10 != 0) return;

    const task_eng = task_state.getEngine() orelse return;
    const eis_id = initial_eis_id orelse return;

    // Check delivery state
    const eis_has_item = task_eng.getStorageHasItem(eis_id);
    const dangling_id = initial_dangling_id orelse return;
    const dangling_still_tracked = task_eng.getDanglingItemType(dangling_id) != null;

    std.log.info("[DeliveryValidator] Frame {d}: eis_has_item={?}, dangling_tracked={}", .{
        frame_count,
        eis_has_item,
        dangling_still_tracked,
    });

    // Success condition: EIS was empty, now has item, and dangling item is no longer tracked
    if (eis_was_empty and eis_has_item == true and !dangling_still_tracked) {
        std.log.info("[DeliveryValidator] PASS: Delivery cycle completed successfully!", .{});
        std.log.info("[DeliveryValidator]   - EIS {d} received the item (was empty: {})", .{ eis_id, eis_was_empty });
        std.log.info("[DeliveryValidator]   - Dangling item {d} removed from tracking", .{dangling_id});
        test_passed = true;

        // Exit the game after successful validation
        game.quit();
    }
}

pub fn deinit() void {
    if (test_passed) {
        std.log.info("[DeliveryValidator] Test result: PASS", .{});
    } else if (test_failed) {
        std.log.err("[DeliveryValidator] Test result: FAIL", .{});
    } else {
        std.log.warn("[DeliveryValidator] Test result: INCOMPLETE", .{});
    }
}
