// build.zig — Pipeline for vizg static library, main exe, and run step (Zig 0.16).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // -------------------------------------------------------------------
    // 1. Package registered at top level so @import("vizg-impl/...") works
    //    from any module in this build (including Lib/vizg.zig).
    // -------------------------------------------------------------------
    const pkg_src = b.addModule("vizg-impl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Library entry point: compile Lib/vizg.zig as a static archive.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Bind "vizg-impl" package to the module defined above.  With this binding,
    // Lib/vizg.zig can use @import("vizg-impl").frontend.xxx which Zig resolves
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
    //       zig-out/include/vizg.h   ← public C header
    // -------------------------------------------------------------------
    const install_lib = b.addInstallArtifact(vizg_lib, .{});
    const install_h = b.addInstallFile(b.path("Lib/vizg.h"), "include/vizg.h");

    const lib_step = b.step("lib", "Build & install: zig-out/lib/libvizg.a + include/vizg.h");
    lib_step.dependOn(&install_lib.step);
    lib_step.dependOn(&install_h.step);

    // Make `zig build` (default step) also produce the static archive.
    b.getInstallStep().dependOn(&install_lib.step);
    b.getInstallStep().dependOn(&install_h.step);

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

    const run_cmd = b.addRunArtifact(main_exe);
    run_cmd.step.dependOn(&install_lib.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run the main executable (for testing only)");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // 4. Test step — register the public package's complete test tree and
    //    compile the C ABI entry point as a test artifact as well.
    // -------------------------------------------------------------------
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const abi_tests_mod = b.createModule(.{
        .root_source_file = b.path("Lib/vizg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_tests_mod.addImport("vizg-impl", pkg_src);
    const abi_tests = b.addTest(.{ .root_module = abi_tests_mod });
    const run_abi_tests = b.addRunArtifact(abi_tests);

    const test_step = b.step("test", "Run all vizg unit and ABI compilation tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_abi_tests.step);

    // -------------------------------------------------------------------
    // 5. Android static libraries — compile the C ABI for each supported
    //    Android ABI and install deterministic archives under zig-out/android.
    // -------------------------------------------------------------------
    const android_step = b.step("android", "Build vizg static libraries for Android ABIs");
    const android_targets = [_]struct {
        arch: std.Target.Cpu.Arch,
        abi: std.Target.Abi,
        install_path: []const u8,
    }{
        .{ .arch = .aarch64, .abi = .android, .install_path = "android/aarch64/libvizg.a" },
        .{ .arch = .arm, .abi = .androideabi, .install_path = "android/armv7/libvizg.a" },
        .{ .arch = .x86_64, .abi = .android, .install_path = "android/x86_64/libvizg.a" },
    };

    for (android_targets) |android_target| {
        const target_android = b.resolveTargetQuery(.{
            .cpu_arch = android_target.arch,
            .os_tag = .linux,
            .abi = android_target.abi,
        });
        const android_pkg = b.addModule(b.fmt("vizg-impl-android-{s}", .{android_target.install_path}), .{
            .root_source_file = b.path("src/root.zig"),
            .target = target_android,
            .optimize = optimize,
            .link_libc = true,
        });
        const android_lib_mod = b.createModule(.{
            .root_source_file = b.path("Lib/vizg.zig"),
            .target = target_android,
            .optimize = optimize,
            .link_libc = true,
        });
        android_lib_mod.addImport("vizg-impl", android_pkg);
        const android_lib = b.addLibrary(.{
            .name = "vizg",
            .root_module = android_lib_mod,
        });
        const install_android_lib = b.addInstallFile(android_lib.getEmittedBin(), android_target.install_path);
        android_step.dependOn(&install_android_lib.step);
    }
}
