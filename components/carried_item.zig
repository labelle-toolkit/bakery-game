/// Tracks which item entity a worker is carrying.
/// Replaces the worker_carried_items HashMap.
/// Set on: worker entities when picking up an item.
/// Removed when: item is delivered or consumed.
pub const CarriedItem = struct {
    item_entity: u64,
};
