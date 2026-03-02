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
// prefabs/oven.zon (current)
.{
    .components = .{
        .Position = .{ .x = 200, .y = 100 },
        .Shape = .{ ... },
        .Workstation = .{ .process_duration = 5 },
    },
    .children = .{
        .eis_flour = .{ .components = .{
            .Position = .{ .x = -20, .y = 0 },
            .Storage = .{ .role = .eis, .accepts = .Flour },
        }},
        // ...
    },
}
```

### Target Prefab Format (ECS-native)

```zon
// prefabs/oven.zon (target)
.{
    .components = .{
        .Position = .{ .x = 200, .y = 100 },
        .Shape = .{ ... },
        .Workstation = .{
            .workstation_type = .kitchen,
            .process_duration = 5,
        },
    },
    .children = .{
        .eis_flour = .{ .components = .{
            .Position = .{ .x = -20, .y = 0 },
            .Storage = .{ .accepted_items = .{ .food = true } },
            .EIS = .{},
        }},
        .iis_flour = .{ .components = .{
            .Position = .{ .x = -10, .y = 0 },
            .Storage = .{ .accepted_items = .{ .food = true } },
            .IIS = .{},
        }},
        .ios_bread = .{ .components = .{
            .Position = .{ .x = 10, .y = 0 },
            .Storage = .{ .accepted_items = .{ .food = true } },
            .IOS = .{},
        }},
        .eos_bread = .{ .components = .{
            .Position = .{ .x = 20, .y = 0 },
            .Storage = .{ .accepted_items = .{ .food = true } },
            .EOS = .{},
        }},
    },
}
```

Key differences:
- Storage role is a separate marker component (`EIS`, `IIS`, `IOS`, `EOS`) instead of a `.role` field
- `Storage.accepted_items` uses `EnumSet(ItemType)` instead of a single `accepts` value
- `Workstation` gains `workstation_type` field
- `StorageSlots` (the link from workstation to its storage entities) must be resolved at scene load time from the parent-child hierarchy

### StorageSlots Resolution

The `Workstation` component's `eis`, `iis`, `ios`, `eos` `StorageSlots` fields must be populated after the scene/prefab spawns the entity hierarchy. Two approaches:

1. **Scene load hook**: after all entities are spawned, iterate workstation children and populate `StorageSlots` based on which role marker each child has. This runs once.
2. **Prefab inline**: declare storage entity IDs directly in the prefab. This requires the prefab system to support forward entity references.

Option 1 is simpler and doesn't require prefab system changes.

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

1. **EOS→EIS transport**: should this be a scheduler-level task (explicit "restock" assignment) or happen naturally through the dangling item path (items removed from EOS become dangling, scheduler delivers to matching EIS)? The dangling path requires someone to first remove items from EOS.

2. **StorageSlots population**: scene load hook (option 1) requires a one-time initialization script. Can this be integrated into the engine's prefab `onCreate` hook?

3. **Movement ownership**: should `WorkerExecutionSystem` handle all movement (including interpolation), or should it only set destinations while a game-side script handles the actual position updates? The latter preserves the current separation of concerns.

## 6.4 Risk Areas

- **Prefab component registration**: all new components (`EIS`, `IIS`, `IOS`, `EOS`, `WithItem`, `Locked`, `WorkingOn`, `Delivering`, `CurrentTask`, `TaskComplete`, `ReadyToWork`, `FilledNeed`) must be registered in the engine's component registry. Missing registrations cause silent failures.
- **StorageSlots initialization order**: `Workstation.eis/iis/ios/eos` must be populated before the first scheduler tick. If the scene load hook runs after the first frame, workers may see workstations with empty slots.
- **Item destruction during process**: `TaskCompletionSystem` destroys IIS items by removing components. The game must also clean up visual entities (shapes, sprites). This requires a game-side hook or a rendering system that reacts to component removal.
