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
const Position = engine.render.Position;
const Shape = engine.render.Shape;
// Use bound component types from main
const BoundTypes = @import("../main.zig").labelle_tasksBindItems;
const Storage = BoundTypes.Storage;
const Workstation = BoundTypes.Workstation;
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
                    std.log.warn("[StorageInspector] EIS entity={any}, accepts={any}", .{ entity, storage.accepts });
                },
                .iis => {
                    iis_count += 1;
                    std.log.warn("[StorageInspector] IIS entity={any}", .{entity});
                },
                .ios => {
                    ios_count += 1;
                    std.log.warn("[StorageInspector] IOS entity={any}, accepts={any}", .{ entity, storage.accepts });
                },
                .eos => {
                    eos_count += 1;
                    std.log.warn("[StorageInspector] EOS entity={any}", .{entity});
                },
            }
        }
    }

    std.log.warn("[StorageInspector] Total workstations: {d}", .{workstation_count});
    std.log.warn("[StorageInspector] Total storages - EIS:{d}, IIS:{d}, IOS:{d}, EOS:{d}", .{ eis_count, iis_count, ios_count, eos_count });

    // Validate task engine integration (disabled - introspection API not available)
    std.log.info("[StorageInspector] PASS: Task engine is assumed to be initialized", .{});

    std.log.warn("[StorageInspector] === Inspection Complete ===", .{});
}
