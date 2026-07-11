// build.zig — Pipeline for vizg static library, main exe, and run step (Zig 0.16).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // -------------------------------------------------------------------
    // 1. Package registered at top level so @import("vizg-impl/...") works
    //    from any module in this build.
    // -------------------------------------------------------------------
    const pkg_src = b.addModule("vizg-impl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Library entry point: compile src/lib.zig as a static archive.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Bind "vizg-impl" package to the module defined above.  With this binding,
    // src/lib.zig can use @import("vizg-impl").frontend.xxx which Zig resolves
    // via pkg_src (rooted at src/root.zig).
    lib_mod.addImport("vizg-impl", pkg_src);

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
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Compile & run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

}
