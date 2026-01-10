//! Bakery Game - iOS Build Configuration
//!
//! Builds the bakery game for iOS using sokol backend.
//!
//! Usage:
//!   zig build              # Build for host (macOS testing)
//!   zig build run          # Run on macOS
//!   zig build ios          # Build for iOS device
//!   zig build ios-sim      # Build for iOS simulator
//!   zig build xcode        # Generate Xcode project only

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Detect if building for iOS
    const is_ios = target.result.os.tag == .ios;

    // iOS-specific options
    const app_name = b.option([]const u8, "app_name", "Application name") orelse "BakeryGame";
    _ = b.option([]const u8, "bundle_id", "Bundle identifier") orelse "com.labelle.bakery";

    // Sokol dependency for all builds (iOS requires sokol)
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // labelle-engine with sokol backend (no raylib on iOS)
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    // labelle-tasks plugin
    const tasks_dep = b.dependency("labelle-tasks", .{
        .target = target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    // ========================================
    // Host/macOS build (for testing)
    // ========================================
    if (!is_ios) {
        const exe = b.addExecutable(.{
            .name = "bakery_game_ios_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("../ios_main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_dep.module("labelle-engine") },
                    .{ .name = "labelle-tasks", .module = tasks_dep.module("labelle_tasks") },
                    .{ .name = "sokol", .module = sokol_dep.module("sokol") },
                },
            }),
        });

        exe.linkLibrary(sokol_dep.artifact("sokol_clib"));
        exe.linkLibC();

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.setCwd(b.path(".."));

        const run_step = b.step("run", "Run on host (macOS) for testing");
        run_step.dependOn(&run_cmd.step);
    }

    // ========================================
    // iOS Device build
    // ========================================
    const ios_device_query: std.Target.Query = .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    };
    const ios_device_target = b.resolveTargetQuery(ios_device_query);

    // Detect iOS SDK path
    const ios_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &ios_device_target.result);

    const ios_sokol_dep = b.dependency("sokol", .{
        .target = ios_device_target,
        .optimize = optimize,
        .dont_link_system_libs = true,
    });

    const ios_engine_dep = b.dependency("labelle-engine", .{
        .target = ios_device_target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    const ios_tasks_dep = b.dependency("labelle-tasks", .{
        .target = ios_device_target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    const sokol_clib = ios_sokol_dep.artifact("sokol_clib");

    // Also get sokol_clib from labelle-engine's internal dependencies
    // These need SDK paths too since labelle-engine creates its own dependency instances
    const engine_sokol_dep = ios_engine_dep.builder.dependency("sokol", .{
        .target = ios_device_target,
        .optimize = optimize,
        .dont_link_system_libs = true,
    });
    const engine_sokol_clib = engine_sokol_dep.artifact("sokol_clib");

    // Add iOS SDK paths to all sokol_clib artifacts
    // Note: miniaudio is no longer used on iOS - sokol_audio backend is used instead
    if (ios_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
        const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

        // Configure direct sokol dependency
        sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
        sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

        // Configure labelle-engine's internal sokol dependency
        engine_sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
        engine_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        engine_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        engine_sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    const ios_exe = b.addExecutable(.{
        .name = app_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("../ios_main.zig"),
            .target = ios_device_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = ios_engine_dep.module("labelle-engine") },
                .{ .name = "labelle-tasks", .module = ios_tasks_dep.module("labelle_tasks") },
                .{ .name = "sokol", .module = ios_sokol_dep.module("sokol") },
            },
        }),
    });

    ios_exe.linkLibrary(sokol_clib);
    ios_exe.linkLibC();

    // Add iOS framework paths
    if (ios_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        ios_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        ios_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        ios_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
        ios_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "lib" }) });
    }

    // Link iOS frameworks
    ios_exe.root_module.linkFramework("Foundation", .{});
    ios_exe.root_module.linkFramework("UIKit", .{});
    ios_exe.root_module.linkFramework("Metal", .{});
    ios_exe.root_module.linkFramework("MetalKit", .{});
    ios_exe.root_module.linkFramework("AudioToolbox", .{});
    ios_exe.root_module.linkFramework("AVFoundation", .{});

    // Don't install by default - use 'zig build ios' step
    const ios_step = b.step("ios", "Build for iOS device");
    ios_step.dependOn(&ios_exe.step);
    ios_step.dependOn(&b.addInstallArtifact(ios_exe, .{}).step);

    // ========================================
    // iOS Simulator build
    // ========================================
    const ios_sim_query: std.Target.Query = .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    };
    const ios_sim_target = b.resolveTargetQuery(ios_sim_query);
    const ios_sim_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &ios_sim_target.result);

    const ios_sim_sokol_dep = b.dependency("sokol", .{
        .target = ios_sim_target,
        .optimize = optimize,
        .dont_link_system_libs = true,
    });

    const ios_sim_engine_dep = b.dependency("labelle-engine", .{
        .target = ios_sim_target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    const ios_sim_tasks_dep = b.dependency("labelle-tasks", .{
        .target = ios_sim_target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = .zig_ecs,
        .gui_backend = .none,
        .physics = false,
    });

    const sim_sokol_clib = ios_sim_sokol_dep.artifact("sokol_clib");

    if (ios_sim_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
        const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

        sim_sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
        sim_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        sim_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        sim_sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    const ios_sim_exe = b.addExecutable(.{
        .name = "BakeryGame_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../ios_main.zig"),
            .target = ios_sim_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = ios_sim_engine_dep.module("labelle-engine") },
                .{ .name = "labelle-tasks", .module = ios_sim_tasks_dep.module("labelle_tasks") },
                .{ .name = "sokol", .module = ios_sim_sokol_dep.module("sokol") },
            },
        }),
    });

    ios_sim_exe.linkLibrary(sim_sokol_clib);
    ios_sim_exe.linkLibC();

    if (ios_sim_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        ios_sim_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        ios_sim_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        ios_sim_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
        ios_sim_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "lib" }) });
    }

    ios_sim_exe.root_module.linkFramework("Foundation", .{});
    ios_sim_exe.root_module.linkFramework("UIKit", .{});
    ios_sim_exe.root_module.linkFramework("Metal", .{});
    ios_sim_exe.root_module.linkFramework("MetalKit", .{});
    ios_sim_exe.root_module.linkFramework("AudioToolbox", .{});
    ios_sim_exe.root_module.linkFramework("AVFoundation", .{});

    const ios_sim_step = b.step("ios-sim", "Build for iOS simulator");
    ios_sim_step.dependOn(&ios_sim_exe.step);

    // ========================================
    // Xcode project generation
    // ========================================
    const xcode_cmd = b.addSystemCommand(&.{
        "./generate_xcode.sh",
        "--app-name",
        app_name,
    });
    xcode_cmd.step.dependOn(&b.addInstallArtifact(ios_exe, .{}).step);

    const xcode_step = b.step("xcode", "Build iOS binary and generate Xcode project");
    xcode_step.dependOn(&xcode_cmd.step);
}
