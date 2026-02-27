/// Tracks a deferred drink need on a worker who is currently working.
/// Replaces the pending_drink_workers/storages arrays in needs_hooks.zig.
/// Set on: worker entities when drink triggers during work.
/// Removed when: work completes and worker seeks water.
pub const DeferredDrink = struct {
    storage_id: u64,
};
