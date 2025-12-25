// Item types for the bakery game

pub const ItemType = enum {
    // Raw ingredients
    Flour,
    Water,
    Yeast,
    Sugar,
    Butter,
    Eggs,

    // Intermediate products
    Dough,
    BatterMix,

    // Final products
    Bread,
    Croissant,
    Cake,
    Cookie,
};

// Alias for component registry
pub const Items = ItemType;

// Re-export storage components
const storage = @import("storage.zig");
pub const Storage = storage.Storage;
pub const StorageType = storage.StorageType;
pub const Slot = storage.Slot;
pub const Workstation = storage.Workstation;
pub const Worker = storage.Worker;
