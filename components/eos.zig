const items = @import("../enums/items.zig");

/// External Output Storage — world-facing finished products.
pub const Eos = struct {
    workstation: u64 = 0,
    item_type: ?items.Items = null,
};
