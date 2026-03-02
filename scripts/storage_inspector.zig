// Storage and Workstation inspector script
//
// Debug script that logs all workstation and storage entities on first update.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Workstation = main.Workstation;
const Storage = main.Storage;
const Eis = main.Eis;
const Iis = main.Iis;
const Ios = main.Ios;
const Eos = main.Eos;

var has_run = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;

    std.log.warn("[StorageInspector] Script initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

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
            const ws = view.get(entity);
            workstation_count += 1;
            std.log.warn("[StorageInspector] Workstation entity={any}, process_duration={d}", .{
                entity,
                ws.process_duration,
            });
        }
    }

    // Count storages by role marker
    var eis_count: u32 = 0;
    var iis_count: u32 = 0;
    var ios_count: u32 = 0;
    var eos_count: u32 = 0;
    {
        var view = registry.view(.{Storage});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            if (registry.tryGet(Eis, entity) != null) {
                eis_count += 1;
                std.log.warn("[StorageInspector] EIS entity={any}", .{entity});
            } else if (registry.tryGet(Iis, entity) != null) {
                iis_count += 1;
                std.log.warn("[StorageInspector] IIS entity={any}", .{entity});
            } else if (registry.tryGet(Ios, entity) != null) {
                ios_count += 1;
                std.log.warn("[StorageInspector] IOS entity={any}", .{entity});
            } else if (registry.tryGet(Eos, entity) != null) {
                eos_count += 1;
                std.log.warn("[StorageInspector] EOS entity={any}", .{entity});
            }
        }
    }

    std.log.warn("[StorageInspector] Total workstations: {d}", .{workstation_count});
    std.log.warn("[StorageInspector] Total storages - EIS:{d}, IIS:{d}, IOS:{d}, EOS:{d}", .{ eis_count, iis_count, ios_count, eos_count });
    std.log.warn("[StorageInspector] === Inspection Complete ===", .{});
}
