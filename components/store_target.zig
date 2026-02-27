/// Tracks the target EOS for a worker's store step.
/// Replaces the worker_store_target HashMap.
/// Set on: worker entities when store_started hook fires.
/// Removed when: store delivery completes.
pub const StoreTarget = struct {
    storage_id: u64,
};
