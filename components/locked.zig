/// Mutual-exclusion primitive. Applied to items, workers, workstations, and storages.
/// Always symmetric — when a worker locks a workstation, both get Locked{ .by = other }.
pub const Locked = struct {
    by: u64,
};
