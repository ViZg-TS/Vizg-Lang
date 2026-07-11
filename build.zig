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

    const lib_step = b.step("lib", "Build & install: zig-out/lib/libvizg.a");
    lib_step.dependOn(&install_lib.step);

    // Make `zig build` (default step) also produce the static archive.
    b.getInstallStep().dependOn(&install_lib.step);

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
    // 4a. Lint-silent: assert no unconditional std.debug.print in Lib/ (Goal-041).
    const lint_silent = b.addSystemCommand(&[_][]const u8{ "bash", "-c", "./lint-silent.sh" });
    const lint_silent_step = b.step("lint-silent", "Assert public library is silent by default (Goal-041)");
    lint_silent_step.dependOn(&lint_silent.step);

    // 4b. C runtime smoke test: compile and run example/silent_test.c against libvizg.a;
    //     asserts zero bytes land on stderr during a real API call.
    const install_headers = b.addInstallHeaderFile(b.path("Lib/vizg.h"), "vizg.h");
    install_headers.step.dependOn(&install_lib.step);

    const cc_compile = b.addSystemCommand(&[_][]const u8{
        "cc", "-Wall", "-Wextra", "-O2",
        "-Izig-out/include", "example/silent_test.c",
        "-Lzig-out/lib", "-lvizg",
        "-o", "/tmp/vizg-silent-test-exe",
    });
    cc_compile.step.dependOn(&install_headers.step);
    const run_silent_c = b.addSystemCommand(&[_][]const u8{ "/tmp/vizg-silent-test-exe" });
    run_silent_c.step.dependOn(&cc_compile.step);

    // 4c. Final test step: run lint-silent first (structural), then tests (unit + ABI + silent runtime).
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = lib_mod }));
    const test_step = b.step("test", "Compile & run all unit tests");
    test_step.dependOn(lint_silent_step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_silent_c.step);

}
