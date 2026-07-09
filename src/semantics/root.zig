const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const diagnostics = @import("../diagnostics/root.zig");

pub const type_info = @import("type_info.zig");
pub const type_collector = @import("type_collector.zig");
pub const type_inference = @import("type_inference.zig");

pub const checker = @import("checker.zig");


// Type compatibility rules (Goal 24).
pub const type_compat = @import("type_compat.zig");

pub const SymbolTypeInfo = type_info.SymbolTypeInfo;
pub const NodeTypeInfo = type_info.NodeTypeInfo;
pub const TypeInfo = type_info.TypeInfo;

test {
    _ = type_info;
    _ = type_collector;
    _ = type_inference;
    _ = type_compat;
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

    // v1 checker — run after collector so pre-pass declarations and
    // assignment/initializer checks both contribute diagnostics to the
    // returned TypeInfo. The passed-in TypeInfo is empty: the checker only
    // needs the builtins table (looked up internally) and the AST.
    const empty_checker_info = @import("type_info.zig").TypeInfo{
        .symbols = &.{},
        .nodes = &.{},
        .diagnostics = &.{},
    };
    const checker_diags = try checker.checkFile(allocator, result, empty_checker_info);

    // Stamp checker diagnostics with the source path too. The collector does
    // this above via its own loop; we mirror it here so callers like
    // analyzeFrontendResult's test can rely on `d.path != null` for every
    // returned diagnostic. Diagnostics come in as a `[]const Diagnostic`, so
    // use index-based copy-and-override to apply the stamp since Zig forbids
    // mutating through a const slice directly.
    // Stamp checker diagnostics with the source path. Since checker_diags is
    // a const slice we build a stamped copy via an ArrayList, then merge both
    // collector + stamped-checker slices below into one output.
    var stamped_checker: std.ArrayList(diagnostics.Diagnostic) = .empty;
    for (checker_diags) |d| {
        if (d.path == null or std.mem.eql(u8, d.path.?, "")) {
            if (!std.mem.eql(u8, result.source.path, "")) {
                var stamped = d;
                stamped.path = result.source.path;
                try stamped_checker.append(allocator, stamped);
                continue;
            }
        }
        try stamped_checker.append(allocator, d);
    }

    // Merge collector diagnostics and stamped-checker diagnostics into one slice.
    var all_diags = try std.ArrayList(diagnostics.Diagnostic).initCapacity(
        allocator, diag_list.items.len + stamped_checker.items.len);
    for (diag_list.items) |d| {
        try all_diags.append(allocator, d);
    }
    for (stamped_checker.items) |d| {
        try all_diags.append(allocator, d);
    }

    // inferLiteralNodeTypes returns an *owned* slice on `allocator`. Do NOT
    // free it via defer — ownership is transferred into the returned TypeInfo.
    const inferred_nodes = try type_inference.inferLiteralNodeTypes(allocator, result.ast);

    return TypeInfo{
        .symbols = try builder.toOwnedSlice(allocator),
        .nodes = inferred_nodes,
        .diagnostics = try all_diags.toOwnedSlice(allocator),
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
// E2E-style assertion: analyzeFrontendResult runs checkAssignments and merges its diagnostics,
// producing a VZG6005 (`type_mismatch`) for `x = "bad"` where x was declared as number.
test "analyzeFrontendResult emits type_mismatch diagnostic for assignment of string to number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src_text = "let x: number;\nx = \"bad\";";
    const src: frontend.SourceFile = .{
        .text = src_text,
        .path = "test.ts",
    };
    const fe_result = try frontend.analyze(arena.allocator(), src, .{});

    // Call analyzeFrontendResult directly (this runs the type checker).
    const info = analyzeFrontendResult(arena.allocator(), fe_result) catch unreachable;

    // We expect at least one diagnostic — the VZG6005 mismatch on line 2.
    try std.testing.expect(info.diagnostics.len > 0);

    var found_mismatch: bool = false;
    for (info.diagnostics) |d| {
        if (d.code == .type_mismatch and d.path != null) {
            found_mismatch = true;
            break;
        }
    }
    try std.testing.expect(found_mismatch);
}
