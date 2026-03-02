// Workstation gizmos script
// Draws lines between workstations and their storages

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Color = engine.Color;

const Workstation = main.Workstation;
const Storage = main.Storage;
const Eis = main.Eis;
const Iis = main.Iis;
const Ios = main.Ios;
const Eos = main.Eos;

var gizmo_drawn: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    const registry = game.getRegistry();

    var ws_count: usize = 0;
    var ws_view = registry.view(.{ Workstation, Position });
    var ws_iter = ws_view.entityIterator();
    while (ws_iter.next()) |_| {
        ws_count += 1;
    }
    std.log.info("[WorkstationGizmos] Script initialized, found {} workstations", .{ws_count});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const registry = game.getRegistry();

    var ws_view = registry.view(.{ Workstation, Position });
    var ws_iter = ws_view.entityIterator();

    while (ws_iter.next()) |ws_entity| {
        const ws = ws_view.get(Workstation, ws_entity);
        const ws_pos = ws_view.get(Position, ws_entity);

        if (!gizmo_drawn) {
            std.log.info("[WorkstationGizmos] Drawing lines for workstation at ({d:.0}, {d:.0}) with {} storages", .{ ws_pos.x, ws_pos.y, ws.storages.len });
        }

        for (ws.storages) |storage_entity| {
            if (registry.tryGet(Position, storage_entity)) |storage_pos| {
                // Color based on storage role marker
                const color: Color = if (registry.tryGet(Eis, storage_entity) != null)
                    Color{ .r = 100, .g = 200, .b = 100, .a = 255 } // green
                else if (registry.tryGet(Iis, storage_entity) != null)
                    Color{ .r = 150, .g = 220, .b = 150, .a = 255 } // light green
                else if (registry.tryGet(Ios, storage_entity) != null)
                    Color{ .r = 220, .g = 180, .b = 100, .a = 255 } // orange
                else if (registry.tryGet(Eos, storage_entity) != null)
                    Color{ .r = 200, .g = 140, .b = 80, .a = 255 } // brown
                else
                    Color{ .r = 128, .g = 128, .b = 128, .a = 255 }; // gray fallback

                game.gizmos.drawLine(ws_pos.x, ws_pos.y, storage_pos.x, storage_pos.y, color);
            }
        }
    }

    if (!gizmo_drawn) {
        gizmo_drawn = true;
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.log.info("[WorkstationGizmos] Script deinitialized", .{});
}
