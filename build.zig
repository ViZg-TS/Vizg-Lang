// build.zig — Pipeline for vizg static library, main exe, and run step (Zig 0.16).
const std = @import("std");
const android = @import("android.build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // root.zig is both the public Zig package and the static-library root.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vizg_cabi = b.addModule("vizg-abi", .{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("vizg-abi", vizg_cabi);
    vizg_cabi.addImport("vizg-impl", lib_mod);
    const vizg_lib = b.addLibrary(.{
        .name = "vizg",
        .root_module = lib_mod,
    });

    // A fixed Debug build keeps runtime safety checks enabled regardless of the
    // caller's selected optimization mode. It is the adversarial audit gate.
    const safety_impl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const safety_abi = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    safety_impl.addImport("vizg-abi", safety_abi);
    safety_abi.addImport("vizg-impl", safety_impl);
    const safety_tests = b.addRunArtifact(b.addTest(.{ .root_module = safety_impl }));
    const safety_step = b.step("audit-safety", "Run the full suite with Zig runtime safety enabled");
    safety_step.dependOn(&safety_tests.step);

    // Compile the OS-independent frontend/types/semantics layers for a small
    // representative target matrix. Objects are compiled only: no foreign
    // executable is linked or run, and Android does not require an NDK here.
    const cross_check_step = b.step("cross-check", "Compile generic layers for representative targets");
    const cross_targets = [_]struct {
        name: []const u8,
        query: std.Target.Query,
    }{
        .{ .name = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "aarch64-linux", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .name = "x86_64-windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "aarch64-linux-android.24", .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = 24,
        } },
    };
    for (cross_targets) |cross_target| {
        const probe = b.addObject(.{
            .name = b.fmt("vizg-cross-{s}", .{cross_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("cross_check.zig"),
                .target = b.resolveTargetQuery(cross_target.query),
                .optimize = .Debug,
            }),
        });
        cross_check_step.dependOn(&probe.step);
    }

    // Compile the same static-library graph installed for consumers, plus a C
    // translation unit that includes the public header, for every matrix target.
    // This is compile-only: no foreign archive is installed or executed.
    const abi_cross_check_step = b.step("abi-cross-check", "Compile C ABI archives for representative targets");
    for (cross_targets) |cross_target| {
        const cross_target_resolved = b.resolveTargetQuery(cross_target.query);
        const cross_impl = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target_resolved,
            .optimize = .Debug,
            .link_libc = true,
        });
        const cross_abi = b.createModule(.{
            .root_source_file = b.path("Lib/vizg.zig"),
            .target = cross_target_resolved,
            .optimize = .Debug,
            .link_libc = true,
        });
        cross_impl.addImport("vizg-abi", cross_abi);
        cross_abi.addImport("vizg-impl", cross_impl);
        cross_abi.addIncludePath(b.path("Lib"));
        cross_abi.addCSourceFile(.{
            .file = b.path("test/c_abi/layout_probe.c"),
            .flags = &.{"-std=c11"},
        });
        const cross_archive = b.addLibrary(.{
            .name = b.fmt("vizg-abi-cross-{s}", .{cross_target.name}),
            .root_module = cross_impl,
        });
        abi_cross_check_step.dependOn(&cross_archive.step);
    }

    // Produce a consumer-ready Android AArch64/API 24 package. Zig supplies
    // the target headers for compilation; final application linkage remains
    // the responsibility of the Android/NDK build consuming this archive.
    const android_target = b.resolveTargetQuery(android.targetQuery(.aarch64, 24));
    const android_impl = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const android_abi = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    android_impl.addImport("vizg-abi", android_abi);
    android_abi.addImport("vizg-impl", android_impl);
    const android_lib = b.addLibrary(.{
        .name = "vizg",
        .root_module = android_impl,
    });

    const android_consumer_source = b.addWriteFiles().add("android_minimal.c",
        \\#include "vizg.h"
        \\int main(void) { return VIZG_ABI_VERSION > 0 ? 0 : 1; }
    );
    const android_consumer_mod = b.createModule(.{
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    android_consumer_mod.addIncludePath(b.path("Lib"));
    android_consumer_mod.addCSourceFile(.{
        .file = android_consumer_source,
        .flags = &.{"-std=c11"},
    });
    const android_consumer = b.addObject(.{
        .name = "vizg-android-aarch64-consumer",
        .root_module = android_consumer_mod,
    });

    const install_android_lib = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "android-aarch64/lib" } },
    });
    const install_android_header = b.addInstallFile(
        b.path("Lib/vizg.h"),
        "android-aarch64/include/vizg.h",
    );
    const android_lib_step = b.step(
        "android-aarch64-lib",
        "Build Android AArch64/API 24 libvizg.a, header, and C compile probe",
    );
    android_lib_step.dependOn(&install_android_lib.step);
    android_lib_step.dependOn(&install_android_header.step);
    android_lib_step.dependOn(&android_consumer.step);

    // -------------------------------------------------------------------
    // 2. Install step — default prefix is zig-out/.
    //       zig build → installs everything into the prefix (default: zig-out)
    //       zig-out/lib/libvizg.a     ← library archive
    // -------------------------------------------------------------------
    const install_lib = b.addInstallArtifact(vizg_lib, .{});
    const install_headers = b.addInstallHeaderFile(b.path("Lib/vizg.h"), "vizg.h");

    const lib_step = b.step("lib", "Build & install: zig-out/lib/libvizg.a");
    lib_step.dependOn(&install_lib.step);

    // Make `zig build` (default step) also produce the static archive.
    b.getInstallStep().dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&install_headers.step);

    // -------------------------------------------------------------------
    // 3. Run step — main executable (dev/testing only).
    // -------------------------------------------------------------------
    const run_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const main_exe = b.addExecutable(.{
        .name = "vizg",
        .root_module = run_mod,
    });

    const install_exe = b.addInstallArtifact(main_exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(main_exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the main executable (for testing only)");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // 4. Test step — register the public package's complete test tree.
    //    Unit tests are compiled with src/root.zig as root so all internal
    //    tests within `modules/`, `semantics/`, etc. get wired in.
    // -------------------------------------------------------------------
    // 4a. Portable structural checks implemented as Zig tests.
    const lint_silent = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_checks.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const lint_silent_step = b.step("lint-silent", "Assert public library is silent by default (Goal-041)");
    lint_silent_step.dependOn(&lint_silent.step);

    // 4b. Final test step: portable structural, unit, ABI, and helper tests.
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = lib_mod }));
    const abi_lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("test/abi_lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_lifecycle_mod.addIncludePath(b.path("Lib"));
    abi_lifecycle_mod.linkLibrary(vizg_lib);
    const abi_lifecycle_tests = b.addRunArtifact(b.addTest(.{
        .root_module = abi_lifecycle_mod,
    }));
    const abi_layout_mod = b.createModule(.{
        .root_source_file = b.path("test/c_abi/layout_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_layout_mod.addImport("vizg-abi", vizg_cabi);
    abi_layout_mod.addIncludePath(b.path("Lib"));
    abi_layout_mod.addCSourceFile(.{
        .file = b.path("test/c_abi/layout_probe.c"),
        .flags = &.{"-std=c11"},
    });
    const abi_layout_tests = b.addRunArtifact(b.addTest(.{
        .root_module = abi_layout_mod,
    }));
    const abi_layout_step = b.step("abi-layout-test", "Compare Zig and C public ABI layouts");
    abi_layout_step.dependOn(&abi_layout_tests.step);
    const android_helper_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("android.build.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const test_step = b.step("test", "Compile & run all unit tests");
    test_step.dependOn(lint_silent_step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&abi_lifecycle_tests.step);
    test_step.dependOn(abi_layout_step);
    test_step.dependOn(&android_helper_tests.step);

    // 5. Portable validation: install public artifacts, run all tests, and
    //    exercise argument forwarding through the CLI without shell helpers.
    const validate_cli = b.addRunArtifact(main_exe);
    validate_cli.addArgs(&.{ "check", "test/frontend/vizg_capabilities_test.ts" });

    const validate_step = b.step("validate", "Install artifacts and run portable project checks");
    validate_step.dependOn(b.getInstallStep());
    validate_step.dependOn(test_step);
    validate_step.dependOn(&validate_cli.step);
}
