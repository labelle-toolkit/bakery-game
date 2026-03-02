# 1. Overview

## 1.1 Motivation

The bakery-game currently integrates `labelle-tasks` as a plugin. The plugin uses an event-driven hook system: the task engine emits hooks (`worker_assigned`, `pickup_started`, `process_started`, etc.) and the game responds by setting `MovementTarget` components and calling back via a `Context` API (`pickupCompleted`, `workCompleted`, etc.).

This creates several problems:

- **Shadow state**: `task_hooks.zig` maintains 7 global HashMaps (`worker_carried_items`, `worker_workstation`, `worker_pickup_storage`, `worker_store_target`, `worker_pending_arrival`, `dangling_item_targets`, `storage_items`) to mirror what the task engine tracks internally. These maps must be kept in sync manually.
- **Two-way notification**: scripts must call `Context.pickupCompleted()`, `Context.workCompleted()`, etc. at the right time. Missing or misordering a call causes silent state corruption.
- **Manual workarounds**: `eos_transport.zig` implements EOS-to-EIS transport entirely outside the task engine. `task_initializer.zig` manually registers workers on scene load.
- **Opaque engine state**: the task engine's internal state is not directly queryable from ECS. Debugging requires inspecting both ECS components and the plugin's internal state.

## 1.2 Target Architecture

Replace the plugin with **6 ECS systems** that run every frame in fixed order:

1. **NeedsDecaySystem** — drains thirst/hunger, adds/removes threshold marker components
2. **NeedsEvaluationSystem** — red needs interrupt workers; yellow needs signal via `FilledNeed`
3. **WorkerExecutionSystem** — moves workers, ticks processing timers
4. **TaskCompletionSystem** — routes finished tasks through workstation/need/delivery pipelines
5. **WorkstationReadinessSystem** — adds/removes `ReadyToWork` marker on workstations
6. **SchedulerSystem** — assigns idle workers by priority

All worker, item, and workstation state lives in ECS components. No external engine, no callbacks, no shadow maps.

## 1.3 Scheduling Priority

1. **Fighting** — external event, overrides everything
2. **Red need** (< 10) — interrupt current task immediately
3. **Yellow need** (10–50) — signal workstation to release worker at next cycle boundary
4. **Workstation** — nearest available with `ReadyToWork` marker
5. **Dangling item delivery** — nearest unowned item with matching empty storage
6. **Idle** — random wander

## 1.4 Design Principles

- **Prefab-first**: every entity (worker, workstation, storage, item, water source, bed, table) must be fully definable through `.zon` prefab files. No runtime-only component setup.
- All state is ECS-queryable — no opaque engine internals
- Systems are stateless functions that read/write components — no side-channel communication
- Marker components (`ReadyToWork`, `YellowThirst`, `TaskComplete`) act as query filters to avoid full-world scans
- Locking is symmetric: `Locked{ .by = entity_id }` on both sides of every claim
- Item state is determined entirely by component composition (see [02-components.md](02-components.md))
- The game owns rendering and movement interpolation; systems own scheduling and state transitions
