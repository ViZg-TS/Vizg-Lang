const std = @import("std");
const diagnostics = @import("../diagnostics/root.zig");

pub const type_info = @import("type_info.zig");
pub const type_collector = @import("type_collector.zig");
pub const type_inference = @import("type_inference.zig");

pub const SymbolTypeInfo = type_info.SymbolTypeInfo;
pub const NodeTypeInfo = type_info.NodeTypeInfo;
pub const TypeInfo = type_info.TypeInfo;

test {
    _ = type_info;
    _ = type_collector;
    _ = type_inference;
}

// analyze — convenience entry point for the inspection `types` CLI command.
// Runs frontend.analyze (scanner → parser → binder → resolver) and then
// combines declared-type collection with literal inference into a single
// TypeInfo snapshot. Purely an inspection helper; does not type check, infer
// beyond literals, or validate calls — those behaviors remain future work.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8) !TypeInfo {
    const fe = @import("../frontend/frontend.zig");
    const collector = @import("type_collector.zig");

    const ast_src: @import("../frontend/frontend.zig").SourceFile = .{ .text = source };
    const fe_result = try fe.analyze(allocator, ast_src, .{});

    var builder: std.ArrayList(SymbolTypeInfo) = .empty;
    errdefer builder.deinit(allocator);

    _ = fe_result.bind.symbols; // reserved — keeps declaration-order iteration in sync.

    const builtins_mod = @import("../types/model.zig");
    const collected = try collector.collectDeclaredTypes(
        allocator,
        fe_result.source,
        fe_result.ast,
        fe_result.bind,
        builtins_mod.builtin_instance,
    );

    var i: usize = 0;
    while (i < collected.symbol_declared_types.len) : (i += 1) {
        const entry = collected.symbol_declared_types[i];
        try builder.append(allocator, .{
            .symbol_id = entry.symbol_id,
            .declared_type = entry.declared_type,
        });
    }

    var diag_list: std.ArrayList(diagnostics.Diagnostic) = .empty;
    errdefer diag_list.deinit(allocator);
    i = 0;
    while (i < collected.diagnostics.len) : (i += 1) {
        try diag_list.append(allocator, collected.diagnostics[i]);
    }

    const inferred_nodes = try type_inference.inferLiteralNodeTypes(allocator, fe_result.ast);
    defer allocator.free(inferred_nodes);

    return TypeInfo{
        .symbols = try builder.toOwnedSlice(allocator),
        .nodes = inferred_nodes,
        .diagnostics = try diag_list.toOwnedSlice(allocator),
    };
}

test "analyze runs frontend + collects declared types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = analyze(arena.allocator(), "let x: number = 1;\n") catch unreachable;

    // One declared symbol ('x') with builtin number type id.
    try std.testing.expectEqual(@as(usize, 1), info.symbols.len);
    const sym = &info.symbols[0];
    if (sym.declared_type) |t| {
        const expected_id = @import("../types/builtin.zig").builtinKindTypeId(.number);
        try std.testing.expectEqual(expected_id, t);
    } else unreachable;
}

test "analyze propagates unknown type name diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = analyze(arena.allocator(), "let bad: Foo = 123;\n") catch unreachable;

    try std.testing.expect(info.diagnostics.len > 0);
}
