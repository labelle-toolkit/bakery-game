// Worker component
// Entities that can perform tasks at workstations

const tasks = @import("labelle-tasks");

pub const Worker = struct {
    /// Priority for worker selection (higher = preferred)
    priority: tasks.Priority = .Normal,
};
