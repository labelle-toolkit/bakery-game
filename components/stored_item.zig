/// Tracks which item entity is stored at a storage entity.
/// Replaces the storage_items HashMap.
/// Set on: storage entities when an item is placed.
/// Removed when: item is picked up or consumed.
pub const StoredItem = struct {
    item_entity: u64,
};
