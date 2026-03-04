const engine = @import("labelle-engine");
const Entity = engine.Entity;

/// Marks a workstation entity. Storages are nested as children via the
/// prefab's storages field. StorageSlots are populated at load time by onReady.
pub const Workstation = struct {
    workstation_type: WorkstationType = .kitchen,
    process_duration: u32 = 60,
    storages: []const Entity = &.{},

    // Runtime-only fields, populated by onReady from child role markers.
    eis_slots: StorageSlots = .{},
    iis_slots: StorageSlots = .{},
    ios_slots: StorageSlots = .{},
    eos_slots: StorageSlots = .{},

    pub fn isProducer(self: *const Workstation) bool {
        return self.eis_slots.len == 0 and self.iis_slots.len == 0;
    }
};

/// Holds up to 4 storage entity IDs per role.
pub const StorageSlots = struct {
    items: [4]u64 = .{ 0, 0, 0, 0 },
    len: u32 = 0,

    pub fn slice(self: *const StorageSlots) []const u64 {
        return self.items[0..self.len];
    }

    pub fn append(self: *StorageSlots, id: u64) void {
        if (self.len < self.items.len) {
            self.items[self.len] = id;
            self.len += 1;
        }
    }
};

/// Workstation types available in the game.
pub const WorkstationType = enum {
    sawmill,
    furnace,
    kitchen,
};
