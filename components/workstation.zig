// Workstation component - re-exports from labelle-tasks for generator compatibility
const tasks = @import("labelle-tasks");
const items = @import("items.zig");
pub const Workstation = tasks.Workstation(items.ItemType);
