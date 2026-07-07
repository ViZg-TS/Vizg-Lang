const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
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

/// Inspect declared and inferred types for a file, using the *already-parsed*
/// FrontendResult. This is the preferred entry point from CLI code paths — it
/// avoids re-running scanner/parser/binder/resolver on source that has already
/// been analyzed by `frontend.analyze`.
///
/// Diagnostics are stamped with `result.source.path` so they preserve their
/// originating file path when printed downstream.
pub fn analyzeFrontendResult(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
) !TypeInfo {
    var builder: std.ArrayList(SymbolTypeInfo) = .empty;
    errdefer builder.deinit(allocator);

    const builtins_mod = @import("../types/root.zig").builtin_instance;
    const collected = try type_collector.collectDeclaredTypes(
        allocator,
        result.source,
        result.ast,
        result.bind,
        builtins_mod,
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
        // Stamp diagnostics with the source path so downstream callers do not
        // have to remember where this slice came from.
        var d = collected.diagnostics[i];
        if (d.path == null or std.mem.eql(u8, d.path.?, "")) {
            d.path = result.source.path;
        }
        try diag_list.append(allocator, d);
    }

    // inferLiteralNodeTypes returns an *owned* slice on `allocator`. Do NOT
    // free it via defer — ownership is transferred into the returned TypeInfo.
    const inferred_nodes = try type_inference.inferLiteralNodeTypes(allocator, result.ast);

    return TypeInfo{
        .symbols = try builder.toOwnedSlice(allocator),
        .nodes = inferred_nodes,
        .diagnostics = try diag_list.toOwnedSlice(allocator),
    };
}

/// Convenience overload: re-parse source, then inspect. Prefer
/// `analyzeFrontendResult` from CLI code to avoid double-parsing the file.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8) !TypeInfo {
    const ast_src: frontend.SourceFile = .{
        .text = source,
        // Default path so downstream callers (type_collector.resolveAnnotation,
        // stamping logic in analyzeFrontendResult) still get a meaningful
        // non-empty path when the caller did not supply one.
        .path = "input",
    };
    const fe_result = try frontend.analyze(allocator, ast_src, .{});
    return analyzeFrontendResult(allocator, fe_result);
}

test "analyze returns node entries without dangling ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = try analyze(arena.allocator(), "let x: number = 1;\n");

    // TypeInfo.nodes owns the slice; inspect a node type to ensure the slice
    // is still valid (not freed under us).
    if (info.nodes.len > 0) {
        _ = info.lookupNode(info.nodes[0].node_id);
    }
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

test "analyze stamps diagnostics with source path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = analyze(arena.allocator(), "let bad: Foo = 123;\n") catch unreachable;
    if (info.diagnostics.len == 0) return error.TestUnexpectedResult;

    var seen_path: bool = false;
    for (info.diagnostics) |d| {
        if (d.code == .unknown_type_name and d.path != null and !std.mem.eql(u8, d.path.?, "")) {
            seen_path = true;
        }
    }
    try std.testing.expect(seen_path);
}
