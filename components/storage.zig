// Storage and task components for bakery game
// Re-exports from labelle-tasks with game-specific additions

const tasks = @import("labelle_tasks");

// Re-export core task types
pub const TaskStorage = tasks.TaskStorage;
pub const TaskStorageRole = tasks.TaskStorageRole;
pub const TaskWorkstationBinding = tasks.TaskWorkstationBinding;
pub const StorageRole = tasks.StorageRole;
pub const Priority = tasks.Priority;

// Re-export workstation interface for generic access
pub const WorkstationInterface = tasks.WorkstationInterface;

// Game-specific workstation types
pub const workstations = @import("workstations.zig");
pub const OvenWorkstation = workstations.OvenWorkstation;
pub const MixerWorkstation = workstations.MixerWorkstation;
pub const CakeOvenWorkstation = workstations.CakeOvenWorkstation;
pub const WellWorkstation = workstations.WellWorkstation;

/// Worker component - attach to entities that can perform tasks
pub const Worker = struct {
    /// Priority for worker selection (higher = preferred)
    priority: Priority = .Normal,
};
