const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // labelle-core dependency
    const labelle_core_dep = b.dependency("labelle-core", .{ .target = target, .optimize = optimize });
    const labelle_core_mod = labelle_core_dep.module("labelle-core");

    // Main module
    const pathfinder_mod = b.addModule("pathfinder", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pathfinder_mod.addImport("labelle-core", labelle_core_mod);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("pathfinder", pathfinder_mod);
    test_mod.addImport("labelle-core", labelle_core_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
