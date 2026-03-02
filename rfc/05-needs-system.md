# 5. Needs System (Phase 4)

## 5.1 Overview

Workers have decaying needs that compete with productive work. The needs system adds urgency-based interruption to the scheduling priority.

This is additive — the workstation pipeline and scheduler work without it. Needs integration is Phase 4 of the migration.

## 5.2 Need Decay

```
Needs { thirst: f32, hunger: f32 }
```

Both values start at 100 and drain by `drain_rate * dt` each frame (drain_rate = 1.0/s). `NeedsDecaySystem` compares old vs. new level after each drain and adds/removes threshold markers only on boundary crossings.

### Thresholds

| Level | Range | Behavior |
|---|---|---|
| Normal | > 50 | No action |
| Yellow | 10–50 | `FilledNeed` signal at cycle boundary |
| Red | < 10 | Interrupt current task immediately |

When both thirst and hunger are yellow, the lower value wins. If equal, thirst takes priority.

## 5.3 Need Fulfillment

Each need type has a fixed step sequence:

### Drinking (2 steps)
1. `go_to(water_source)` — walk to nearest water entity
2. `process(3.0s)` — drink, restores thirst to 100

### Eating (4 steps)
1. `pick_up(food)` — walk to food, lock it
2. `go_to(table)` — walk to table carrying food
3. `deliver(food, table)` — place food on table, unlock it
4. `process(5.0s)` — eat, restores hunger to 100

### Sleeping (2 steps)
1. `go_to(bed)` — walk to bed entity
2. `process(8.0s)` — sleep, restores sleep value

## 5.4 Need Creation

When the scheduler decides to address a need:

1. Find the nearest available resource (water source, food item, bed)
2. Lock the resource immediately to prevent double-claiming
3. Create a `Need` component on the worker with the appropriate `NeedImpl`
4. Convert the first step to a `CurrentTask` and assign it

## 5.5 Yellow Need Signal

`NeedsEvaluationSystem` checks resource availability each frame. For workers with yellow-level needs:

- If the resource is available, add `FilledNeed { .need_type }` to the worker
- If the resource becomes unavailable, remove `FilledNeed`

`TaskCompletionSystem` checks for `FilledNeed` at workstation cycle boundaries. If present, the worker is released to address their need instead of starting a new cycle.

## 5.6 Red Need Interruption

When a worker crosses into red level:

1. `NeedsDecaySystem` adds the red threshold marker (`RedThirst` or `RedHunger`)
2. `NeedsEvaluationSystem` queries workers with red markers
3. If the resource is available, call `interruptWorker` (see [04-scheduler-and-delivery.md](04-scheduler-and-delivery.md))
4. Create the need and assign the first step

If the resource is not available, the worker is not interrupted (can't address the need anyway).
