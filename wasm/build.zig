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
    const gui_backend: GuiBackend = .none;

    // Get labelle-tasks plugin first - this will create its own labelle-engine dependency
    // We get our engine from labelle-tasks to avoid diamond dependency (both use same instance)
    const labelle_tasks_dep = b.dependency("labelle-tasks", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .physics = false,
    });
    const labelle_tasks_mod = labelle_tasks_dep.module("labelle_tasks");

    // Get labelle-engine through labelle-tasks's dependency chain
    // This ensures we use the exact same engine instance that labelle-tasks uses
    const engine_dep = labelle_tasks_dep.builder.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .gui_backend = gui_backend,
        .physics = false,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Check if targeting emscripten (WASM)
    const is_wasm = target.result.os.tag == .emscripten;

    if (is_wasm) {
        // Get raylib dependency for emsdk via labelle-gfx chain
        // Use engine_dep's builder to stay in the same dependency graph
        const labelle_gfx_dep = engine_dep.builder.dependency("labelle-gfx", .{
            .target = target,
            .optimize = optimize,
            .backend = backend,
        });
        const raylib_zig = @import("raylib_zig");
        const emsdk = raylib_zig.emsdk;

        // Get raylib_zig dependency and raylib artifact through labelle-gfx
        const raylib_zig_dep = labelle_gfx_dep.builder.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
        });
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
