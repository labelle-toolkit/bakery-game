const items = @import("../enums/items.zig");

/// External Input Storage — world-facing raw materials.
pub const Eis = struct {
    workstation: u64 = 0,
    item_type: ?items.Items = null,
};
