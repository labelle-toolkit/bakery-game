/// The active task a worker is executing. The game movement script reads
/// this each frame to move the worker. On completion, a TaskComplete marker
/// is added by the movement script.
pub const CurrentTask = union(enum) {
    idle,
    wandering: struct { dest_x: f32, dest_y: f32 },
    walking: struct { dest_x: f32, dest_y: f32 },
    going_to_workstation: struct { workstation_id: u64 },
    carrying_item: struct { item_id: u64, destination_id: u64 },
    processing: struct { duration: f32 },
    filling_need,
    fighting,
};
