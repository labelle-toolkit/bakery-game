// ============================================================================
// WASM Build Configuration for Bakery Game
// ============================================================================
// Builds the bakery game for WebAssembly using Emscripten.
// Based on labelle-engine's example_wasm pattern.
// ============================================================================

const std = @import("std");

pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu_native };
pub const EcsBackend = enum { zig_ecs, zflecs };
pub const GuiBackend = enum { none, raygui, microui, nuklear, imgui };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WASM uses raylib backend with emscripten
    const backend: Backend = .raylib;
    const ecs_backend: EcsBackend = .zig_ecs;
    _ = GuiBackend; // Not used

    // Get labelle-engine dependency directly
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .physics = false,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get labelle-tasks and create our own module to avoid diamond dependency
    // By creating the module ourselves, we control which engine_mod it uses
    const labelle_tasks_dep = b.dependency("labelle-tasks", .{
        .target = target,
        .optimize = optimize,
    });
    const ecs_mod = engine_dep.module("ecs");

    // Create labelle-tasks module with our engine_mod
    const labelle_tasks_mod = b.addModule("labelle-tasks", .{
        .root_source_file = labelle_tasks_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    labelle_tasks_mod.addImport("labelle-engine", engine_mod);
    labelle_tasks_mod.addImport("ecs", ecs_mod);

    // Add transitive dependencies through the correct dependency chain
    // labelle-gfx has the raylib and sokol modules
    const labelle_gfx_dep = engine_dep.builder.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    labelle_tasks_mod.addImport("labelle", labelle_gfx_dep.module("labelle"));
    labelle_tasks_mod.addImport("build_options", engine_dep.module("build_options"));
    // Get raylib through raylib_zig dependency
    const raylib_zig_dep = labelle_gfx_dep.builder.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    labelle_tasks_mod.addImport("raylib", raylib_zig_dep.module("raylib"));
    // Get sokol through labelle-gfx
    labelle_tasks_mod.addImport("sokol", labelle_gfx_dep.module("sokol"));

    // Check if targeting emscripten (WASM)
    const is_wasm = target.result.os.tag == .emscripten;

    if (is_wasm) {
        // Use raylib_zig for emsdk setup (already defined above)
        const raylib_zig = @import("raylib_zig");
        const emsdk = raylib_zig.emsdk;

        // Get raylib artifact for WASM linking
        const raylib_artifact = raylib_zig_dep.artifact("raylib");

        // Create WASM library
        const wasm = b.addLibrary(.{
            .name = "bakery_game",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_mod },
                    .{ .name = "labelle-tasks", .module = labelle_tasks_mod },
                },
            }),
        });

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .asyncify = true,
        });
        const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });

        // Use custom index.html as shell
        const shell_path = b.path("index.html");

        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = shell_path,
            .install_dir = install_dir,
        });

        // Make install depend on WASM build
        b.getInstallStep().dependOn(emcc_step);

        // Add wasm step alias
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
    } else {
        // Native build (for testing)
        const exe = b.addExecutable(.{
            .name = "bakery_game",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_mod },
                    .{ .name = "labelle-tasks", .module = labelle_tasks_mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the bakery game");
        run_step.dependOn(&run_cmd.step);
    }
}
