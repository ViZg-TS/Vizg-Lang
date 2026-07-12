// build.zig — Pipeline for vizg static library, main exe, and run step (Zig 0.16).
const std = @import("std");

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
    abi_lifecycle_mod.linkLibrary(vizg_lib);
    const abi_lifecycle_tests = b.addRunArtifact(b.addTest(.{
        .root_module = abi_lifecycle_mod,
    }));
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
