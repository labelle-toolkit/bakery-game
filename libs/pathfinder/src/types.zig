const std = @import("std");

pub const NodeId = u32;

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn distanceTo(self: Vec2, other: Vec2) f32 {
        const dx = other.x - self.x;
        const dy = other.y - self.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

pub const INF: f32 = std.math.inf(f32);
