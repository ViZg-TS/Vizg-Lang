// Standalone test — runs ONLY the "linked import model compiles" test logic
// using std.testing.allocator directly, bypassing any shared arena state.
const std = @import("std");

test "linked import model compiles (isolated)" {
    const allocator = std.testing.allocator;

    // Same shape as before but no ArenaAllocator involvement for the slice.
    var imports_list: std.ArrayListUnmanaged(linker.LinkedImport) = .empty;
    errdefer { _ = imports_list.deinit(allocator); }

    try imports_list.append(allocator, .{
        .id = 0,
        .from_module = @intCast(@as(u32, 0)),
        .import_edge = @intCast(@as(u32, 0)),
        .import_symbol = null,
        .local_name = "localX",
        .imported_name = "x",
        .target_module = @intCast(@as(u32, 1)),
        .target_symbol = @intCast(@as(u32, 42)),
        .kind = .named,
        .span = .{ .start = 0, .end = 50, .line = 0, .column = 0 },
    });

    const imports: []const linker.LinkedImport = try imports_list.toOwnedSlice(allocator);

    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expect(std.mem.eql(u8, "localX", imports[0].local_name));
    try std.testing.expect(std.mem.eql(u8, "x", imports[0].imported_name));
}

const linker = @import("linker.zig");
