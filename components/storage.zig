// Storage types container for bakery game
// Individual storage components are in separate files

const tasks = @import("labelle-tasks");

// Container type for all storage-related utilities
pub const Storage = struct {
    pub const Role = tasks.StorageRole;
    pub const Priority = tasks.Priority;
};
