/// Tracks which workstation a worker is assigned to.
/// Replaces the worker_workstation HashMap.
/// Set on: worker entities when assigned by task engine.
/// Removed when: worker is released from workstation.
pub const AssignedWorkstation = struct {
    workstation_id: u64,
};
