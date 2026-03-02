# RFC: Replace labelle-tasks with ECS-native architecture

**Status**: Draft

Migrate bakery-game from the `labelle-tasks` plugin (hook/callback-based) to an ECS-native worker scheduling architecture based on `tasks-and-needs`. This eliminates the bidirectional Game <-> TaskEngine notification pattern and shadow state in favor of pure ECS component composition and frame-driven systems.

## Table of Contents

1. [Overview](01-overview.md) — motivation, current pain points, target architecture
2. [Components](02-components.md) — component mapping from labelle-tasks to ECS-native
3. [Workstation Pipeline](03-workstation-pipeline.md) — EIS/IIS/IOS/EOS storage model and worker phases
4. [Scheduler and Delivery](04-scheduler-and-delivery.md) — priority-based assignment, dangling item delivery
5. [Needs System](05-needs-system.md) — need decay, thresholds, interruption (Phase 4)
6. [Migration Plan](06-migration-plan.md) — phased migration steps, file-level changes, risk areas
