// Production system script
//
// Drives the EIS → IIS → Process → IOS → EOS pipeline for all workstations.
// Handles:
//   - StorageSlots initialization (populating eis/iis/ios/eos_slots on Workstations)
//   - Idle worker scheduling (assign to workstations or dangling item delivery)
//   - Worker state machine (pickup → process → store cycle via WorkingOn)
//   - Dangling item delivery (via Delivering component)
//   - Output item creation after processing completes

const std = @import("std");
const engine = @import("labelle-engine");
const main = @import("../main.zig");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.render.Position;
const Shape = engine.render.Shape;

const Worker = main.Worker;
const Workstation = main.Workstation;
const Eis = main.Eis;
const Iis = main.Iis;
const Ios = main.Ios;
const Eos = main.Eos;
const Item = main.Item;
const Stored = main.Stored;
const Locked = main.Locked;
const WithItem = main.WithItem;
const working_on_mod = @import("../components/working_on.zig");
const WorkstationStep = working_on_mod.WorkstationStep;
const WorkingOn = main.WorkingOn;
const Delivering = main.Delivering;
const MovementTarget = main.MovementTarget;
const WorkProgress = main.WorkProgress;
const Items = main.Items;

/// Sentinel value for WorkingOn.item to indicate "processing started" without
/// conflicting with any real entity ID. Uses maxInt(i64) cast to u64 so it
/// fits in JSON integer serialization.
pub const processing_sentinel: u64 = @intCast(std.math.maxInt(i64));

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    const registry = game.getRegistry();
    initStorageSlots(registry);
    std.log.info("[ProductionSystem] Script initialized", .{});
}

pub fn deinit() void {
    std.log.info("[ProductionSystem] Script deinitialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const registry = game.getRegistry();

    // 1. Drive workers that have WorkingOn (state machine)
    updateWorkingWorkers(game, registry);

    // 2. Drive workers that have Delivering (dangling item delivery)
    updateDeliveringWorkers(game, registry);

    // 3. Schedule idle workers
    scheduleIdleWorkers(game, registry);
}

// ============================================================================
// StorageSlots Initialization
// ============================================================================

fn initStorageSlots(registry: anytype) void {
    var ws_view = registry.view(.{Workstation});
    var ws_iter = ws_view.entityIterator();

    while (ws_iter.next()) |ws_entity| {
        const ws = ws_view.get(ws_entity);
        const ws_id = engine.entityToU64(ws_entity);

        for (ws.storages) |storage_entity| {
            const storage_id = engine.entityToU64(storage_entity);

            if (registry.tryGet(Eis, storage_entity)) |eis| {
                ws.eis_slots.append(storage_id);
                eis.workstation = ws_id;
            } else if (registry.tryGet(Iis, storage_entity)) |iis| {
                ws.iis_slots.append(storage_id);
                iis.workstation = ws_id;
            } else if (registry.tryGet(Ios, storage_entity)) |ios| {
                ws.ios_slots.append(storage_id);
                ios.workstation = ws_id;
            } else if (registry.tryGet(Eos, storage_entity)) |eos| {
                ws.eos_slots.append(storage_id);
                eos.workstation = ws_id;
            }
        }

        std.log.info("[ProductionSystem] Workstation {d}: EIS={d} IIS={d} IOS={d} EOS={d}, producer={}", .{
            ws_id,
            ws.eis_slots.len,
            ws.iis_slots.len,
            ws.ios_slots.len,
            ws.eos_slots.len,
            ws.isProducer(),
        });
    }
}

// ============================================================================
// Scheduling
// ============================================================================

fn scheduleIdleWorkers(game: *Game, registry: anytype) void {
    var worker_view = registry.view(.{ Worker, Position });
    var worker_iter = worker_view.entityIterator();

    while (worker_iter.next()) |worker_entity| {
        // Skip busy workers
        if (registry.tryGet(WorkingOn, worker_entity) != null) continue;
        if (registry.tryGet(Delivering, worker_entity) != null) continue;
        if (registry.tryGet(MovementTarget, worker_entity) != null) continue;

        const worker_pos = worker_view.get(Position, worker_entity);
        const worker_id = engine.entityToU64(worker_entity);

        // Try workstation assignment first
        if (tryAssignWorkstation(game, registry, worker_entity, worker_id, worker_pos)) continue;

        // Try dangling item delivery
        if (tryAssignDelivery(game, registry, worker_entity, worker_id, worker_pos)) continue;

        // Otherwise: wander (handled by worker_movement.zig)
    }
}

fn tryAssignWorkstation(game: *Game, registry: anytype, worker_entity: Entity, worker_id: u64, worker_pos: *const Position) bool {
    _ = game;
    var best_ws_entity: ?Entity = null;
    var best_dist: f32 = std.math.inf(f32);

    var ws_view = registry.view(.{ Workstation, Position });
    var ws_iter = ws_view.entityIterator();

    while (ws_iter.next()) |ws_entity| {
        // Skip locked workstations
        if (registry.tryGet(Locked, ws_entity) != null) continue;

        const ws = ws_view.get(Workstation, ws_entity);
        const ws_pos = ws_view.get(Position, ws_entity);

        if (ws.isProducer()) {
            // Producer: needs at least one empty EOS
            if (!hasEmptyEos(registry, ws)) continue;
        } else {
            // Non-producer: needs all EIS filled and at least one empty EOS
            if (!allEisFilled(registry, ws)) continue;
            if (!hasEmptyEos(registry, ws)) continue;
        }

        const dx = ws_pos.x - worker_pos.x;
        const dy = ws_pos.y - worker_pos.y;
        const dist = dx * dx + dy * dy;
        if (dist < best_dist) {
            best_dist = dist;
            best_ws_entity = ws_entity;
        }
    }

    if (best_ws_entity) |ws_entity| {
        const ws_pos = registry.tryGet(Position, ws_entity) orelse return false;
        const ws_id = engine.entityToU64(ws_entity);

        const ws = registry.tryGet(Workstation, ws_entity) orelse return false;
        const initial_step: WorkstationStep = if (ws.isProducer()) .process else .pickup;

        // Lock workstation ↔ worker
        registry.add(worker_entity, Locked{ .by = ws_id });
        registry.add(ws_entity, Locked{ .by = worker_id });

        // Assign WorkingOn
        registry.add(worker_entity, WorkingOn{
            .workstation_id = ws_id,
            .step = initial_step,
        });

        // Move to workstation
        registry.add(worker_entity, MovementTarget{
            .target_x = ws_pos.x,
            .target_y = ws_pos.y,
            .speed = 120.0,
            .action = .arrive_at_workstation,
        });

        std.log.info("[ProductionSystem] Worker {d} assigned to workstation {d} (step={})", .{
            worker_id, ws_id, initial_step,
        });
        return true;
    }

    return false;
}

fn tryAssignDelivery(game: *Game, registry: anytype, worker_entity: Entity, worker_id: u64, worker_pos: *const Position) bool {
    _ = game;

    // Find dangling items (Item + Position, no Stored, no Locked)
    var item_view = registry.view(.{ Item, Position });
    var item_iter = item_view.entityIterator();

    while (item_iter.next()) |item_entity| {
        if (registry.tryGet(Stored, item_entity) != null) continue;
        if (registry.tryGet(Locked, item_entity) != null) continue;

        const item = item_view.get(Item, item_entity);
        const item_id = engine.entityToU64(item_entity);

        // Find an empty EIS that accepts this item type
        if (findEmptyEisForItem(registry, item.item_type)) |eis_storage_id| {
            const item_pos = item_view.get(Position, item_entity);
            _ = worker_pos;

            // Lock the item and destination storage
            registry.add(item_entity, Locked{ .by = worker_id });
            const dest_lock_entity = engine.entityFromU64(eis_storage_id);
            registry.add(dest_lock_entity, Locked{ .by = worker_id });

            // Assign Delivering
            registry.add(worker_entity, Delivering{
                .item_id = item_id,
                .dest_storage = eis_storage_id,
                .current_step = 0,
            });

            // Move to item
            registry.add(worker_entity, MovementTarget{
                .target_x = item_pos.x,
                .target_y = item_pos.y,
                .speed = 120.0,
                .action = .pickup_dangling,
            });

            std.log.info("[ProductionSystem] Worker {d} delivering dangling item {d} to EIS {d}", .{
                worker_id, item_id, eis_storage_id,
            });
            return true;
        }
    }

    return false;
}

// ============================================================================
// Worker State Machine (WorkingOn)
// ============================================================================

fn updateWorkingWorkers(game: *Game, registry: anytype) void {
    // Collect working workers to avoid iterator invalidation on component removal
    var workers_buf: [32]Entity = undefined;
    var worker_count: usize = 0;
    {
        var worker_view = registry.view(.{ WorkingOn, Worker });
        var worker_iter = worker_view.entityIterator();
        while (worker_iter.next()) |worker_entity| {
            if (worker_count < workers_buf.len) {
                workers_buf[worker_count] = worker_entity;
                worker_count += 1;
            }
        }
    }

    for (workers_buf[0..worker_count]) |worker_entity| {
        // Only act when worker has arrived (no MovementTarget) and no WorkProgress running
        if (registry.tryGet(MovementTarget, worker_entity) != null) continue;
        if (registry.tryGet(WorkProgress, worker_entity) != null) continue;

        const wo = registry.tryGet(WorkingOn, worker_entity) orelse continue;
        const worker_id = engine.entityToU64(worker_entity);
        const ws_entity = engine.entityFromU64(wo.workstation_id);
        const ws = registry.tryGet(Workstation, ws_entity) orelse continue;

        switch (wo.step) {
            .pickup => advancePickup(game, registry, worker_entity, worker_id, wo, ws),
            .process => advanceProcess(game, registry, worker_entity, worker_id, wo, ws),
            .store => advanceStore(game, registry, worker_entity, worker_id, wo, ws),
        }
    }
}

fn advancePickup(game: *Game, registry: anytype, worker_entity: Entity, worker_id: u64, wo: *WorkingOn, ws: *const Workstation) void {
    if (wo.source == null) {
        // Find next EIS→IIS pair to transfer
        if (findNextEisIisPair(registry, ws)) |pair| {
            wo.source = pair.eis_id;
            wo.dest = pair.iis_id;

            // Walk to EIS
            const eis_entity = engine.entityFromU64(pair.eis_id);
            if (registry.tryGet(Position, eis_entity)) |eis_pos| {
                registry.add(worker_entity, MovementTarget{
                    .target_x = eis_pos.x,
                    .target_y = eis_pos.y,
                    .speed = 120.0,
                    .action = .pickup,
                });
                std.log.info("[ProductionSystem] Worker {d}: pickup — walking to EIS {d}", .{ worker_id, pair.eis_id });
            }
        } else {
            // All EIS→IIS transfers done, advance to process
            wo.step = .process;
            wo.source = null;
            wo.dest = null;
            wo.item = null;
            std.log.info("[ProductionSystem] Worker {d}: pickup complete, advancing to process", .{worker_id});
        }
    } else if (wo.item == null) {
        // At EIS — pick up item
        const eis_entity = engine.entityFromU64(wo.source.?);
        if (registry.tryGet(WithItem, eis_entity)) |with_item| {
            const item_id = with_item.item_id;
            const item_entity = engine.entityFromU64(item_id);

            // Remove item from EIS storage
            registry.remove(WithItem, eis_entity);
            if (registry.tryGet(Stored, item_entity) != null) {
                registry.remove(Stored, item_entity);
            }

            // Lock item (being carried)
            if (registry.tryGet(Locked, item_entity) == null) {
                registry.add(item_entity, Locked{ .by = worker_id });
            }

            wo.item = item_id;

            // Walk to IIS
            const iis_entity = engine.entityFromU64(wo.dest.?);
            if (registry.tryGet(Position, iis_entity)) |iis_pos| {
                registry.add(worker_entity, MovementTarget{
                    .target_x = iis_pos.x,
                    .target_y = iis_pos.y,
                    .speed = 120.0,
                    .action = .deliver_to_iis,
                });
                std.log.info("[ProductionSystem] Worker {d}: carrying item {d} to IIS {d}", .{ worker_id, item_id, wo.dest.? });
            }
        } else {
            // EIS empty unexpectedly — skip this pair
            wo.source = null;
            wo.dest = null;
        }
    } else {
        // At IIS — deliver item
        const iis_entity = engine.entityFromU64(wo.dest.?);
        const item_id = wo.item.?;
        const item_entity = engine.entityFromU64(item_id);
        const iis_id = wo.dest.?;

        // Place item in IIS
        registry.add(iis_entity, WithItem{ .item_id = item_id });
        registry.set(item_entity, Stored{ .storage_id = iis_id });

        // Unlock item
        if (registry.tryGet(Locked, item_entity) != null) {
            registry.remove(Locked, item_entity);
        }

        // Move item to IIS position
        if (registry.tryGet(Position, iis_entity)) |iis_pos| {
            game.pos.setLocalPosition(item_entity, Position{ .x = iis_pos.x, .y = iis_pos.y });
        }

        std.log.info("[ProductionSystem] Worker {d}: delivered item {d} to IIS {d}", .{ worker_id, item_id, iis_id });

        // Clear carry state and look for next pair
        wo.source = null;
        wo.dest = null;
        wo.item = null;
    }
}

fn advanceProcess(_: *Game, registry: anytype, worker_entity: Entity, worker_id: u64, wo: *WorkingOn, ws: *const Workstation) void {

    if (wo.item == null) {
        // Not started yet — consume IIS items (for non-producers) and start timer
        if (!ws.isProducer()) {
            consumeIisItems(registry, ws);
        }

        // Add WorkProgress timer
        const duration: f32 = @floatFromInt(ws.process_duration);
        registry.add(worker_entity, WorkProgress{
            .workstation_id = wo.workstation_id,
            .duration = duration,
        });

        // Mark that processing has started (sentinel value, not a real entity ID)
        wo.item = processing_sentinel;

        std.log.info("[ProductionSystem] Worker {d}: processing started ({d}s)", .{
            worker_id, ws.process_duration,
        });
    } else {
        // WorkProgress was removed by work_processor.zig — processing complete
        // Create output items in each IOS
        createOutputItems(registry, ws);

        std.log.info("[ProductionSystem] Worker {d}: processing complete, created output items", .{worker_id});

        // Advance to store
        wo.step = .store;
        wo.source = null;
        wo.dest = null;
        wo.item = null;
    }
}

fn advanceStore(game: *Game, registry: anytype, worker_entity: Entity, worker_id: u64, wo: *WorkingOn, ws: *const Workstation) void {

    if (wo.source == null) {
        // Find next IOS→EOS pair to transfer
        if (findNextIosEosPair(registry, ws)) |pair| {
            wo.source = pair.ios_id;
            wo.dest = pair.eos_id;

            // Walk to IOS
            const ios_entity = engine.entityFromU64(pair.ios_id);
            if (registry.tryGet(Position, ios_entity)) |ios_pos| {
                registry.add(worker_entity, MovementTarget{
                    .target_x = ios_pos.x,
                    .target_y = ios_pos.y,
                    .speed = 120.0,
                    .action = .pickup_from_ios,
                });
                std.log.info("[ProductionSystem] Worker {d}: store — walking to IOS {d}", .{ worker_id, pair.ios_id });
            }
        } else {
            // All IOS→EOS transfers done — cycle complete
            finishCycle(registry, worker_entity, worker_id, wo, ws);
        }
    } else if (wo.item == null) {
        // At IOS — pick up item
        const ios_entity = engine.entityFromU64(wo.source.?);
        if (registry.tryGet(WithItem, ios_entity)) |with_item| {
            const item_id = with_item.item_id;
            const item_entity = engine.entityFromU64(item_id);

            // Remove from IOS
            registry.remove(WithItem, ios_entity);
            if (registry.tryGet(Stored, item_entity) != null) {
                registry.remove(Stored, item_entity);
            }

            // Lock item (being carried)
            if (registry.tryGet(Locked, item_entity) == null) {
                registry.add(item_entity, Locked{ .by = worker_id });
            }

            wo.item = item_id;

            // Walk to EOS
            const eos_entity = engine.entityFromU64(wo.dest.?);
            if (registry.tryGet(Position, eos_entity)) |eos_pos| {
                registry.add(worker_entity, MovementTarget{
                    .target_x = eos_pos.x,
                    .target_y = eos_pos.y,
                    .speed = 120.0,
                    .action = .store,
                });
                std.log.info("[ProductionSystem] Worker {d}: carrying item {d} to EOS {d}", .{ worker_id, item_id, wo.dest.? });
            }
        } else {
            // IOS empty unexpectedly — skip
            wo.source = null;
            wo.dest = null;
        }
    } else {
        // At EOS — deliver item
        const eos_entity = engine.entityFromU64(wo.dest.?);
        const item_id = wo.item.?;
        const item_entity = engine.entityFromU64(item_id);
        const eos_id = wo.dest.?;

        // Place item in EOS
        registry.add(eos_entity, WithItem{ .item_id = item_id });
        registry.set(item_entity, Stored{ .storage_id = eos_id });

        // Unlock item
        if (registry.tryGet(Locked, item_entity) != null) {
            registry.remove(Locked, item_entity);
        }

        // Move item to EOS position
        if (registry.tryGet(Position, eos_entity)) |eos_pos| {
            game.pos.setLocalPosition(item_entity, Position{ .x = eos_pos.x, .y = eos_pos.y });
        }

        std.log.info("[ProductionSystem] Worker {d}: stored item {d} in EOS {d}", .{ worker_id, item_id, eos_id });

        // Clear and look for next pair
        wo.source = null;
        wo.dest = null;
        wo.item = null;
    }
}

fn finishCycle(registry: anytype, worker_entity: Entity, worker_id: u64, wo: *WorkingOn, ws: *const Workstation) void {
    // Check if workstation can run another cycle
    if (ws.isProducer() and hasEmptyEos(registry, ws)) {
        // Producer with empty EOS: restart at process
        wo.step = .process;
        wo.source = null;
        wo.dest = null;
        wo.item = null;
        std.log.info("[ProductionSystem] Worker {d}: producer cycle restart", .{worker_id});
        return;
    }

    if (!ws.isProducer() and allEisFilled(registry, ws)) {
        // Non-producer with all EIS filled: restart at pickup
        wo.step = .pickup;
        wo.source = null;
        wo.dest = null;
        wo.item = null;
        std.log.info("[ProductionSystem] Worker {d}: non-producer cycle restart", .{worker_id});
        return;
    }

    // Release worker
    const ws_entity = engine.entityFromU64(wo.workstation_id);

    registry.remove(WorkingOn, worker_entity);
    if (registry.tryGet(Locked, worker_entity) != null) {
        registry.remove(Locked, worker_entity);
    }
    if (registry.tryGet(Locked, ws_entity) != null) {
        registry.remove(Locked, ws_entity);
    }

    std.log.info("[ProductionSystem] Worker {d}: released from workstation {d}", .{
        worker_id, engine.entityToU64(ws_entity),
    });
}

// ============================================================================
// Delivering Workers (dangling items)
// ============================================================================

fn updateDeliveringWorkers(game: *Game, registry: anytype) void {
    // Collect delivering workers to avoid iterator invalidation on component removal
    var workers_buf: [32]Entity = undefined;
    var worker_count: usize = 0;
    {
        var worker_view = registry.view(.{ Delivering, Worker });
        var worker_iter = worker_view.entityIterator();
        while (worker_iter.next()) |worker_entity| {
            if (worker_count < workers_buf.len) {
                workers_buf[worker_count] = worker_entity;
                worker_count += 1;
            }
        }
    }

    for (workers_buf[0..worker_count]) |worker_entity| {
        // Only act when worker has arrived
        if (registry.tryGet(MovementTarget, worker_entity) != null) continue;

        const del = registry.tryGet(Delivering, worker_entity) orelse continue;
        const worker_id = engine.entityToU64(worker_entity);

        if (del.current_step == 0) {
            // Arrived at item — pick it up, walk to EIS
            const item_entity = engine.entityFromU64(del.item_id);

            // Move item to worker position (carried)
            if (registry.tryGet(Position, worker_entity)) |worker_pos| {
                game.pos.setLocalPosition(item_entity, Position{ .x = worker_pos.x, .y = worker_pos.y });
            }

            del.current_step = 1;

            // Walk to destination EIS
            const dest_entity = engine.entityFromU64(del.dest_storage);
            if (registry.tryGet(Position, dest_entity)) |dest_pos| {
                registry.add(worker_entity, MovementTarget{
                    .target_x = dest_pos.x,
                    .target_y = dest_pos.y,
                    .speed = 120.0,
                    .action = .transport_deliver,
                });
                std.log.info("[ProductionSystem] Worker {d}: carrying dangling item {d} to EIS {d}", .{
                    worker_id, del.item_id, del.dest_storage,
                });
            }
        } else {
            // Arrived at EIS — place item
            const dest_entity = engine.entityFromU64(del.dest_storage);
            const item_id = del.item_id;
            const item_entity = engine.entityFromU64(item_id);
            const dest_id = del.dest_storage;

            // Place item in EIS
            registry.add(dest_entity, WithItem{ .item_id = item_id });
            registry.set(item_entity, Stored{ .storage_id = dest_id });

            // Unlock item and destination storage
            if (registry.tryGet(Locked, item_entity) != null) {
                registry.remove(Locked, item_entity);
            }
            if (registry.tryGet(Locked, dest_entity) != null) {
                registry.remove(Locked, dest_entity);
            }

            // Move item to EIS position
            if (registry.tryGet(Position, dest_entity)) |dest_pos| {
                game.pos.setLocalPosition(item_entity, Position{ .x = dest_pos.x, .y = dest_pos.y });
            }

            std.log.info("[ProductionSystem] Worker {d}: delivered dangling item {d} to EIS {d}", .{
                worker_id, item_id, dest_id,
            });

            // Remove Delivering component
            registry.remove(Delivering, worker_entity);
        }
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn hasEmptyEos(registry: anytype, ws: *const Workstation) bool {
    for (ws.eos_slots.slice()) |eos_id| {
        const eos_entity = engine.entityFromU64(eos_id);
        if (registry.tryGet(WithItem, eos_entity) == null) return true;
    }
    return false;
}

fn allEisFilled(registry: anytype, ws: *const Workstation) bool {
    if (ws.eis_slots.len == 0) return false;
    for (ws.eis_slots.slice()) |eis_id| {
        const eis_entity = engine.entityFromU64(eis_id);
        if (registry.tryGet(WithItem, eis_entity) == null) return false;
    }
    return true;
}

const EisIisPair = struct { eis_id: u64, iis_id: u64 };

fn findNextEisIisPair(registry: anytype, ws: *const Workstation) ?EisIisPair {
    // Match EIS to IIS by item_type
    for (ws.eis_slots.slice()) |eis_id| {
        const eis_entity = engine.entityFromU64(eis_id);
        if (registry.tryGet(WithItem, eis_entity) == null) continue; // EIS must have an item

        const eis_marker = registry.tryGet(Eis, eis_entity) orelse continue;
        const eis_item_type = eis_marker.item_type orelse continue;

        // Find matching IIS that's empty
        for (ws.iis_slots.slice()) |iis_id| {
            const iis_entity = engine.entityFromU64(iis_id);
            if (registry.tryGet(WithItem, iis_entity) != null) continue;

            const iis_marker = registry.tryGet(Iis, iis_entity) orelse continue;
            const iis_item_type = iis_marker.item_type orelse continue;

            if (eis_item_type == iis_item_type) {
                return EisIisPair{ .eis_id = eis_id, .iis_id = iis_id };
            }
        }
    }
    return null;
}

const IosEosPair = struct { ios_id: u64, eos_id: u64 };

fn findNextIosEosPair(registry: anytype, ws: *const Workstation) ?IosEosPair {
    for (ws.ios_slots.slice()) |ios_id| {
        const ios_entity = engine.entityFromU64(ios_id);
        if (registry.tryGet(WithItem, ios_entity) == null) continue;

        const ios_marker = registry.tryGet(Ios, ios_entity) orelse continue;
        const ios_item_type = ios_marker.item_type orelse continue;

        // Find matching empty EOS
        for (ws.eos_slots.slice()) |eos_id| {
            const eos_entity = engine.entityFromU64(eos_id);
            if (registry.tryGet(WithItem, eos_entity) != null) continue;

            const eos_marker = registry.tryGet(Eos, eos_entity) orelse continue;
            const eos_item_type = eos_marker.item_type orelse continue;

            if (ios_item_type == eos_item_type) {
                return IosEosPair{ .ios_id = ios_id, .eos_id = eos_id };
            }
        }
    }
    return null;
}

fn findEmptyEisForItem(registry: anytype, item_type: Items) ?u64 {
    // Search all EIS entities for one that accepts this item and is empty
    var eis_view = registry.view(.{Eis});
    var eis_iter = eis_view.entityIterator();

    while (eis_iter.next()) |eis_entity| {
        if (registry.tryGet(WithItem, eis_entity) != null) continue;
        if (registry.tryGet(Locked, eis_entity) != null) continue;

        const eis_marker = eis_view.get(eis_entity);
        if (eis_marker.item_type) |accepted| {
            if (accepted == item_type) {
                return engine.entityToU64(eis_entity);
            }
        }
    }
    return null;
}

fn consumeIisItems(registry: anytype, ws: *const Workstation) void {
    for (ws.iis_slots.slice()) |iis_id| {
        const iis_entity = engine.entityFromU64(iis_id);
        if (registry.tryGet(WithItem, iis_entity)) |with_item| {
            const item_entity = engine.entityFromU64(with_item.item_id);

            // Remove item from IIS
            registry.remove(WithItem, iis_entity);
            if (registry.tryGet(Stored, item_entity) != null) {
                registry.remove(Stored, item_entity);
            }

            // Destroy consumed item
            registry.remove(Item, item_entity);
            if (registry.tryGet(Position, item_entity) != null) {
                registry.remove(Position, item_entity);
            }
            if (registry.tryGet(Shape, item_entity) != null) {
                registry.remove(Shape, item_entity);
            }

            std.log.info("[ProductionSystem] Consumed item {d} from IIS {d}", .{
                with_item.item_id, iis_id,
            });
        }
    }
}

fn createOutputItems(registry: anytype, ws: *const Workstation) void {
    for (ws.ios_slots.slice()) |ios_id| {
        const ios_entity = engine.entityFromU64(ios_id);
        if (registry.tryGet(WithItem, ios_entity) != null) continue; // already has item

        const ios_pos = registry.tryGet(Position, ios_entity) orelse continue;
        const ios_marker = registry.tryGet(Ios, ios_entity) orelse continue;
        const item_type = ios_marker.item_type orelse continue;

        // Create new item entity
        const item_entity = registry.createEntity();
        const item_id = engine.entityToU64(item_entity);

        registry.add(item_entity, Position{ .x = ios_pos.x, .y = ios_pos.y });
        registry.add(item_entity, Item{ .item_type = item_type });
        registry.add(item_entity, Stored{ .storage_id = ios_id });

        // Add shape (colored by item type)
        registry.add(item_entity, itemShape(item_type));

        // Mark IOS as holding the item
        registry.add(ios_entity, WithItem{ .item_id = item_id });

        std.log.info("[ProductionSystem] Created item {d} ({}) in IOS {d}", .{
            item_id, @intFromEnum(item_type), ios_id,
        });
    }
}

pub fn itemShape(item_type: Items) Shape {
    const color = switch (item_type) {
        .Water => engine.Color{ .r = 80, .g = 150, .b = 255, .a = 255 },
        .Flour => engine.Color{ .r = 240, .g = 230, .b = 200, .a = 255 },
        .Bread => engine.Color{ .r = 200, .g = 150, .b = 80, .a = 255 },
        else => engine.Color{ .r = 180, .g = 180, .b = 180, .a = 255 },
    };
    return Shape{
        .shape = .{ .circle = .{ .radius = 8 } },
        .color = color,
    };
}
