const std = @import("std");
const items = @import("../enums/items.zig");

/// Declares which item types a storage slot accepts.
pub const Storage = struct {
    accepted_items: std.EnumSet(items.Items) = .{},
};
