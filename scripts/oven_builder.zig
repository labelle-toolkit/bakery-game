// Oven workstation builder script
//
// Creates the oven workstation with all its storage entities (EIS, IIS, IOS, EOS)
// and registers it with the task engine.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.render.Position;
const Shape = engine.render.Shape;
const Text = engine.render.Text;
const Context = main.labelle_tasksContext;
const BoundTypes = main.labelle_tasksBindItems;
const Storage = BoundTypes.Storage;
const Workstation = BoundTypes.Workstation;
const Items = @import("../enums/items.zig").Items;

var oven_id: u64 = 0;
var flour_eis_id: u64 = 0;
var water_eis_id: u64 = 0;
var flour_iis_id: u64 = 0;
var water_iis_id: u64 = 0;
var bread_ios_id: u64 = 0;
var bread_eos_id: u64 = 0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("[OvenBuilder] Building oven workstation", .{});

    const registry = game.getRegistry();

    // Create the main oven entity (visual)
    const oven_entity = registry.create();
    oven_id = engine.entityToU64(oven_entity);

    registry.set(oven_entity, Position{ .x = 600, .y = 150 });
    registry.set(oven_entity, Shape{
        .shape = .{ .rectangle = .{ .width = 80, .height = 60 } },
        .color = .{ .r = 200, .g = 80, .b = 50, .a = 255 },
    });

    // Create label
    const label_entity = registry.create();
    game.setParent(label_entity, oven_entity) catch {};
    registry.set(label_entity, Position{ .x = 0, .y = -40 });
    registry.set(label_entity, Text{
        .text = "Oven",
        .size = 14,
        .color = .{ .r = 255, .g = 100, .b = 100, .a = 255 },
    });

    // Create EIS - Flour storage (external input - already exists in scene, use existing one)
    // We'll find the existing EIS entities and register them with the engine
    var existing_eis_view = registry.view(.{ Storage, Position });
    var eis_iter = existing_eis_view.entityIterator();

    while (eis_iter.next()) |entity| {
        const storage = existing_eis_view.get(Storage, entity);
        if (storage.role == .eis) {
            const id = engine.entityToU64(entity);
            if (storage.accepts == .Flour) {
                flour_eis_id = id;
            } else if (storage.accepts == .Water) {
                water_eis_id = id;
            }
        }
    }

    // Create IIS - Internal Flour slot (recipe input)
    const flour_iis_entity = registry.create();
    flour_iis_id = engine.entityToU64(flour_iis_entity);
    registry.set(flour_iis_entity, Position{ .x = 560, .y = 150 });
    registry.set(flour_iis_entity, Shape{
        .shape = .{ .rectangle = .{ .width = 30, .height = 30 } },
        .color = .{ .r = 150, .g = 200, .b = 150, .a = 255 },
    });
    registry.set(flour_iis_entity, Storage{
        .role = .iis,
        .accepts = Items.Flour,
    });

    // Create IIS - Internal Water slot (recipe input)
    const water_iis_entity = registry.create();
    water_iis_id = engine.entityToU64(water_iis_entity);
    registry.set(water_iis_entity, Position{ .x = 560, .y = 185 });
    registry.set(water_iis_entity, Shape{
        .shape = .{ .rectangle = .{ .width = 30, .height = 30 } },
        .color = .{ .r = 150, .g = 150, .b = 220, .a = 255 },
    });
    registry.set(water_iis_entity, Storage{
        .role = .iis,
        .accepts = Items.Water,
    });

    // Create IOS - Internal Output slot (produced Bread)
    const bread_ios_entity = registry.create();
    bread_ios_id = engine.entityToU64(bread_ios_entity);
    registry.set(bread_ios_entity, Position{ .x = 690, .y = 165 });
    registry.set(bread_ios_entity, Shape{
        .shape = .{ .rectangle = .{ .width = 30, .height = 30 } },
        .color = .{ .r = 220, .g = 180, .b = 100, .a = 255 },
    });
    registry.set(bread_ios_entity, Storage{
        .role = .ios,
        .accepts = Items.Bread,
    });

    // Create EOS - External Output storage (final Bread storage)
    const bread_eos_entity = registry.create();
    bread_eos_id = engine.entityToU64(bread_eos_entity);
    registry.set(bread_eos_entity, Position{ .x = 750, .y = 165 });
    registry.set(bread_eos_entity, Shape{
        .shape = .{ .rectangle = .{ .width = 40, .height = 40 } },
        .color = .{ .r = 180, .g = 140, .b = 80, .a = 255 },
    });
    registry.set(bread_eos_entity, Storage{
        .role = .eos,
        .accepts = Items.Bread,
    });

    // Create array of storage IDs
    const storage_ids = [_]u64{
        flour_eis_id,
        water_eis_id,
        flour_iis_id,
        water_iis_id,
        bread_ios_id,
        bread_eos_id,
    };

    // Add Workstation component to oven entity
    registry.set(oven_entity, Workstation{
        .process_duration = 120,
        .storages = &storage_ids,
    });

    // Register workstation with task engine
    Context.registerWorkstation(oven_id, &storage_ids, 120);

    std.log.info("[OvenBuilder] Created oven workstation {d} with 6 storages:", .{oven_id});
    std.log.info("[OvenBuilder]   EIS Flour: {d}", .{flour_eis_id});
    std.log.info("[OvenBuilder]   EIS Water: {d}", .{water_eis_id});
    std.log.info("[OvenBuilder]   IIS Flour: {d}", .{flour_iis_id});
    std.log.info("[OvenBuilder]   IIS Water: {d}", .{water_iis_id});
    std.log.info("[OvenBuilder]   IOS Bread: {d}", .{bread_ios_id});
    std.log.info("[OvenBuilder]   EOS Bread: {d}", .{bread_eos_id});
    std.log.info("[OvenBuilder] Registered workstation with task engine", .{});
}

pub fn deinit() void {
    std.log.info("[OvenBuilder] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
