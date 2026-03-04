const items = @import("../enums/items.zig");

/// Internal Output Storage — output buffer at workstation.
pub const Ios = struct {
    workstation: u64 = 0,
    item_type: ?items.Items = null,
};
