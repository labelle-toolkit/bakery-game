# 3. Workstation Pipeline

## 3.1 Storage Layout

Each workstation has up to 4 storage entities per role:

```
EIS → IIS → [Process] → IOS → EOS
```

- **EIS** (External Input Storage) — world-facing raw materials
- **IIS** (Internal Input Storage) — input buffer at workstation
- **IOS** (Internal Output Storage) — output buffer at workstation
- **EOS** (External Output Storage) — world-facing finished products

Producer workstations (water well) have no EIS/IIS. They skip the pickup phase and start directly at process.

### Storage State

| State | Components on storage entity |
|---|---|
| Empty, available | `Storage` + role marker |
| Holding item | `Storage` + role marker + `WithItem { .item_id }` |
| Reserved | `Storage` + role marker + `Locked { .by }` |
| Holding + reserved | `Storage` + role marker + `WithItem` + `Locked` |

## 3.2 Worker Phases

A worker assigned to a workstation goes through three phases:

### 3.2.1 Pickup (non-producers only)

Fill IIS from EIS. Each carry is a 2-phase operation:

1. Walk to EIS (source) — `CurrentTask.going_to_workstation`
2. Pick up item — remove `WithItem` from EIS, remove `Stored` from item, add `Locked` to item
3. Walk to IIS (dest) — `CurrentTask.carrying_item`
4. Deliver item — add `Stored` to item, add `WithItem` to IIS, remove `Locked` from item

`WorkingOn.source/dest/item` track mid-carry state. Repeat for each EIS→IIS pair. When all IIS are filled (or no more EIS items), advance to process.

### 3.2.2 Process

1. Consume all IIS items — destroy item entities (remove `Item`, `Position`, `Stored`, `Locked`)
2. Start processing timer — `CurrentTask.processing { .duration = workstation.process_duration }`
3. On completion, create new item entities in each IOS — position at IOS storage, type from `Storage.accepted_items`

### 3.2.3 Store

Move IOS items to EOS. Mirror of pickup:

1. Walk to IOS (source)
2. Pick up item from IOS
3. Walk to EOS (dest)
4. Deliver item to EOS

Repeat for each IOS→EOS pair. When all IOS are empty, the cycle is complete.

## 3.3 Cycle Completion

When a store phase completes, `TaskCompletionSystem` checks in order:

1. **FilledNeed present?** — release worker to address their need (even if more work is available)
2. **Producer workstation?** — restart at process phase
3. **EIS has items?** — restart at pickup phase
4. **Otherwise** — release worker (remove `WorkingOn`, unlock both, `CurrentTask.idle`)

## 3.4 Bakery-Game Workstations

### Oven (non-producer)

```
EIS: [Flour, Water]
IIS: [Flour, Water]
IOS: [Bread]
EOS: [Bread]
Process duration: 5.0s
```

Worker picks up Flour and Water from EIS, delivers to IIS, processes for 5s, creates Bread in IOS, delivers to EOS.

### Water Well (producer)

```
EIS: (none)
IIS: (none)
IOS: [Water]
EOS: [Water, Water, Water, Water]
Process duration: 3.0s
```

No inputs. Processes for 3s, creates Water in IOS, delivers to EOS. Restarts at process when EOS has space.

## 3.5 Readiness

`WorkstationReadinessSystem` evaluates every workstation each frame:

- **Producers**: ready when all IOS are empty AND at least one EOS is empty and unlocked
- **Non-producers**: ready when ALL EIS have `WithItem` AND are unlocked AND at least one EOS is empty and unlocked

Only workstations with `ReadyToWork` are visible to the scheduler.
