const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "debug_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/debug_test.zig"),
            .imports = &.{.{.name="vizg", .module=b.addModule("vizg", .{})},  },
        }),
    });
    b.installArtifact(exe);
}
