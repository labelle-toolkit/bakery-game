const items = @import("../enums/items.zig");

/// Marks an entity as an item. Item state is determined by component composition:
/// - Item only → Dangling (on the ground, unowned)
/// - Item + Stored → In storage
/// - Item + Stored + Locked → Reserved (will be picked up)
/// - Item + Locked → Being carried
pub const Item = struct {
    item_type: items.Items,
};
