// Work progress tracking component
//
// Attached to workers when they're processing at a workstation.
// Tracks accumulated work time and target duration.

/// Tracks work progress for a worker at a workstation.
/// Attached when process_started is received, removed when work completes.
pub const WorkProgress = struct {
    /// The workstation being worked on
    workstation_id: u64,
    /// Accumulated work time in frames
    accumulated: u32 = 0,
    /// Target duration in frames (from workstation.process_duration)
    duration: u32,

    /// Check if work is complete
    pub fn isComplete(self: WorkProgress) bool {
        return self.accumulated >= self.duration;
    }

    /// Tick the work progress by one frame
    pub fn tick(self: *WorkProgress) void {
        self.accumulated += 1;
    }
};
