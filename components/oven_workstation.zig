// Oven workstation component
// Simple oven: 1 EIS (flour), 2 IIS (2 flour = 1 bread), 1 IOS, 1 EOS

const tasks = @import("labelle-tasks");

pub const OvenWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);
