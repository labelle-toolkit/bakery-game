// Storage component for task engine integration
//
// Defines storage configuration that can be used in prefabs.
// The movement script reads these components and registers them with labelle-tasks.

const items = @import("items.zig");
pub const ItemType = items.ItemType;

/// Storage type for task engine
pub const StorageType = enum {
    eis, // External Input Storage (e.g., pantry)
    iis, // Internal Input Storage (workstation input buffer)
    ios, // Internal Output Storage (workstation output buffer)
    eos, // External Output Storage (e.g., shelf)
};

/// Slot configuration for a storage
pub const Slot = struct {
    item: ItemType,
    capacity: u32,
    initial: u32 = 0, // Initial quantity to stock
};

/// Storage component - attach to entities to define task engine storages
pub const Storage = struct {
    /// Unique ID for this storage (used by task engine)
    id: u32,
    /// Type of storage (EIS, IIS, IOS, EOS)
    storage_type: StorageType,
    /// Storage slots (up to 4 items per storage)
    slots: [4]?Slot = .{ null, null, null, null },
    /// Associated workstation ID (for IIS/IOS)
    workstation_id: ?u32 = null,
};

/// Workstation component - attach to entities to define task engine workstations
pub const Workstation = struct {
    /// Unique ID for this workstation
    id: u32,
    /// EIS storage ID (where to pull ingredients)
    eis_id: u32,
    /// IIS storage ID (internal input buffer)
    iis_id: u32,
    /// IOS storage ID (internal output buffer)
    ios_id: u32,
    /// EOS storage ID (where to store output)
    eos_id: u32,
    /// Processing duration in frames
    process_duration: u32 = 120,
};

/// Worker component - attach to entities to define task engine workers
pub const Worker = struct {
    /// Unique ID for this worker
    id: u32,
};
