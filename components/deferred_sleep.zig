/// Tracks a deferred sleep need on a worker who is currently working.
/// Replaces the pending_sleep_workers/facilities arrays in needs_hooks.zig.
/// Set on: worker entities when sleep triggers during work.
/// Removed when: work completes and worker seeks bed.
pub const DeferredSleep = struct {
    facility_id: u64,
};
