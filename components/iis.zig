const items = @import("../enums/items.zig");

/// Internal Input Storage — input buffer at workstation.
pub const Iis = struct {
    workstation: u64 = 0,
    item_type: ?items.Items = null,
};
