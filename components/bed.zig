// Bed component — re-exports labelle-needs Facility component
//
// This provides the Bed type alias for use in scene files and the
// component registry. Under the hood it's the Facility component
// from labelle-needs.

const labelle_needs = @import("labelle-needs");

pub const Bed = labelle_needs.Facility;
