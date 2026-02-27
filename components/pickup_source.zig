/// Tracks which storage a worker is currently picking from.
/// Replaces the worker_pickup_storage HashMap.
/// Set on: worker entities when pickup_started hook fires.
/// Removed when: pickup completes or fails.
pub const PickupSource = struct {
    storage_id: u64,
};
