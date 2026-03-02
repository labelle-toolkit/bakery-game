# 4. Scheduler and Delivery

## 4.1 Scheduler

`SchedulerSystem` runs after `WorkstationReadinessSystem`. It collects all idle, unlocked workers and calls `schedule()` for each.

### Priority Assignment

For each idle worker, in order:

1. **Check needs** — if `Needs.mostUrgent()` returns a need below normal level and `canAddressNeed()` returns true, create a `Need` component and assign the first step. Lock the resource entity immediately.
2. **Find nearest workstation** — query all `Workstation + Position + ReadyToWork` without `Locked`. Pick the nearest. Lock both worker and workstation mutually.
3. **Find dangling item delivery** — find nearest `Item` without `Stored` or `Locked` that has a matching empty, unlocked standalone storage (not IIS, not IOS). Lock item, storage, and worker. Assign `Delivering` component.
4. **Wander** — assign `CurrentTask.wandering` with a deterministic offset from current position.

### Workstation Locking

When a worker is assigned a workstation:
- Worker gets `Locked { .by = workstation_id }`
- Workstation gets `Locked { .by = worker_id }`
- Worker gets `CurrentTask.going_to_workstation { .workstation_id }`

Both locks are released together via `releaseWorker`.

## 4.2 Dangling Item Delivery

Items become dangling when:
- Dropped by an interrupted worker (red need or combat)
- Created as scene entities (flour, water in bakery-game)
- Output placed in a full EOS area

A dangling item is an entity with `Item` but without `Stored` or `Locked`.

### Delivery Flow

1. Scheduler finds nearest dangling item with a matching empty, unlocked storage
2. Lock item, storage, and worker upfront
3. Assign `Delivering { .item_id, .storage_id, .current_step = 0 }` + `CurrentTask.walking` toward item
4. **Step 0** (arrive at item): remove `Stored` if present, add `Locked` to item, assign `CurrentTask.carrying_item` toward storage
5. **Step 1** (arrive at storage): add `Stored` to item, add `WithItem` to storage, release storage lock, release worker

### Storage Matching

`findDanglingItemAndStorage` checks:
- Storage has `Storage.accepted_items` containing the item's `ItemType`
- Storage has no `WithItem` (empty)
- Storage has no `Locked` (not reserved)
- Storage has no `IIS` or `IOS` marker (standalone or EIS/EOS only)

## 4.3 Interruption

`interruptWorker` is called when a red-level need must be addressed immediately:

1. Drop all items locked by this worker — remove `Locked` from items. Items without `Stored` become dangling.
2. If worker has `WorkingOn` — unlock workstation (remove `Locked` from both)
3. Remove `WorkingOn`, `Need`, `FilledNeed`, `Delivering` from worker
4. Call `releaseWorker` — remove `Locked` from worker and whatever it was locked by
5. Assign the new need

Dropped items will be picked up later by the scheduler's dangling delivery path.

## 4.4 EOS-to-EIS Transport (replaces eos_transport.zig)

In the current bakery-game, `eos_transport.zig` manually scans for idle workers and moves items from EOS to EIS of another workstation. This is a workaround because `labelle-tasks` doesn't handle cross-workstation transport.

In the ECS-native architecture, this happens naturally:

1. Items in EOS are in storage (`Item + Stored`)
2. When a worker retrieves an item from EOS, the item leaves storage and may become dangling
3. If a workstation's EIS needs items, `WorkstationReadinessSystem` marks it as not ready
4. The scheduler's dangling delivery path picks up unowned items and routes them to matching empty storages (including EIS)

Alternatively, the scheduler could directly assign EOS→EIS transfers as a workstation restocking task. This is an open design question — see [06-migration-plan.md](06-migration-plan.md).
