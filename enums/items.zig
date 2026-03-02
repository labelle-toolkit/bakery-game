// Item types for the bakery game

pub const Items = enum {
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
