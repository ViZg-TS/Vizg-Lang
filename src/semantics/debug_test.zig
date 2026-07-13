const std = @import("std");
const checker = @import("checker.zig");
const type_inference = @import("type_inference.zig");

export fn zig_entry() void {}

test "debug tuple mismatch trace" {
    const allocator = std.testing.allocator;
    var result = try analyze(allocator,
        \\const tuple: [number, string] = ["wrong", 1];
    );
    defer result.deinit();

    // Print all diagnostics
    for (result.semantic_diagnostics) |d| {
        const label_info = if (d.label) |l| l else "(null)";
        std.debug.print("diag: code={any} msg=\"{}\" label=\"{}\"\n", .{ d.code, d.message, label_info });
    }

    // Get the declared type from the symbol
    var found = false;
    for (result.bind.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "tuple")) {
            const info = result.type_info.lookupSymbol(sym.id) orelse continue;
            std.debug.print("symbol 'tuple' declared_type: {}\n", .{info.declared_type});
            found = true;
            break;
        }
    }
}

fn analyze(allocator: std.mem.Allocator, source: [*c]const u8) !@import("root.zig").SemanticResult {
    return @import("root.zig").analyze(allocator, source);
}
