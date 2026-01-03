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
