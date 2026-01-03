// Workstation component for task engine integration
//
// Attach to entities that process items (e.g., ovens, forges, looms).
// Uses onReady callback (RFC #169) to register the workstation and its storages
// with the task engine after the entire hierarchy is complete.

const std = @import("std");
const engine = @import("labelle-engine");
const task_state = @import("task_state.zig");

const Entity = engine.Entity;
const Game = engine.Game;
const Storage = task_state.Storage;
const StorageRole = task_state.StorageRole;

/// Workstation component - attach to entities to define task engine workstations
/// The ECS entity ID will be used as the workstation ID.
pub const Workstation = struct {
    /// Processing duration in frames (0 = use default)
    process_duration: u32 = 120,

    /// External Input Storages (EIS) - external input storages that accept dangling items
    external_input_storages: []const Entity = &.{},

    /// Internal Output Storages (IOS) - output buffers for the workstation
    output_storages: []const Entity = &.{},

    /// External Output Storages (EOS) - final output storages
    external_outputs: []const Entity = &.{},

    /// Called after the entire entity hierarchy is complete (RFC #169).
    /// At this point, all nested storage entities have been created and
    /// the storage arrays are fully populated.
    pub fn onReady(payload: engine.ComponentPayload) void {
        const entity_id = payload.entity_id;
        std.log.info("[Workstation.onReady] Entity {d} - hierarchy complete, registering", .{entity_id});

        // Access the game and registry to query component data
        const game = payload.getGame(Game);
        const registry = game.getRegistry();

        // Ensure task_state has access to the registry and game for position updates
        task_state.setRegistry(registry);
        task_state.setGame(game);

        // Get the Workstation component to access configuration
        const ws_entity = engine.entityFromU64(entity_id);
        const ws = registry.tryGet(Workstation, ws_entity) orelse {
            std.log.err("[Workstation.onReady] Entity {d} - could not get Workstation component", .{entity_id});
            return;
        };

        std.log.warn("[Workstation.onReady] Entity {d} - process_duration: {d}", .{ entity_id, ws.process_duration });
        std.log.warn("[Workstation.onReady] Entity {d} - external_input_storages: {d}, output_storages: {d}, external_outputs: {d}", .{
            entity_id,
            ws.external_input_storages.len,
            ws.output_storages.len,
            ws.external_outputs.len,
        });

        // Collect storage IDs by type for task engine registration
        var eis_ids: [16]u64 = undefined;
        var eis_count: usize = 0;
        var iis_ids: [16]u64 = undefined;
        var iis_count: usize = 0;
        var ios_ids: [16]u64 = undefined;
        var ios_count: usize = 0;
        var eos_ids: [16]u64 = undefined;
        var eos_count: usize = 0;

        // Helper to process a storage entity and categorize it
        const processStorage = struct {
            fn call(
                reg: anytype,
                storage_entity: Entity,
                eis: *[16]u64,
                eis_cnt: *usize,
                iis: *[16]u64,
                iis_cnt: *usize,
                ios: *[16]u64,
                ios_cnt: *usize,
                eos: *[16]u64,
                eos_cnt: *usize,
                default_role: StorageRole,
            ) void {
                const storage_id = engine.entityToU64(storage_entity);

                // Get the Storage component to determine role
                // Storage auto-registers via onAdd callback (RFC #28)
                const role = if (reg.tryGet(Storage, storage_entity)) |s| s.role else default_role;

                // Workstation just needs to collect IDs for workstation config
                switch (role) {
                    .eis => {
                        if (eis_cnt.* < eis.len) {
                            eis[eis_cnt.*] = storage_id;
                            eis_cnt.* += 1;
                        }
                    },
                    .iis => {
                        if (iis_cnt.* < iis.len) {
                            iis[iis_cnt.*] = storage_id;
                            iis_cnt.* += 1;
                        }
                    },
                    .ios => {
                        if (ios_cnt.* < ios.len) {
                            ios[ios_cnt.*] = storage_id;
                            ios_cnt.* += 1;
                        }
                    },
                    .eos => {
                        if (eos_cnt.* < eos.len) {
                            eos[eos_cnt.*] = storage_id;
                            eos_cnt.* += 1;
                        }
                    },
                }
            }
        }.call;

        // Process external_input_storages (default to EIS)
        for (ws.external_input_storages) |storage_entity| {
            processStorage(registry, storage_entity, &eis_ids, &eis_count, &iis_ids, &iis_count, &ios_ids, &ios_count, &eos_ids, &eos_count, .eis);
        }

        // Process output_storages (default to IOS)
        for (ws.output_storages) |storage_entity| {
            processStorage(registry, storage_entity, &eis_ids, &eis_count, &iis_ids, &iis_count, &ios_ids, &ios_count, &eos_ids, &eos_count, .ios);
        }

        // Process external_outputs (default to EOS)
        for (ws.external_outputs) |storage_entity| {
            processStorage(registry, storage_entity, &eis_ids, &eis_count, &iis_ids, &iis_count, &ios_ids, &ios_count, &eos_ids, &eos_count, .eos);
        }

        // Register workstation with task engine
        task_state.addWorkstation(entity_id, .{
            .eis = eis_ids[0..eis_count],
            .iis = iis_ids[0..iis_count],
            .ios = ios_ids[0..ios_count],
            .eos = eos_ids[0..eos_count],
        }) catch |err| {
            std.log.err("[Workstation.onReady] Failed to add workstation {d}: {}", .{ entity_id, err });
            return;
        };

        std.log.info("[Workstation.onReady] Entity {d} - registered with task engine (eis={d}, iis={d}, ios={d}, eos={d})", .{
            entity_id,
            eis_count,
            iis_count,
            ios_count,
            eos_count,
        });
    }

    /// Called when Workstation component is removed
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.warn("[Workstation.onRemove] Entity {d} - workstation removed", .{payload.entity_id});
    }
};
