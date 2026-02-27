/// Marker component for workers that need to move to workstation before starting work.
/// Replaces the worker_pending_arrival HashMap.
/// Set on: worker entities when assigned to workstation.
/// Removed when: worker arrives at workstation.
pub const PendingArrival = struct {
    _padding: u8 = 0,
};
