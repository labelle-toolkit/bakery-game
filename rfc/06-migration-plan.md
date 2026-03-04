# 6. Migration Plan

## 6.1 Phased Approach

### Phase 1: Core Components and Prefab Integration

Remove the `labelle-tasks` plugin and register ECS-native components directly. All entities must be fully definable through prefabs — no runtime-only component setup.

**Prefab-first principle**: every component used by the systems must be declarable in `.zon` prefab files. Workers, workstations, storages, items, water sources, beds, and tables are all prefab-defined entities.

Files changed:
- `project.labelle` — remove `.plugins` block
- `main.zig` — remove `labelle-tasks` import, register new components in `Components` registry
- `prefabs/baker.zon` — add `Needs` component (Phase 4-ready)
- `prefabs/oven.zon` — port to `Workstation` + `StorageSlots` format, storage children use `EIS/IIS/IOS/EOS` markers + `Storage { .accepted_items }`
- `prefabs/water_well.zon` — same treatment (producer: no EIS/IIS)
- `scenes/main.zon` — dangling items use `Item { .item_type }` instead of `DanglingItem`

### Phase 2: Replace Hooks with Systems

Integrate the 6 ECS systems into the game loop. The systems run as scripts registered in the scene.

Files changed:
- Add system scripts (wrappers that call into tasks-and-needs systems)
- Delete `hooks/task_hooks.zig` — all 11 hooks and 7 HashMaps removed
- `scenes/main.zon` — register system scripts in execution order

### Phase 3: Simplify Game Scripts

Game scripts become thin wrappers that handle rendering and input only. All scheduling and state management lives in the systems.

Files changed:
- `scripts/worker_movement.zig` — read `CurrentTask` for movement, no Context calls. Game still owns movement interpolation and entity hierarchy (attach/detach carried items).
- `scripts/work_processor.zig` — set `TaskComplete` marker instead of `Context.workCompleted()`. Or remove entirely if processing is handled by `WorkerExecutionSystem`.
- Delete `scripts/task_initializer.zig` — scheduler finds idle workers automatically
- Delete `scripts/eos_transport.zig` — scheduler handles dangling delivery
- `scripts/storage_inspector.zig` — update queries for new marker types
- `scripts/workstation_gizmos.zig` — update queries for new marker types
- `components/movement_target.zig` — may be simplified or removed if `CurrentTask` drives movement directly

### Phase 4: Needs Integration (optional, additive)

- Add `Needs { .thirst, .hunger }` to baker prefab
- Add water source, table, and bed prefabs with `Position`
- Register `NeedsDecaySystem` and `NeedsEvaluationSystem`
- Add threshold marker components to registry

## 6.2 Prefab Integration

### Current Prefab Format (labelle-tasks)

```zon
// prefabs/oven.zon (current) — storages nested under Workstation.storages
.Workstation = .{
    .process_duration = 5,
    .storages = .{
        .{ .components = .{
            .Position = .{ .x = -60, .y = 80 },
            .Storage = .{ .role = .eis, .accepts = .Flour },
            .Shape = .{ ... },
        }},
        .{ .components = .{
            .Position = .{ .x = -50, .y = 0 },
            .Storage = .{ .role = .iis, .accepts = .Flour },
            .Shape = .{ ... },
        }},
        // ... IOS, EOS similarly
    },
},
```

### Target Prefab Format (ECS-native)

```zon
// prefabs/oven.zon (target) — same nesting structure, role split into marker
.Workstation = .{
    .workstation_type = .kitchen,
    .process_duration = 5,
    .storages = .{
        .{ .components = .{
            .Position = .{ .x = -60, .y = 80 },
            .Storage = .{ .accepted_items = .{ .flour = true } },
            .EIS = .{},
            .Shape = .{ ... },
        }},
        .{ .components = .{
            .Position = .{ .x = -50, .y = 0 },
            .Storage = .{ .accepted_items = .{ .flour = true } },
            .IIS = .{},
            .Shape = .{ ... },
        }},
        .{ .components = .{
            .Position = .{ .x = 50, .y = 15 },
            .Storage = .{ .accepted_items = .{ .bread = true } },
            .IOS = .{},
            .Shape = .{ ... },
        }},
        .{ .components = .{
            .Position = .{ .x = 100, .y = 15 },
            .Storage = .{ .accepted_items = .{ .bread = true } },
            .EOS = .{},
            .Shape = .{ ... },
        }},
    },
},
```

Key differences:
- Storage role is a separate marker component (`EIS`, `IIS`, `IOS`, `EOS`) instead of `Storage.role`
- `Storage.accepted_items` uses `EnumSet(ItemType)` instead of a single `.accepts` value
- `Workstation` gains `workstation_type` field
- Prefab nesting structure (`Workstation.storages = .{ ... }`) is unchanged

### StorageSlots Resolution

`Workstation` has runtime-only `StorageSlots` fields (`eis_slots`, `iis_slots`, `ios_slots`, `eos_slots`) that are not declared in prefabs. They are populated automatically via the engine's `onReady` callback (RFC #169).

The engine guarantees that when `Workstation.onReady` fires:
1. All storage children are created
2. The `storages: []const Entity` slice is populated
3. Each child's `EIS.workstation`/`IIS.workstation`/etc. back-reference is auto-set from the parent

```zig
// Workstation component definition
pub fn onReady(payload: engine.ComponentPayload) void {
    const game = payload.getGame(MyGame);
    const entity = engine.entityFromU64(payload.entity_id);
    const reg = game.getRegistry();
    const ws = reg.getComponent(entity, Workstation);

    var eis = StorageSlots{};
    var iis = StorageSlots{};
    var ios = StorageSlots{};
    var eos = StorageSlots{};

    for (ws.storages) |child| {
        if (reg.has(EIS, child)) eis.append(child);
        if (reg.has(IIS, child)) iis.append(child);
        if (reg.has(IOS, child)) ios.append(child);
        if (reg.has(EOS, child)) eos.append(child);
    }

    ws.eis_slots = eis;
    ws.iis_slots = iis;
    ws.ios_slots = ios;
    ws.eos_slots = eos;
}
```

No init scripts needed. No engine changes required.

### Item Prefabs

Items are plain entities. Dangling items in the scene use:

```zon
.flour_1 = .{ .components = .{
    .Position = .{ .x = 50, .y = 80 },
    .Item = .{ .item_type = .food },
    .Shape = .{ ... },
}},
```

No `DanglingItem` component needed — an `Item` without `Stored` or `Locked` is dangling by definition.

### Worker Prefabs

```zon
// prefabs/baker.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Shape = .{ ... },
        .Worker = .{},
        .CurrentTask = .{ .idle = {} },
        .Needs = .{ .thirst = 100, .hunger = 100 },  // Phase 4
    },
}
```

Workers start idle. The scheduler picks them up on the first frame.

## 6.3 Open Questions

1. ~~**EOS→EIS transport**~~: **Resolved** — generalize `Delivering` with an optional `source_storage` field. The scheduler treats EOS items as available for relocation alongside dangling items. Destination can be any EIS or standalone storage. See [04-scheduler-and-delivery.md](04-scheduler-and-delivery.md) section 4.2.

2. ~~**StorageSlots population**~~: **Resolved** — use the engine's `onReady` callback (RFC #169). `Workstation.onReady` fires after all children are spawned and the `storages` slice is populated. It walks children, checks for `EIS`/`IIS`/`IOS`/`EOS` markers, and populates `StorageSlots`. No init script needed, no engine changes. The prefab structure stays almost identical to the current format — `Storage.role` is split into a separate marker component.

3. ~~**Movement ownership**~~: **Resolved** — the game-side movement script owns all position interpolation, hierarchy attach/detach, and arrival detection. When a worker arrives at a destination or a processing timer completes, the movement script adds `TaskComplete {}` to the worker. `TaskCompletionSystem` handles the state transition. `WorkerExecutionSystem` is eliminated — its responsibilities are split between the game movement script (movement, arrival, timers) and `TaskCompletionSystem` (state routing).

## 6.4 Risk Areas

- **Prefab component registration**: all new components (`EIS`, `IIS`, `IOS`, `EOS`, `WithItem`, `Locked`, `WorkingOn`, `Delivering`, `CurrentTask`, `TaskComplete`, `ReadyToWork`, `FilledNeed`) must be registered in the engine's component registry. Missing registrations cause silent failures.
- **StorageSlots initialization order**: `Workstation.eis/iis/ios/eos` must be populated before the first scheduler tick. If the scene load hook runs after the first frame, workers may see workstations with empty slots.
- **Item destruction during process**: `TaskCompletionSystem` destroys IIS items by removing components. The game must also clean up visual entities (shapes, sprites). This requires a game-side hook or a rendering system that reacts to component removal.
