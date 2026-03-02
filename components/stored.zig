/// Present on an item entity when it sits in a storage slot.
/// Absence of Stored combined with Locked means the item is being carried.
pub const Stored = struct {
    storage_id: u64,
};
