/// Tracks which EIS a dangling item should be delivered to.
/// Replaces the dangling_item_targets HashMap.
/// Set on: item entities when pickup_dangling_started hook fires.
/// Removed when: delivery completes.
pub const DanglingTarget = struct {
    storage_id: u64,
};
