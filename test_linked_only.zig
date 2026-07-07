// Minimal reproduction of linked import model compiles in project scope.
const std = @import("std");
test "linked import model compiles (in-proj)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    _ = try arena.allocator().dupe(u8, "import { x as localX } from \"./a\";\n");
    const edges_buf = try arena.allocator().alloc([1]u32, 1);
    edges_buf[0][0] = @intCast(@as(u32, 0));
    
    // Just verify no panic happens before defer; the crash is in deinit itself.
    std.debug.print("arena size after allocs: {}\n", .{arena.deallocator.arenaSize()});
}
