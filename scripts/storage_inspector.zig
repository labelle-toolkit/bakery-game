// Storage and Workstation inspector script
//
// This script queries for Storage and Workstation components and validates
// that the task engine integration is working correctly.

const std = @import("std");
const engine = @import("labelle-engine");
const labelle_tasks = @import("labelle-tasks");
const main = @import("../main.zig");
const items = @import("../enums/items.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Storage = labelle_tasks.Storage(items.ItemType);
const StorageRole = labelle_tasks.StorageRole;
const Workstation = labelle_tasks.Workstation(items.ItemType);
const Context = main.labelle_tasksContext;

var has_run = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;

    std.log.warn("[StorageInspector] Script initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    // Run once on first update
    if (has_run) return;
    has_run = true;

    std.log.warn("[StorageInspector] === Inspecting Entities ===", .{});

    const registry = game.getRegistry();

    // Count and log workstations
    var workstation_count: u32 = 0;
    {
        var view = registry.view(.{Workstation});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const ws = view.getConst(entity);
            workstation_count += 1;
            std.log.warn("[StorageInspector] Workstation entity={any}, process_duration={d}, storages={d}", .{
                entity,
                ws.process_duration,
                ws.storages.len,
            });
        }
    }

    // Count and log storages by type
    var eis_count: u32 = 0;
    var iis_count: u32 = 0;
    var ios_count: u32 = 0;
    var eos_count: u32 = 0;
    {
        var view = registry.view(.{Storage});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const storage = view.getConst(entity);

            switch (storage.role) {
                .eis => {
                    eis_count += 1;
                    std.log.warn("[StorageInspector] EIS entity={any}, initial_item={any}", .{ entity, storage.initial_item });
                },
                .iis => {
                    iis_count += 1;
                    std.log.warn("[StorageInspector] IIS entity={any}, initial_item={any}", .{ entity, storage.initial_item });
                },
                .ios => {
                    ios_count += 1;
                    std.log.warn("[StorageInspector] IOS entity={any}, initial_item={any}", .{ entity, storage.initial_item });
                },
                .eos => {
                    eos_count += 1;
                    std.log.warn("[StorageInspector] EOS entity={any}, initial_item={any}", .{ entity, storage.initial_item });
                },
            }
        }
    }

    std.log.warn("[StorageInspector] Total workstations: {d}", .{workstation_count});
    std.log.warn("[StorageInspector] Total storages - EIS:{d}, IIS:{d}, IOS:{d}, EOS:{d}", .{ eis_count, iis_count, ios_count, eos_count });

    // Validate task engine integration
    if (Context.getEngine()) |_| {
        std.log.info("[StorageInspector] PASS: Task engine is initialized", .{});

        // Validate by checking a workstation's status in the task engine
        if (workstation_count > 0) {
            var view = registry.view(.{Workstation});
            var iter = view.entityIterator();
            if (iter.next()) |entity| {
                const ws_id = engine.entityToU64(entity);
                if (Context.getEngine()) |task_engine| {
                    if (task_engine.getWorkstationStatus(ws_id)) |status| {
                        std.log.info("[StorageInspector] PASS: Workstation {d} registered with status={any}", .{ ws_id, status });
                    } else {
                        std.log.err("[StorageInspector] FAIL: Workstation {d} not found in task engine", .{ws_id});
                    }
                }
            }
        }
    } else {
        std.log.err("[StorageInspector] FAIL: Task engine not initialized!", .{});
    }

    std.log.warn("[StorageInspector] === Inspection Complete ===", .{});
}
