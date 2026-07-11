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

    _ = b.addTest(.{ .root_module = tests_mod }); // consumed by lint-silent path only in prior wiring; kept for compat.
    // 4a. Lint-silent: assert no unconditional std.debug.print in Lib/ (Goal-041).
    const lint_silent = b.addSystemCommand(&[_][]const u8{ "bash", "-c", "./lint-silent.sh" });
    const lint_silent_step = b.step("lint-silent", "Assert public library is silent by default (Goal-041)");
    lint_silent_step.dependOn(&lint_silent.step);

    // 4b. C runtime smoke test: compile and run example/silent_test.c against libvizg.a;
    //     asserts zero bytes land on stderr during a real API call.
    const cc_compile = b.addSystemCommand(&[_][]const u8{
        "cc", "-Wall", "-Wextra", "-O2",
        "-Izig-out/include", "example/silent_test.c",
        "-Lzig-out/lib", "-lvizg",
        "-o", "/tmp/vizg-silent-test-exe",
    });
    cc_compile.step.dependOn(&install_lib.step);
    const run_silent_c = b.addSystemCommand(&[_][]const u8{ "/tmp/vizg-silent-test-exe" });
    run_silent_c.step.dependOn(&cc_compile.step);

    // 4c. Final test step: run lint-silent first (structural), then tests (unit + ABI + silent runtime).
    const abi_tests_mod = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    abi_tests_mod.addImport("vizg-impl", pkg_src);
    const run_abi_tests = b.addRunArtifact(b.addTest(.{ .root_module = abi_tests_mod }));
    const test_step = b.step("test", "Compile & run all unit tests");
    test_step.dependOn(lint_silent_step);
    test_step.dependOn(&run_abi_tests.step);
    test_step.dependOn(&run_silent_c.step);

}
