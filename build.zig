const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module exposed as "vizg" for `@import("vizg")` usage.
    const mod = b.addModule("vizg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable; wire vizg module and explicit target/optimization into its root module.
    const exe = b.addExecutable(.{
        .name = "vizg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vizg", .module = mod }},
        }),
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
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
