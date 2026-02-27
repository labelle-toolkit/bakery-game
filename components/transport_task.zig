/// Tracks an in-flight transport task on a worker.
/// Replaces the worker_transport_from and worker_transport_to HashMaps.
/// Set on: worker entities when transport is assigned.
/// Removed when: transport delivery completes or is cancelled.
pub const TransportTask = struct {
    from_storage: u64,
    to_storage: u64,
};
