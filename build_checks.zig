const std = @import("std");

const forbidden_output = [_][]const u8{
    "std.debug.print",
    "std.log.debug",
    "printf(",
    "fprintf(stderr",
};

fn expectTreeSilent(root_path: []const u8) !void {
    const io = std.testing.io;
    const root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig") and
            !std.mem.endsWith(u8, entry.path, ".c") and
            !std.mem.endsWith(u8, entry.path, ".h")) continue;
        if (std.mem.eql(u8, root_path, "src") and std.mem.eql(u8, entry.path, "main.zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "semantics/debug_")) continue;

        const source = try root.readFileAlloc(
            io,
            entry.path,
            std.testing.allocator,
            .limited(16 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        for (forbidden_output) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
        }
    }
}

test "library, semantic, and test code has no accidental debug output" {
    try expectTreeSilent("Lib");
    try expectTreeSilent("src");
    try expectTreeSilent("test");
}
