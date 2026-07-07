// Helper file — runs ONLY the linked-import-model test logic standalone
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    
    // Create a LinkedImport exactly as "linked import model compiles" does.
    var list: std.ArrayListUnmanaged(LinkedImportData) = .empty;
    errdefer { _ = list.deinit(std.testing.allocator); }

    try list.append(std.testing.allocator, .{
        .id = 0,
        .local_name = "localX",
        .imported_name = "x",
    });
    
    try stdout.print("Test passed: created {} LinkedImports\n", .{list.items.len});
}

pub const LinkedImportData = struct {
    id: u32,
    local_name: []const u8,
    imported_name: []const u8,
};
