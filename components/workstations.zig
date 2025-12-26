// Workstation types container for the bakery game
// Individual workstation components are in separate files

const tasks = @import("labelle-tasks");

// Re-export all workstation types from this module
pub const Workstations = struct {
    pub const Oven = tasks.TaskWorkstation(1, 2, 1, 1);
    pub const Mixer = tasks.TaskWorkstation(2, 2, 1, 1);
    pub const CakeOven = tasks.TaskWorkstation(3, 3, 1, 1);
    pub const Well = tasks.TaskWorkstation(0, 0, 1, 1);
};
