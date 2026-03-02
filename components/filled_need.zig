/// Signal component placed on a worker when a yellow-level need is active
/// and the resource is available. Checked at workstation cycle boundary.
pub const FilledNeed = struct {
    need_type: NeedType,
};

/// Need types.
pub const NeedType = enum {
    thirst,
    hunger,
    sleep,
};
