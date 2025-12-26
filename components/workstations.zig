// Workstation types for the bakery game
// Each workstation type defines specific storage counts

const tasks = @import("labelle-tasks");

/// Simple oven: 1 EIS (flour), 2 IIS (2 flour = 1 bread), 1 IOS, 1 EOS
pub const OvenWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);

/// Mixer: 2 EIS (flour + water), 2 IIS, 1 IOS (dough), 1 EOS
pub const MixerWorkstation = tasks.TaskWorkstation(2, 2, 1, 1);

/// Advanced oven for cakes: 3 EIS (flour, eggs, sugar), 3 IIS, 1 IOS, 1 EOS
pub const CakeOvenWorkstation = tasks.TaskWorkstation(3, 3, 1, 1);

/// Well (producer): no inputs, produces water
pub const WellWorkstation = tasks.TaskWorkstation(0, 0, 1, 1);
