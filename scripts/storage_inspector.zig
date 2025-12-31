// Storage inspector script
//
// This script queries for Storage components and logs their details

const std = @import("std");
const engine = @import("labelle-engine");
const storage_mod = @import("../components/storage.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Storage = storage_mod.Storage;
const StorageType = storage_mod.StorageType;

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

    // Query for storages
    const registry = game.getRegistry();

    // Count and log storages by type
    {
        var view = registry.view(.{Storage});
        var iter = view.entityIterator();
        var eis_count: u32 = 0;
        var iis_count: u32 = 0;
        var ios_count: u32 = 0;
        var eos_count: u32 = 0;

        while (iter.next()) |entity| {
            const storage = view.getConst(entity);

            switch (storage.storage_type) {
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

        std.log.warn("[StorageInspector] Total storages - EIS:{d}, IIS:{d}, IOS:{d}, EOS:{d}", .{ eis_count, iis_count, ios_count, eos_count });
    }

    std.log.warn("[StorageInspector] === Inspection Complete ===", .{});
}
