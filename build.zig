const std = @import("std");
const android = @import("./android.build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module exposed as "vizg" for `@import("vizg")` usage.
    const vizg_mod = b.addModule("vizg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable; wire vizg module and explicit target/optimization into its root module.
    const exe_root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target         = target,
        .optimize       = optimize,
    });
    exe_root_mod.addImport("vizg", vizg_mod);

    const exe = b.addExecutable(.{
        .name        = "vizg",
        .root_module = exe_root_mod,
    });
    b.installArtifact(exe);

    // `zig build run` — invokes the executable; depends on install so it runs from zig-out.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — runs both library and executable tests in parallel.
    const mod_tests = b.addTest(.{ .root_module = vizg_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- Android builds --------------------------------------------------
    // Three arch variants: aarch64 (production), armv7l (legacy 32-bit), x86_64 (emulator).
    const android_arches = [_]struct { a: android.Arch, n: []const u8 }{
        .{ .a = .aarch64, .n = "vizg-aarch64" },
        .{ .a = .armv7l,  .n = "vizg-armv7l"  },
        .{ .a = .x86_64,  .n = "vizg-x86_64"  },
    };

    for (android_arches) |item| {
        const exe_android = android.addAndroidExe(b, item.n, b.path("src/main.zig"), item.a) catch continue;
        // Wire vizg module so @import("vizg") resolves in the Android build too.
        exe_android.root_module.addImport("vizg", vizg_mod);
        b.installArtifact(exe_android);
    }

    const android_install = b.step("install-android", "Copy all Android artifacts to zig-out");
    android_install.dependOn(b.getInstallStep());
}
