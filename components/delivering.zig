/// Tracks a worker delivering an item to a storage.
/// source_storage is null for dangling items (on the ground), set for EOS items.
/// current_step: 0 = walk to item/source, 1 = carry to dest.
pub const Delivering = struct {
    item_id: u64,
    source_storage: ?u64 = null,
    dest_storage: u64,
    current_step: u32 = 0,
};
