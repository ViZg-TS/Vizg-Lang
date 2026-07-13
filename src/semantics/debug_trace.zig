// Temporary debug test - will remove after investigation
test "debug trace" {
    const allocator = std.testing.allocator;
    var result = try analyze(allocator,
        \\const tuple: [number, string] = ["wrong", 1];
    );
    defer result.deinit();

    // Print all semantic diagnostics with their label status
    for (result.semantic_diagnostics) |d| {
        std.debug.print("diag[0]: code={}\nmsg=\"{}\"\nlabel={any}\nspan={}..{}\n\n", .{ d.code, d.message, d.label, d.span.start, d.span.end });
    }

    // Get initializer node info
    var found = false;
    for (result.bind.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "tuple")) {
            const info = result.type_info.lookupSymbol(sym.id) orelse continue;
            std.debug.print("symbol: declared_type={}, contextual={any}\n", .{ info.declared_type, info.contextual_type });
            found = true;
            break;
        }
    }

    if (found) return;

    // Print all node types for initializer-like nodes
    var any_init = false;
    for (result.type_info.nodes) |info| {
        _ = info;
        // skip for now
    } else {
        std.debug.print("no tuple symbol found\n", .{});
    }
}

const std = @import("std");
fn analyze(allocator: std.mem.Allocator, source: [*c] const u8) !@import("root.zig").SemanticResult {
    _ = allocator;
    _ = source;
    return error.NotImplemented;
}
