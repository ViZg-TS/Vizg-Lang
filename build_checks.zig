const std = @import("std");

const cabi_source = @embedFile("Lib/vizg.zig");

test "public C ABI has no unconditional debug printing" {
    try std.testing.expect(std.mem.indexOf(u8, cabi_source, "std.debug.print") == null);
}
