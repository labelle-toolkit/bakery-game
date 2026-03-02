// Save/Load System
//
// Press F5 to save game state, F9 to load.
// Saves to savegame.json in the working directory.

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.Position;
const Shape = engine.Shape;

const Worker = main.Worker;
const Workstation = main.Workstation;
const Eis = main.Eis;
const Iis = main.Iis;
const Ios = main.Ios;
const Eos = main.Eos;
const Item = main.Item;
const Items = main.Items;
const Stored = main.Stored;
const Locked = main.Locked;
const WithItem = main.WithItem;
const WorkingOn = main.WorkingOn;
const Delivering = main.Delivering;
const MovementTarget = main.MovementTarget;
const WorkProgress = main.WorkProgress;
const CurrentTask = main.CurrentTask;
const TaskComplete = main.TaskComplete;
const ReadyToWork = main.ReadyToWork;
const FilledNeed = main.FilledNeed;
const Storage = main.Storage;

const production_system = @import("production_system.zig");

const SAVE_FILE = "savegame.json";
const MAX_SCENE_ENTITIES = 64;
const MAX_DYNAMIC_ENTITIES = 128;

/// Components persisted across save/load (all non-zero-size).
/// Zero-size markers (Worker, ReadyToWork) are omitted — they come from
/// prefabs or are re-derived by the production system.
const SaveableComponents = .{
    Item,
    Stored,
    Locked,
    WithItem,
    Storage,
    Eis,
    Iis,
    Ios,
    Eos,
    WorkingOn,
    Delivering,
    CurrentTask,
    FilledNeed,
    Workstation,
};

/// Transient components stripped on load (all non-zero-size).
/// TaskComplete is zero-size — omitted, harmless if present.
const TransientComponents = .{
    MovementTarget,
    WorkProgress,
};

var script_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

// ─── Auto-test state ────────────────────────────────────────────────────────

const AutoTestPhase = enum { waiting, saving, corrupting, loading, validating, done };
const AUTO_TEST_DELAY: f32 = 8.0; // seconds before auto-test starts

var auto_test: bool = false;
var auto_test_phase: AutoTestPhase = .waiting;
var elapsed: f32 = 0;

const MAX_SNAPSHOTS = 32;
const Snapshot = struct { x: f32, y: f32 };
var position_snapshots: [MAX_SNAPSHOTS]Snapshot = undefined;
var snapshot_count: usize = 0;

// ─── Public Script Interface ────────────────────────────────────────────────

pub fn init(game: *Game, _: *Scene) void {
    script_allocator = game.allocator;
    initialized = true;
    elapsed = 0;

    // Enable auto-test via SAVE_TEST env var
    auto_test = std.posix.getenv("SAVE_TEST") != null;
    if (auto_test) {
        auto_test_phase = .waiting;
        std.log.info("[SaveLoad] Auto-test enabled, will trigger after {d:.0}s", .{AUTO_TEST_DELAY});
    }
}

pub fn deinit() void {
    std.log.info("[SaveLoad] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    if (!initialized) return;

    // Auto-test mode
    if (auto_test) {
        elapsed += dt;
        runAutoTest(game, scene);
        return;
    }

    // Manual mode: F5 save, F9 load
    const input = game.getInput();

    if (input.isKeyPressed(.six)) {
        std.log.info("[SaveLoad] Saving game state...", .{});
        saveState(scene, game) catch |err| {
            std.log.err("[SaveLoad] Save failed: {}", .{err});
            return;
        };
        std.log.info("[SaveLoad] Game saved to {s}", .{SAVE_FILE});
    }

    if (input.isKeyPressed(.seven)) {
        std.log.info("[SaveLoad] Loading game state...", .{});
        loadState(scene, game) catch |err| {
            std.log.err("[SaveLoad] Load failed: {}", .{err});
            return;
        };
        std.log.info("[SaveLoad] Game loaded from {s}", .{SAVE_FILE});
    }
}

fn runAutoTest(game: *Game, scene: *Scene) void {
    const registry = game.getRegistry();

    switch (auto_test_phase) {
        .waiting => {
            if (elapsed >= AUTO_TEST_DELAY) {
                std.log.info("[SaveLoad] === AUTO-TEST: Starting at T={d:.2}s ===", .{elapsed});
                auto_test_phase = .saving;
            }
        },
        .saving => {
            // Capture position snapshots
            snapshot_count = 0;
            for (scene.entities.items) |ei| {
                if (snapshot_count >= MAX_SNAPSHOTS) break;
                if (registry.getComponent(ei.entity, Position)) |pos| {
                    position_snapshots[snapshot_count] = .{ .x = pos.x, .y = pos.y };
                } else {
                    position_snapshots[snapshot_count] = .{ .x = -1, .y = -1 };
                }
                snapshot_count += 1;
            }

            // Count items
            var item_count: usize = 0;
            var item_view = registry.view(.{Item});
            var item_iter = item_view.entityIterator();
            while (item_iter.next()) |_| item_count += 1;

            std.log.info("[SaveLoad] Snapshot: {d} scene entities, {d} items total", .{ snapshot_count, item_count });

            saveState(scene, game) catch |err| {
                std.log.err("[SaveLoad] AUTO-TEST FAIL: Save error: {}", .{err});
                auto_test_phase = .done;
                return;
            };
            std.log.info("[SaveLoad] Saved successfully", .{});
            auto_test_phase = .corrupting;
        },
        .corrupting => {
            // Corrupt all positions
            for (scene.entities.items) |ei| {
                if (registry.getComponent(ei.entity, Position)) |pos| {
                    pos.x = -999;
                    pos.y = -999;
                }
            }
            std.log.info("[SaveLoad] State corrupted (all positions set to -999)", .{});
            auto_test_phase = .loading;
        },
        .loading => {
            loadState(scene, game) catch |err| {
                std.log.err("[SaveLoad] AUTO-TEST FAIL: Load error: {}", .{err});
                auto_test_phase = .done;
                return;
            };
            std.log.info("[SaveLoad] Loaded successfully", .{});
            auto_test_phase = .validating;
        },
        .validating => {
            var passed: u32 = 0;
            var failed: u32 = 0;

            // Validate positions match snapshots
            for (scene.entities.items, 0..) |ei, i| {
                if (i >= snapshot_count) break;
                const expected = position_snapshots[i];
                if (expected.x == -1) continue; // no position on this entity

                if (registry.getComponent(ei.entity, Position)) |pos| {
                    if (@abs(pos.x - expected.x) < 0.01 and @abs(pos.y - expected.y) < 0.01) {
                        passed += 1;
                    } else {
                        std.log.err("[SaveLoad] Entity {d}: position FAIL (expected {d:.1},{d:.1} got {d:.1},{d:.1})", .{ i, expected.x, expected.y, pos.x, pos.y });
                        failed += 1;
                    }
                } else {
                    std.log.err("[SaveLoad] Entity {d}: position FAIL (component missing)", .{i});
                    failed += 1;
                }
            }

            // Validate items still exist
            var item_count: usize = 0;
            var item_view = registry.view(.{Item});
            var item_iter = item_view.entityIterator();
            while (item_iter.next()) |_| item_count += 1;

            if (item_count > 0) {
                std.log.info("[SaveLoad] Items after load: {d}", .{item_count});
                passed += 1;
            } else {
                std.log.err("[SaveLoad] No items found after load", .{});
                failed += 1;
            }

            std.log.info("[SaveLoad] === AUTO-TEST RESULT: {d} passed, {d} failed ===", .{ passed, failed });
            if (failed == 0) {
                std.log.info("[SaveLoad] AUTO-TEST PASSED", .{});
            } else {
                std.log.err("[SaveLoad] AUTO-TEST FAILED", .{});
            }
            auto_test_phase = .done;
        },
        .done => {},
    }
}

// ─── Save Implementation ────────────────────────────────────────────────────

fn saveState(scene: *Scene, game: *Game) !void {
    const registry = game.getRegistry();

    // Build scene entity ID set
    var scene_ids: [MAX_SCENE_ENTITIES]u64 = undefined;
    var scene_count: usize = 0;
    for (scene.entities.items) |ei| {
        if (scene_count < MAX_SCENE_ENTITIES) {
            scene_ids[scene_count] = engine.entityToU64(ei.entity);
            scene_count += 1;
        }
    }

    var aw: std.io.Writer.Allocating = .init(script_allocator);
    errdefer aw.deinit();

    var jw: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try jw.beginObject();

    // Version
    try jw.objectField("version");
    try jw.write(@as(u32, 1));

    // Scene entities
    try jw.objectField("scene_entities");
    try jw.beginArray();

    for (scene.entities.items, 0..) |ei, idx| {
        try jw.beginObject();

        try jw.objectField("index");
        try jw.write(idx);

        try jw.objectField("id");
        try jw.write(engine.entityToU64(ei.entity));

        // Position
        if (registry.getComponent(ei.entity, Position)) |pos| {
            try jw.objectField("Position");
            try jw.beginObject();
            try jw.objectField("x");
            try jw.write(pos.x);
            try jw.objectField("y");
            try jw.write(pos.y);
            try jw.endObject();
        }

        // Saveable components
        try jw.objectField("components");
        try jw.beginObject();
        try writeEntityComponents(registry, ei.entity, &jw);
        try jw.endObject();

        try jw.endObject();
    }

    try jw.endArray();

    // Dynamic entities (items not in scene)
    try jw.objectField("dynamic_entities");
    try jw.beginArray();

    var item_view = registry.view(.{Item});
    var item_iter = item_view.entityIterator();
    while (item_iter.next()) |item_entity| {
        const item_id = engine.entityToU64(item_entity);
        if (isInSet(item_id, scene_ids[0..scene_count])) continue;

        try jw.beginObject();

        try jw.objectField("id");
        try jw.write(item_id);

        // Position
        if (registry.getComponent(item_entity, Position)) |pos| {
            try jw.objectField("Position");
            try jw.beginObject();
            try jw.objectField("x");
            try jw.write(pos.x);
            try jw.objectField("y");
            try jw.write(pos.y);
            try jw.endObject();
        }

        // Saveable components
        try jw.objectField("components");
        try jw.beginObject();
        try writeEntityComponents(registry, item_entity, &jw);
        try jw.endObject();

        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    const json = try aw.toOwnedSlice();
    defer script_allocator.free(json);

    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = SAVE_FILE, .data = json });
}

fn writeEntityComponents(registry: anytype, entity: anytype, jw: anytype) !void {
    inline for (SaveableComponents) |T| {
        if (registry.getComponent(entity, T)) |comp| {
            try jw.objectField(comptime componentName(T));
            try writeComponent(T, comp, jw);
        }
    }
}

// ─── Load Implementation ────────────────────────────────────────────────────

fn loadState(scene: *Scene, game: *Game) !void {
    const registry = game.getRegistry();

    // Read save file
    const cwd = std.fs.cwd();
    const json = try cwd.readFileAlloc(script_allocator, SAVE_FILE, 16 * 1024 * 1024);
    defer script_allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, script_allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Build scene entity ID set
    var scene_ids: [MAX_SCENE_ENTITIES]u64 = undefined;
    var scene_count: usize = 0;
    for (scene.entities.items) |ei| {
        if (scene_count < MAX_SCENE_ENTITIES) {
            scene_ids[scene_count] = engine.entityToU64(ei.entity);
            scene_count += 1;
        }
    }

    // ── Pass 1: Build ID map ──

    var id_map = std.AutoHashMap(u64, u64).init(script_allocator);
    defer id_map.deinit();

    // Scene entities: map saved_id → current_id (same entity by index)
    const scene_entities_json = (root.get("scene_entities") orelse return error.MissingField).array;
    for (scene_entities_json.items) |entry| {
        const obj = entry.object;
        const idx: usize = @intCast((obj.get("index") orelse continue).integer);
        const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
        if (idx >= scene.entities.items.len) continue;
        const current_id = engine.entityToU64(scene.entities.items[idx].entity);
        try id_map.put(saved_id, current_id);
    }

    // Remove components from existing dynamic entities
    var item_view = registry.view(.{Item});
    var item_iter = item_view.entityIterator();
    // Collect first to avoid iterator invalidation
    var dynamic_to_remove: [MAX_DYNAMIC_ENTITIES]Entity = undefined;
    var remove_count: usize = 0;
    while (item_iter.next()) |item_entity| {
        const item_id = engine.entityToU64(item_entity);
        if (isInSet(item_id, scene_ids[0..scene_count])) continue;
        if (remove_count < MAX_DYNAMIC_ENTITIES) {
            dynamic_to_remove[remove_count] = item_entity;
            remove_count += 1;
        }
    }
    for (dynamic_to_remove[0..remove_count]) |entity| {
        // Strip all components to make entity "dead"
        inline for (SaveableComponents) |T| {
            if (registry.getComponent(entity, T) != null) {
                registry.removeComponent(entity, T);
            }
        }
        if (registry.getComponent(entity, Position) != null) {
            registry.removeComponent(entity, Position);
        }
        if (registry.getComponent(entity, Shape) != null) {
            registry.removeComponent(entity, Shape);
        }
    }

    // Create new dynamic entities from save data
    const dynamic_entities_json = (root.get("dynamic_entities") orelse return error.MissingField).array;
    for (dynamic_entities_json.items) |entry| {
        const obj = entry.object;
        const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
        const new_entity = registry.createEntity();
        const new_id = engine.entityToU64(new_entity);
        try id_map.put(saved_id, new_id);
    }

    // ── Pass 2: Restore components ──

    // Restore scene entities
    for (scene_entities_json.items) |entry| {
        const obj = entry.object;
        const idx: usize = @intCast((obj.get("index") orelse continue).integer);
        if (idx >= scene.entities.items.len) continue;
        const entity = scene.entities.items[idx].entity;

        // Restore Position
        if (obj.get("Position")) |pos_val| {
            if (registry.getComponent(entity, Position)) |pos| {
                const pos_obj = pos_val.object;
                pos.x = jsonFloat(pos_obj.get("x").?);
                pos.y = jsonFloat(pos_obj.get("y").?);
            }
        }

        // Restore components
        const components = (obj.get("components") orelse continue).object;
        restoreEntityComponents(registry, entity, components, &id_map);
    }

    // Restore dynamic entities
    for (dynamic_entities_json.items) |entry| {
        const obj = entry.object;
        const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
        const new_id = id_map.get(saved_id) orelse continue;
        const entity = engine.entityFromU64(new_id);

        // Restore Position
        if (obj.get("Position")) |pos_val| {
            const pos_obj = pos_val.object;
            const pos = Position{
                .x = jsonFloat(pos_obj.get("x").?),
                .y = jsonFloat(pos_obj.get("y").?),
            };
            registry.addComponent(entity, pos);
        }

        // Restore components
        const components = (obj.get("components") orelse continue).object;
        addEntityComponents(registry, entity, components, &id_map);

        // Add Shape based on item type (re-derived, not serialized)
        if (registry.getComponent(entity, Item)) |item| {
            registry.addComponent(entity, createItemShape(item.item_type));
        }
    }

    // ── Post-load cleanup ──

    // Strip transient components
    stripTransientComponents(registry);

    // Reset WorkingOn.item for workers in .process step (forces timer restart)
    resetProcessingWorkers(registry);

    // Re-init StorageSlots on all workstations
    reinitStorageSlots(registry);

    // Mark visuals dirty
    const pipeline = game.getPipeline();
    for (scene.entities.items) |ei| {
        pipeline.markVisualDirty(ei.entity);
    }

    std.log.info("[SaveLoad] Post-load cleanup complete", .{});
}

fn restoreEntityComponents(registry: anytype, entity: anytype, components: std.json.ObjectMap, id_map: *const std.AutoHashMap(u64, u64)) void {
    inline for (SaveableComponents) |T| {
        const name = comptime componentName(T);
        if (components.get(name)) |comp_val| {
            if (T == Workstation) {
                // Update in-place to preserve runtime fields (storages, slots)
                if (registry.getComponent(entity, T)) |existing| {
                    readComponentInto(T, existing, comp_val) catch {};
                    remapEntityRefs(T, existing, id_map);
                }
            } else {
                // Remove and re-add with remapped IDs
                if (registry.getComponent(entity, T) != null) {
                    registry.removeComponent(entity, T);
                }
                if (readComponent(T, comp_val)) |restored| {
                    var comp = restored;
                    remapEntityRefs(T, &comp, id_map);
                    registry.addComponent(entity, comp);
                } else |_| {}
            }
        } else {
            // Component not in save — remove if present (except Workstation)
            if (T != Workstation) {
                if (registry.getComponent(entity, T) != null) {
                    registry.removeComponent(entity, T);
                }
            }
        }
    }
}

fn addEntityComponents(registry: anytype, entity: anytype, components: std.json.ObjectMap, id_map: *const std.AutoHashMap(u64, u64)) void {
    inline for (SaveableComponents) |T| {
        const name = comptime componentName(T);
        if (components.get(name)) |comp_val| {
            if (readComponent(T, comp_val)) |restored| {
                var comp = restored;
                remapEntityRefs(T, &comp, id_map);
                registry.addComponent(entity, comp);
            } else |_| {}
        }
    }
}

// ─── Serialization Helpers ──────────────────────────────────────────────────

fn writeComponent(comptime T: type, value: *const T, jw: anytype) !void {
    const info = @typeInfo(T);

    // Special case: EnumSet
    if (comptime isEnumSet(T)) {
        return writeEnumSet(T, value, jw);
    }

    switch (info) {
        .@"struct" => |s| {
            try jw.beginObject();
            inline for (s.fields) |field| {
                if (comptime shouldSkipField(T, field.name)) continue;
                try jw.objectField(field.name);
                // Copy to local to normalize alignment (handles packed struct fields)
                const val = @field(value.*, field.name);
                try writeComponent(field.type, &val, jw);
            }
            try jw.endObject();
        },
        .@"union" => {
            try jw.beginObject();
            switch (value.*) {
                inline else => |payload, tag| {
                    try jw.objectField(@tagName(tag));
                    if (@TypeOf(payload) == void) {
                        try jw.beginObject();
                        try jw.endObject();
                    } else {
                        try writeComponent(@TypeOf(payload), &payload, jw);
                    }
                },
            }
            try jw.endObject();
        },
        .@"enum" => {
            try jw.write(@tagName(value.*));
        },
        .optional => {
            if (value.*) |inner| {
                try writeComponent(@typeInfo(T).optional.child, &inner, jw);
            } else {
                try jw.write(null);
            }
        },
        .float => {
            try jw.write(value.*);
        },
        .int, .comptime_int => {
            try jw.write(value.*);
        },
        .bool => {
            try jw.write(value.*);
        },
        else => @compileError("Unsupported type for serialization: " ++ @typeName(T)),
    }
}

fn readComponent(comptime T: type, value: std.json.Value) !T {
    const info = @typeInfo(T);

    // Special case: EnumSet
    if (comptime isEnumSet(T)) {
        return readEnumSet(T, value);
    }

    switch (info) {
        .@"struct" => |s| {
            const obj = value.object;
            var result: T = undefined;
            inline for (s.fields) |field| {
                if (comptime shouldSkipField(T, field.name)) {
                    // Use default value for skipped fields
                    if (field.default_value_ptr) |dp| {
                        const typed: *const field.type = @ptrCast(@alignCast(dp));
                        @field(&result, field.name) = typed.*;
                    }
                } else if (obj.get(field.name)) |fv| {
                    @field(&result, field.name) = try readComponent(field.type, fv);
                } else if (field.default_value_ptr) |dp| {
                    const typed: *const field.type = @ptrCast(@alignCast(dp));
                    @field(&result, field.name) = typed.*;
                } else {
                    return error.MissingField;
                }
            }
            return result;
        },
        .@"union" => |u| {
            const obj = value.object;
            inline for (u.fields) |field| {
                if (obj.get(field.name)) |fv| {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        const payload = try readComponent(field.type, fv);
                        return @unionInit(T, field.name, payload);
                    }
                }
            }
            return error.InvalidUnionTag;
        },
        .@"enum" => {
            const name = value.string;
            return std.meta.stringToEnum(T, name) orelse error.InvalidEnumTag;
        },
        .optional => |opt| {
            if (value == .null) return null;
            return try readComponent(opt.child, value);
        },
        .float => {
            return jsonFloat(value);
        },
        .int, .comptime_int => {
            return @intCast(value.integer);
        },
        .bool => {
            return value.bool;
        },
        else => @compileError("Unsupported type for deserialization: " ++ @typeName(T)),
    }
}

/// Update existing component in-place, skipping runtime-derived fields.
fn readComponentInto(comptime T: type, comp: *T, value: std.json.Value) !void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => {
            const obj = value.object;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime shouldSkipField(T, field.name)) continue;
                if (obj.get(field.name)) |fv| {
                    @field(comp, field.name) = try readComponent(field.type, fv);
                }
            }
        },
        else => comp.* = try readComponent(T, value),
    }
}

fn writeEnumSet(comptime T: type, value: *const T, jw: anytype) !void {
    try jw.beginArray();
    var iter = value.iterator();
    while (iter.next()) |item| {
        try jw.write(@tagName(item));
    }
    try jw.endArray();
}

fn readEnumSet(comptime T: type, value: std.json.Value) T {
    var result = T{};
    for (value.array.items) |elem| {
        if (std.meta.stringToEnum(T.Key, elem.string)) |key| {
            result.insert(key);
        }
    }
    return result;
}

// ─── Entity ID Remapping ────────────────────────────────────────────────────

fn remapEntityRefs(comptime T: type, comp: *T, id_map: *const std.AutoHashMap(u64, u64)) void {
    if (T == Stored) {
        comp.storage_id = remapId(comp.storage_id, id_map);
    } else if (T == Locked) {
        comp.by = remapId(comp.by, id_map);
    } else if (T == WithItem) {
        comp.item_id = remapId(comp.item_id, id_map);
    } else if (T == WorkingOn) {
        comp.workstation_id = remapId(comp.workstation_id, id_map);
        comp.source = remapOptId(comp.source, id_map);
        comp.dest = remapOptId(comp.dest, id_map);
        // Don't remap item when it's the sentinel value (processing started)
        if (comp.item) |item_id| {
            if (item_id != production_system.processing_sentinel) comp.item = remapOptId(comp.item, id_map);
        }
    } else if (T == Delivering) {
        comp.item_id = remapId(comp.item_id, id_map);
        comp.source_storage = remapOptId(comp.source_storage, id_map);
        comp.dest_storage = remapId(comp.dest_storage, id_map);
    } else if (T == Eis or T == Iis or T == Ios or T == Eos) {
        comp.workstation = remapId(comp.workstation, id_map);
    } else if (T == CurrentTask) {
        switch (comp.*) {
            .going_to_workstation => |*payload| {
                payload.workstation_id = remapId(payload.workstation_id, id_map);
            },
            .carrying_item => |*payload| {
                payload.item_id = remapId(payload.item_id, id_map);
                payload.destination_id = remapId(payload.destination_id, id_map);
            },
            else => {},
        }
    }
}

fn remapId(id: u64, id_map: *const std.AutoHashMap(u64, u64)) u64 {
    return id_map.get(id) orelse id;
}

fn remapOptId(id: ?u64, id_map: *const std.AutoHashMap(u64, u64)) ?u64 {
    if (id) |i| return id_map.get(i) orelse i;
    return null;
}

// ─── Post-Load Cleanup ─────────────────────────────────────────────────────

fn stripTransientComponents(registry: anytype) void {
    inline for (TransientComponents) |T| {
        var view = registry.view(.{T});
        var iter = view.entityIterator();
        // Collect first to avoid iterator invalidation
        var entities: [128]Entity = undefined;
        var count: usize = 0;
        while (iter.next()) |entity| {
            if (count < 128) {
                entities[count] = entity;
                count += 1;
            }
        }
        for (entities[0..count]) |entity| {
            registry.removeComponent(entity, T);
        }
    }
}

fn resetProcessingWorkers(registry: anytype) void {
    var view = registry.view(.{WorkingOn});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const wo = view.get(entity);
        if (wo.step == .process) {
            wo.item = null;
        }
    }
}

fn reinitStorageSlots(registry: anytype) void {
    var ws_view = registry.view(.{Workstation});
    var ws_iter = ws_view.entityIterator();

    while (ws_iter.next()) |ws_entity| {
        const ws = ws_view.get(ws_entity);
        const ws_id = engine.entityToU64(ws_entity);

        // Reset slots
        ws.eis_slots = .{};
        ws.iis_slots = .{};
        ws.ios_slots = .{};
        ws.eos_slots = .{};

        // Re-populate from storages
        for (ws.storages) |storage_entity| {
            const storage_id = engine.entityToU64(storage_entity);

            if (registry.getComponent(storage_entity, Eis)) |eis| {
                eis.workstation = ws_id;
                ws.eis_slots.append(storage_id);
            }
            if (registry.getComponent(storage_entity, Iis)) |iis| {
                iis.workstation = ws_id;
                ws.iis_slots.append(storage_id);
            }
            if (registry.getComponent(storage_entity, Ios)) |ios| {
                ios.workstation = ws_id;
                ws.ios_slots.append(storage_id);
            }
            if (registry.getComponent(storage_entity, Eos)) |eos| {
                eos.workstation = ws_id;
                ws.eos_slots.append(storage_id);
            }
        }
    }
}

// ─── Utility ────────────────────────────────────────────────────────────────

fn shouldSkipField(comptime T: type, comptime field_name: []const u8) bool {
    if (T == Workstation) {
        return std.mem.eql(u8, field_name, "storages") or
            std.mem.eql(u8, field_name, "eis_slots") or
            std.mem.eql(u8, field_name, "iis_slots") or
            std.mem.eql(u8, field_name, "ios_slots") or
            std.mem.eql(u8, field_name, "eos_slots");
    }
    return false;
}

fn isEnumSet(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasDecl(T, "Key") and @hasDecl(T, "MaskInt") and @hasDecl(T, "insert");
}

fn componentName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const idx = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[idx + 1 ..];
}

fn jsonFloat(value: std.json.Value) f32 {
    return switch (value) {
        .float => @floatCast(value.float),
        .integer => @floatFromInt(value.integer),
        else => 0.0,
    };
}

fn isInSet(id: u64, set: []const u64) bool {
    for (set) |sid| {
        if (sid == id) return true;
    }
    return false;
}

fn createItemShape(item_type: Items) Shape {
    return production_system.itemShape(item_type);
}
