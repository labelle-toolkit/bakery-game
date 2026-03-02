/// Binds a worker to a workstation. source/dest/item track mid-carry state.
pub const WorkingOn = struct {
    workstation_id: u64,
    step: WorkstationStep = .pickup,
    source: ?u64 = null,
    dest: ?u64 = null,
    item: ?u64 = null,
};

/// Workstation phase the worker is currently in.
pub const WorkstationStep = enum {
    pickup,
    process,
    store,
};
