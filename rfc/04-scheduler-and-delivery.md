# 4. Scheduler and Delivery

## 4.1 Scheduler

`SchedulerSystem` runs after `WorkstationReadinessSystem`. It collects all idle, unlocked workers and calls `schedule()` for each.

### Priority Assignment

For each idle worker, in order:

1. **Check needs** — if `Needs.mostUrgent()` returns a need below normal level and `canAddressNeed()` returns true, create a `Need` component and assign the first step. Lock the resource entity immediately.
2. **Find nearest workstation** — query all `Workstation + Position + ReadyToWork` without `Locked`. Pick the nearest. Lock both worker and workstation mutually.
3. **Find available item for delivery** — find nearest available item (dangling or in EOS) that has a matching empty, unlocked destination storage (not IIS, not IOS). Lock item, destination storage, and worker. Assign `Delivering` component.
4. **Wander** — assign `CurrentTask.wandering` with a deterministic offset from current position.

### Workstation Locking

When a worker is assigned a workstation:
- Worker gets `Locked { .by = workstation_id }`
- Workstation gets `Locked { .by = worker_id }`
- Worker gets `CurrentTask.going_to_workstation { .workstation_id }`

Both locks are released together via `releaseWorker`.

## 4.2 Item Delivery

The scheduler assigns delivery tasks for items that need to reach a storage. Two sources:

1. **Dangling items** — on the ground, no `Stored`, no `Locked`. Created by:
   - Dropped by an interrupted worker (red need or combat)
   - Scene-spawned items (flour, water in bakery-game)
2. **EOS items** — in an EOS storage (`Item + Stored`, storage has `EOS` marker). Available for relocation when not `Locked`.

Both deliver to any matching empty, unlocked storage that is not internal to a workstation (no `IIS`, no `IOS`). Valid destinations are EIS storages and standalone storages.

### Delivery Flow

1. Scheduler finds the nearest available item (dangling or EOS) with a matching empty, unlocked destination storage
2. Lock item, destination storage, and worker upfront. If source is EOS, lock the source storage too.
3. Assign `Delivering { .item_id, .source_storage, .dest_storage, .current_step = 0 }` + `CurrentTask.walking` toward item position

**Step 0** (arrive at item/source):
- If `source_storage` is set (EOS): remove `WithItem` from source storage, remove `Stored` from item, release source storage lock
- Lock item, assign `CurrentTask.carrying_item` toward dest storage

**Step 1** (arrive at dest storage):
- Add `Stored { .storage_id = dest_storage }` to item, add `WithItem { .item_id }` to dest storage
- Release item lock, dest storage lock, and worker lock

### Item and Storage Matching

`findAvailableItemAndStorage` scans two pools:

**Dangling items**: `Item + Position` without `Stored` or `Locked`

**EOS items**: `Item + Stored` where the storage entity has an `EOS` marker and no `Locked`

**Destination storages**: `Storage + Position` without `WithItem`, `Locked`, `IIS`, or `IOS`, where `Storage.accepted_items` contains the item's `ItemType`

Priority is nearest item to the worker. For items with multiple valid destinations, the first matching storage is selected.

## 4.3 Interruption

`interruptWorker` is called when a red-level need must be addressed immediately:

1. Drop all items locked by this worker — remove `Locked` from items. Items without `Stored` become dangling.
2. If worker has `WorkingOn` — unlock workstation (remove `Locked` from both)
3. Remove `WorkingOn`, `Need`, `FilledNeed`, `Delivering` from worker
4. Call `releaseWorker` — remove `Locked` from worker and whatever it was locked by
5. Assign the new need

Dropped items will be picked up later by the scheduler's dangling delivery path.

## 4.4 EOS-to-EIS Transport (replaces eos_transport.zig)

In the current bakery-game, `eos_transport.zig` manually scans for idle workers and moves items from EOS to EIS with 3 extra HashMaps. This is replaced by the unified delivery system described in 4.2.

EOS items are treated as available for relocation — the same `Delivering` component and scheduler scan handles both dangling items and EOS items. When the Water Well produces Water and places it in EOS, the scheduler sees an EOS item matching the Oven's empty EIS and assigns a delivery. No separate script needed.
