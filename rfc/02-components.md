# 2. Components

## 2.1 Component Mapping

What changes from `labelle-tasks` to ECS-native:

| labelle-tasks (current) | ECS-native (target) | Notes |
|---|---|---|
| `Worker = {}` | `Worker = {}` | Unchanged — zero-size marker |
| `Storage { .role, .accepts }` | `Storage { .accepted_items }` + role markers | Role becomes separate zero-size components |
| `Storage.role = .eis` | `EIS { .workstation_id }` | Back-reference to owning workstation |
| `Storage.role = .iis` | `IIS { .workstation_id }` | Back-reference to owning workstation |
| `Storage.role = .ios` | `IOS { .workstation_id }` | Back-reference to owning workstation |
| `Storage.role = .eos` | `EOS { .workstation_id }` | Back-reference to owning workstation |
| `Workstation { .process_duration, .storages }` | `Workstation { .workstation_type, .process_duration, .eis, .iis, .ios, .eos }` | StorageSlots per role instead of flat array |
| `DanglingItem { .item_type }` | `Item { .item_type }` (no `Stored`, no `Locked`) | State determined by component composition |
| `MovementTarget { .action }` | `CurrentTask` (tagged union) | Action enum replaced by task union |
| `WorkProgress { .duration }` | `CurrentTask.processing { .duration }` | Timer integrated into task |
| `task_hooks.worker_carried_items` map | `Locked { .by }` on item | ECS-native |
| `task_hooks.worker_workstation` map | `WorkingOn { .workstation_id }` | ECS-native |
| `task_hooks.storage_items` map | `WithItem { .item_id }` on storage | ECS-native |
| `task_hooks.dangling_item_targets` map | `Delivering { .item_id, .storage_id }` | ECS-native |
| (no equivalent) | `FilledNeed { .need_type }` | New — yellow need signal |
| (no equivalent) | `Needs { .thirst, .hunger }` | New — need values (Phase 4) |
| (no equivalent) | `Need { .need_impl, .current_step }` | New — active need (Phase 4) |

## 2.2 Core Components

### Position

```
Position { x: f32, y: f32 }
```

On workers, items, workstations, and storage entities. Systems resolve destination positions from target entity's `Position`.

### Locked

```
Locked { by: EntityId }
```

Mutual-exclusion primitive. Applied to items, workers, workstations, and storage entities. Always symmetric — when a worker locks a workstation, both get `Locked{ .by = other }`. Released via `releaseWorker`.

### Item

```
Item { item_type: ItemType }
```

Marks an entity as an item. Item state is determined entirely by which other components are present:

| State | Components |
|---|---|
| In storage | `Item` + `Stored` |
| Reserved | `Item` + `Stored` + `Locked` |
| Carried | `Item` + `Locked` |
| Dangling | `Item` only |

### Stored

```
Stored { storage_id: EntityId }
```

Present on an item entity when it sits in a storage slot. Absence of `Stored` combined with `Locked` means the item is being carried.

### WithItem

```
WithItem { item_id: EntityId }
```

Present on a storage entity when it holds an item. Kept in sync with `Stored` on the item.

## 2.3 Worker State Components

### CurrentTask

```
CurrentTask = union(enum) {
    idle,
    wandering: { destination: Vector2 },
    walking: { destination: Vector2 },
    going_to_workstation: { workstation_id: EntityId },
    carrying_item: { destination: EntityId },
    processing: { duration: f32 },
    filling_need,
    fighting,
}
```

The active task a worker is executing. `WorkerExecutionSystem` reads this each frame and advances the worker. On completion, a `TaskComplete` marker is added.

### WorkingOn

```
WorkingOn {
    workstation_id: EntityId,
    step: WorkstationStep,  // pickup, process, store
    source: ?EntityId,
    dest: ?EntityId,
    item: ?EntityId,
}
```

Binds a worker to a workstation. `source`/`dest`/`item` track the current 2-phase carry. If `item` is set and has `Stored`, the worker arrived at the source; without `Stored`, arrived at the destination.

### Delivering

```
Delivering {
    item_id: EntityId,
    storage_id: EntityId,
    current_step: u32,  // 0 = walk to item, 1 = carry to storage
}
```

Tracks a worker delivering a dangling item to a standalone storage.

### TaskComplete

```
TaskComplete = struct {}
```

Zero-size marker. Added by `WorkerExecutionSystem` when a task finishes. Consumed by `TaskCompletionSystem`.

### FilledNeed

```
FilledNeed { need_type: NeedType }
```

Signal component placed on a worker when a yellow-level need is active and the resource is available. Checked at workstation cycle boundary — if present, the worker is released to address their need.

## 2.4 Workstation Components

### Workstation

```
Workstation {
    workstation_type: WorkstationType,
    process_duration: f32,
    eis: StorageSlots,
    iis: StorageSlots,
    ios: StorageSlots,
    eos: StorageSlots,
}
```

Each `StorageSlots` holds up to 4 entity IDs. `isProducer()` returns true when `eis.len == 0 and iis.len == 0`.

### ReadyToWork

```
ReadyToWork = struct {}
```

Zero-size marker managed by `WorkstationReadinessSystem`. The scheduler only considers workstations with this marker.

## 2.5 Storage Role Markers

```
EIS { workstation_id: EntityId }
IIS { workstation_id: EntityId }
IOS { workstation_id: EntityId }
EOS { workstation_id: EntityId }
```

Zero-size in spirit but carry a back-reference to the owning workstation. Combined with `Storage { .accepted_items }` on the same entity. Enable direct ECS query filtering by storage role.

## 2.6 Threshold Markers (Phase 4)

```
YellowThirst = struct {}
YellowHunger = struct {}
RedThirst = struct {}
RedHunger = struct {}
```

Zero-size markers added/removed by `NeedsDecaySystem` only on boundary crossings. Used as ECS query filters so `NeedsEvaluationSystem` only processes workers with active needs.
