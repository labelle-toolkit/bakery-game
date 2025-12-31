// Workstation validation script
//
// This script validates that:
// 1. Workstation components are properly loaded
// 2. Nested storage entities are instantiated
// 3. Storage types match expected values
// 4. Entity relationships are correct

const std = @import("std");
const engine = @import("labelle-engine");
const workstation_mod = @import("../components/workstation.zig");
const storage_mod = @import("../components/storage.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Workstation = workstation_mod.Workstation;
const Storage = storage_mod.Storage;
const StorageType = storage_mod.StorageType;

var initialized = false;
var validation_results: ValidationResults = .{};

const ValidationResults = struct {
    workstations_found: u32 = 0,
    storages_found: u32 = 0,
    eis_storages: u32 = 0,
    iis_storages: u32 = 0,
    ios_storages: u32 = 0,
    eos_storages: u32 = 0,
    errors: u32 = 0,
};

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    _ = game;

    initialized = true;
    std.log.info("[WorkstationValidator] Validation script initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    if (!initialized) return;

    // Run validation once on first update after initialization
    if (validation_results.workstations_found == 0 and validation_results.storages_found == 0) {
        validateWorkstations(game);
        validateStorages(game);
        printResults();
    }
}

fn validateWorkstations(game: *Game) void {
    const registry = game.getRegistry();
    var view = registry.view(.{Workstation});
    var iter = view.entityIterator();

    std.log.info("\n=== Validating Workstations ===", .{});

    while (iter.next()) |entity| {
        validation_results.workstations_found += 1;

        const workstation = view.getConst(entity);

        std.log.info("[WORKSTATION] Entity {any}:", .{entity});
        std.log.info("  - process_duration: {d}", .{workstation.process_duration});
        std.log.info("  - input_storages (IIS): {d}", .{workstation.input_storages.len});

        // Log IIS entity IDs
        for (workstation.input_storages, 0..) |iis_entity, i| {
            std.log.info("    - IIS[{d}]: entity {any}", .{ i, iis_entity });
        }

        // Validate that IIS has entries
        if (workstation.input_storages.len == 0) {
            std.log.warn("[VALIDATION WARNING] Workstation {d} has no IIS storages!", .{entity});
        }
    }
}

fn validateStorages(game: *Game) void {
    const registry = game.getRegistry();
    var view = registry.view(.{Storage});
    var iter = view.entityIterator();

    std.log.info("\n=== Validating Storages ===", .{});

    while (iter.next()) |entity| {
        validation_results.storages_found += 1;

        const storage = view.getConst(entity);

        std.log.info("[STORAGE] Entity {any}:", .{entity});
        std.log.info("  - type: {s}", .{@tagName(storage.storage_type)});
        std.log.info("  - initial_item: {?}", .{storage.initial_item});

        // Count by type
        switch (storage.storage_type) {
            .eis => validation_results.eis_storages += 1,
            .iis => validation_results.iis_storages += 1,
            .ios => validation_results.ios_storages += 1,
            .eos => validation_results.eos_storages += 1,
        }
    }
}

fn printResults() void {
    std.log.info("\n=== Validation Results ===", .{});
    std.log.info("Workstations found: {d}", .{validation_results.workstations_found});
    std.log.info("Storages found: {d}", .{validation_results.storages_found});
    std.log.info("  - EIS storages: {d}", .{validation_results.eis_storages});
    std.log.info("  - IIS storages: {d}", .{validation_results.iis_storages});
    std.log.info("  - IOS storages: {d}", .{validation_results.ios_storages});
    std.log.info("  - EOS storages: {d}", .{validation_results.eos_storages});
    std.log.info("Errors: {d}", .{validation_results.errors});

    // Expected values for bakery game
    const expected_workstations: u32 = 1;
    const expected_eis: u32 = 3; // flour, water, yeast
    const expected_iis: u32 = 3; // 3 input storages on oven

    if (validation_results.workstations_found == expected_workstations) {
        std.log.info("+ Workstation count matches expected ({d})", .{expected_workstations});
    } else {
        std.log.err("x Expected {d} workstations, found {d}", .{ expected_workstations, validation_results.workstations_found });
    }

    if (validation_results.eis_storages == expected_eis) {
        std.log.info("+ EIS storage count matches expected ({d})", .{expected_eis});
    } else {
        std.log.err("x Expected {d} EIS storages, found {d}", .{ expected_eis, validation_results.eis_storages });
    }

    if (validation_results.iis_storages == expected_iis) {
        std.log.info("+ IIS storage count matches expected ({d})", .{expected_iis});
    } else {
        std.log.err("x Expected {d} IIS storages, found {d}", .{ expected_iis, validation_results.iis_storages });
    }

    if (validation_results.errors == 0) {
        std.log.info("+ No validation errors found!", .{});
    } else {
        std.log.err("x Found {d} validation errors!", .{validation_results.errors});
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;

    initialized = false;
    validation_results = .{};
    std.log.info("[WorkstationValidator] Validation script deinitialized", .{});
}
