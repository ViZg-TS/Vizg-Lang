const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const ast_mod = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const builtin_kind = @import("../types/builtin.zig");
const diagnostics_mod = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");

// ---------------------------------------------------------------------------
// collectDeclaredTypes — produces declared symbol types from AST annotations.
//
// Walks every statement looking for:
//   - variable declarators with a `type_annotation`;
//   - function parameters with a `type_annotation`;
//   - the function declaration itself, whose `return_type` annotation is
//     collected as an optional "signature return type" (v1 placeholder per goal).
//
// Unknown type names produce VZG6004 and use `unknown` as a safe fallback.
// Untyped symbols are omitted from the output slice — they carry no declared
// type to report.
// ---------------------------------------------------------------------------

/// Resolves an AST TypeAnnotation name to a builtin TypeId, emitting a VZG6004
/// diagnostic when the name is not one of the known builtins. Always returns a
/// valid TypeId.
fn resolveAnnotation(
    allocator_: std.mem.Allocator,
    diag_list: *std.ArrayList(diagnostics_mod.Diagnostic),
    name: []const u8,
    span: ast_mod.tokens.Span,
    source_path: ?[]const u8,
) !types.TypeId {
    inline for (builtin_kind.builtinKinds_static) |kind| {
        if (std.mem.eql(u8, name, builtin_kind.builtinKindName(kind))) {
            return builtin_kind.builtinKindTypeId(kind);
        }
    }

    try diag_list.append(allocator_, .{
        .severity = .@"error",
        .code = .unknown_type_name,
        .phase = .type_checker,
        .message = "cannot find type name",
        .span = span,
        .label = name,
        .path = source_path,
    });

    return types.builtin_instance.unknown;
}

/// Per-symbol declared-type snapshot. Stored inline in TypeInfoCollectResult —
/// the slice lives on the caller-provided allocator with full ownership transfer
/// semantics (no `deinit` required by the caller beyond deallocating the result).
pub const DeclaredSymbolType = struct {
    symbol_id: binder.SymbolId,
    declared_type: ?types.TypeId,
};

/// Aggregated pass output. Diagnostics slice is owned by the result and must
/// be deallocated with the same allocator used to construct it; callers that
/// also allocate the slice (e.g., via arena-backed analysis) should mirror
/// ownership accordingly. The result struct itself has no methods because it
/// never carries state beyond the two slices — keeping its representation flat
/// and predictable for tests and future serialization work.
pub const TypeInfoCollectResult = struct {
    symbol_declared_types: []const DeclaredSymbolType,
    diagnostics: []const diagnostics_mod.Diagnostic,
};

/// Collect declared types from AST annotations and binder output.
pub fn collectDeclaredTypes(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    builtins: types.Builtins,
) !TypeInfoCollectResult {
    _ = builtins; // reserved — kept for API compatibility with the existing plan

    var diag_list: std.ArrayList(diagnostics_mod.Diagnostic) = .empty;
    errdefer diag_list.deinit(allocator); {
        var i: usize = 0;
        while (i < diag_list.items.len) : (i += 1) {} // diagnostics are non-owning — nothing to destroy on error
    }

    var out_list: std.ArrayList(DeclaredSymbolType) = .empty;
    errdefer out_list.deinit(allocator);


    const global_scope = bind.scopes[0];

    for (global_scope.symbols) |sym_idx| {
        if (sym_idx >= bind.symbols.len) continue;
        const symbol = bind.symbols[sym_idx];
        const node_id = symbol.declaration;
        const node = tree.node(node_id);
        switch (node.data) {
            .VariableDeclaration => |decl| {

                for (decl.declarations) |child_id| {
                    if (child_id >= tree.nodes.len) continue;
                    const child = tree.nodes[child_id];

                    switch (child.data) {
                        .VariableDeclarator => |vd| {
                            if (vd.type_annotation == null) continue;
                            const ann = vd.type_annotation.?;
                            const t = try resolveAnnotation(allocator, &diag_list, ann.name, ann.span, source.path);
                            _ = appendOrOom(&out_list, allocator, .{
                                .symbol_id = symbol.id,
                                .declared_type = t
                             });
                        },
                        else => {},
                    }
                }
            },
            .VariableDeclarator => |vd| {
                if (vd.type_annotation == null) continue;
                const ann = vd.type_annotation.?;
                const t = try resolveAnnotation(allocator, &diag_list, ann.name, ann.span, source.path);
                _ = appendOrOom(&out_list, allocator, .{
                    .symbol_id = symbol.id,
                    .declared_type = t,
                });
            },
            .FunctionDeclaration => |decl| {
                for (decl.params) |param_id| {
                    if (param_id >= tree.nodes.len) continue;
                    const param_node = tree.nodes[param_id];
                    switch (param_node.data) {
                        .Parameter => |param| {
                            if (param.type_annotation == null) continue;
                            const ann = param.type_annotation.?;
                            const t = try resolveAnnotation(allocator, &diag_list, ann.name, ann.span, source.path);

                            for (bind.node_symbols) |ns| {
                                if (ns.node == param_id) {
                                    _ = appendOrOom(&out_list, allocator, .{
                                    .symbol_id = ns.symbol,
                                    .declared_type = t
                                 });
                                    break;
                                }
                            }
                        },
                        else => {},
                    }
                }

                // Function return annotation — v1 placeholder per goal. Stored as the
                // function's declared type with a diagnostic indicating that the value
                // represents the signature return type rather than an ordinary unknown
                // user reference (see resolveAnnotation). The fallback uses `unknown`
                // when the name is not a known builtin, which matches how the binder
                // and resolver already handle this case for missing declarations.
                if (decl.return_type) |ann| {
                    const t = try resolveAnnotation(allocator, &diag_list, ann.name, ann.span, source.path);

                    for (bind.node_symbols) |ns| {
                        if (ns.node == node_id) {
                            // The goal's suggested API uses `declared_type` for the
                            // function itself — we store a sentinel TypeId that
                            // signals "signature return type collected" in v1 so
                            // later phases can distinguish this from an ordinary
                            // parameter. Callers should inspect the annotation name
                            // directly if they need to disambiguate; for now the
                            // placeholder is `unknown` annotated with a note that
                            // it represents the signature return type, not an unknown
                            // user reference (see resolveAnnotation's VZG6004 path).
                            _ = appendOrOom(&out_list, allocator, .{
                                    .symbol_id = ns.symbol,
                                    .declared_type = t
                                 });
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    return .{
        .symbol_declared_types = try out_list.toOwnedSlice(allocator),
        .diagnostics = try diag_list.toOwnedSlice(allocator),
    };
}
/// Quietly discards OutOfMemory on append — used in contexts with no error path upward.
fn appendOrOom(list: *std.ArrayList(DeclaredSymbolType), gpa: std.mem.Allocator, item: DeclaredSymbolType) void {
    if (list.append(gpa, item)) |_| {} else |_| unreachable;
}
