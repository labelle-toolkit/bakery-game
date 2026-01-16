const std = @import("std");

pub fn build(b: *std.Build) !void {
    // WASM target using Emscripten
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    // Get labelle-engine dependency
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = .raylib,
        .physics = false,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Note: For path-based plugin dependencies that also depend on labelle-engine,
    // we create the module manually to avoid duplicate labelle-engine dependencies
    const labelle_tasks_mod = b.createModule(.{
        .root_source_file = b.path("../../labelle-tasks/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    labelle_tasks_mod.addImport("labelle-engine", engine_mod);
    labelle_tasks_mod.addImport("ecs", engine_dep.module("ecs"));

    // Get raylib_zig for emsdk utilities
    const raylib_zig = @import("raylib_zig");
    const emsdk = raylib_zig.emsdk;

    // Get labelle-gfx from engine to access raylib
    const labelle_gfx_dep = engine_dep.builder.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });

    // Get raylib_zig dependency and raylib artifact
    const raylib_zig_dep = labelle_gfx_dep.builder.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_artifact = raylib_zig_dep.artifact("raylib");

    // Get the actual raylib dependency (raylib_zig depends on raylib)
    const raylib_dep = raylib_zig_dep.builder.dependency("raylib", .{});

    // Create WASM library
    const wasm = b.addLibrary(.{
        .name = "bakery_game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle-tasks", .module = labelle_tasks_mod },
            },
        }),
    });

    const install_dir: std.Build.InstallDir = .{ .custom = "web" };
    var emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
        .optimize = optimize,
        .asyncify = true,
    });

    // Increase stack size to prevent stack overflow (default is 64KB)
    try emcc_flags.put("-sSTACK_SIZE=524288", {}); // 512KB stack

    const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
    });

    // Get the shell.html path from raylib_zig's internal raylib dependency
    const shell_path = raylib_dep.path("src/shell.html");

    const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
        .optimize = optimize,
        .flags = emcc_flags,
        .settings = emcc_settings,
        .shell_file_path = shell_path,
        .install_dir = install_dir,
    });

    // Default build step creates WASM
    b.default_step.dependOn(emcc_step);

    const wasm_step = b.step("wasm", "Build for WebAssembly");
    wasm_step.dependOn(emcc_step);

    // Add emrun step to serve in browser
    const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{"bakery_game"});
    const emrun_step = emsdk.emrunStep(
        b,
        b.getInstallPath(install_dir, html_filename),
        &.{},
    );
    emrun_step.dependOn(emcc_step);

    const serve_step = b.step("serve", "Build and serve in browser");
    serve_step.dependOn(emrun_step);
}
