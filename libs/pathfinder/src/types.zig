const std = @import("std");

pub const NodeId = u32;

pub const Position = @import("labelle-core").Position;

pub const INF: f32 = std.math.inf(f32);

/// Euclidean distance between two positions (ignores rotation).
pub fn distanceBetween(a: Position, b: Position) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}
