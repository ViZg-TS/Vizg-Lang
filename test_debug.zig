const std = @import("std");
const graph_mod = struct {
    pub const ModuleId = u32;
    pub const ImportEdgeId = u32;
    
    // Re-export public types we need
    pub fn build(allocator: anytype, io_inst: anytype, path: []const u8) @TypeOf(graph_mod.build_impl.?) {
        return graph_mod.build_impl(allocator, io_inst, path);
    }
};

fn main() void {
    std.debug.print("debug test\n", .{});
}
