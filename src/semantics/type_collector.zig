const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const ast_mod = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const builtin_kind = @import("../types/builtin.zig");
const diagnostics_mod = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const type_inference = @import("type_inference.zig");

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
fn resolveAnnotationName(
    allocator_: std.mem.Allocator,
    diag_list: *std.ArrayList(diagnostics_mod.Diagnostic),
    name: []const u8,
    span: ast_mod.tokens.Span,
    source_path: ?[]const u8,
    builtins: *const types.Builtins,
) !types.TypeId {
    for (builtin_kind.builtinKinds) |kind| {
        if (std.mem.eql(u8, name, builtin_kind.builtinKindName(kind))) {
            return builtins.id(kind);
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

    return builtins.unknown;
}

fn resolveAnnotation(
    allocator_: std.mem.Allocator,
    diag_list: *std.ArrayList(diagnostics_mod.Diagnostic),
    tree: ast_mod.Ast,
    annotation: ast_mod.TypeAnnotation,
    source_path: ?[]const u8,
    type_store: *types.TypeStore,
) !types.TypeId {
    const name = tree.annotationName(annotation) orelse
        return type_inference.resolveTypeAnnotation(tree, annotation, type_store);
    return resolveAnnotationName(allocator_, diag_list, name, annotation.span, source_path, &type_store.builtins);
}

/// Per-symbol declared-type snapshot. Stored inline in TypeInfoCollectResult —
/// the slice lives on the caller-provided allocator with full ownership transfer
/// semantics (no `deinit` required by the caller beyond deallocating the result).
pub const DeclaredSymbolType = struct {
    symbol_id: binder.SymbolId,
    declared_type: ?types.TypeId,
};

/// One entry pairing a function symbol with its captured function signature. The
/// pair exists because the per-symbol slice above carries individual parameter/return
/// declared types while this parallel list is how callers can enumerate every full
/// function signature produced during collection (for inspection, diagnostics, or
/// later use by the type checker).
pub const FunctionSignatureEntry = struct {
    symbol_id: binder.SymbolId,
    /// Id of the signature in the owning semantic TypeStore.
    signature_id: types.FunctionSignatureId,
    /// Inline snapshot of the resolved return type. May be `unknown` when no annotation was present.
    resolved_return_type: ?types.TypeId = null,
};

/// Aggregated pass output. Diagnostics slice is owned by the result and must
/// be deallocated with the same allocator used to construct it; callers that
/// also allocate the slice (e.g., via arena-backed analysis) should mirror
/// ownership accordingly. The result struct itself has no methods because it
/// never carries state beyond the two slices — keeping its representation flat
/// and predictable for tests and future serialization work.
pub const TypeInfoCollectResult = struct {
    symbol_declared_types: []const DeclaredSymbolType,
    function_signatures: []const FunctionSignatureEntry,
    diagnostics: []const diagnostics_mod.Diagnostic,
    allocator_: ?*const std.mem.Allocator = null,

    /// Returns true when at least one (fully-annotated or partially-annotated) function signature was collected. Useful for callers that need to branch on whether any `FunctionSignature` was produced without having to iterate the slice.
    pub fn hasAny(self: TypeInfoCollectResult) bool {
        return self.function_signatures.len > 0;
    }
};

/// Collect declared types from AST annotations and binder output.
pub fn collectDeclaredTypes(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    type_store: *types.TypeStore,
) !TypeInfoCollectResult {
    const builtins = &type_store.builtins;
    var diag_list: std.ArrayList(diagnostics_mod.Diagnostic) = .empty;
    errdefer diag_list.deinit(allocator);
    {
        var i: usize = 0;
        while (i < diag_list.items.len) : (i += 1) {} // diagnostics are non-owning — nothing to destroy on error
    }

    // Pair each function symbol with the canonical signature owned by TypeStore.
    var signature_entries: std.ArrayList(FunctionSignatureEntry) = .empty;
    errdefer signature_entries.deinit(allocator);

    var out_list: std.ArrayList(DeclaredSymbolType) = .empty;
    errdefer out_list.deinit(allocator);
    // Iterate every binder scope — function bodies, block statements, and the
    // global module body each carry their own symbols with type annotations.
    // This replaces the prior single-scope pass so declared types from local
    // declarations (e.g., for-loop inits) are also captured.

    var i_scope: usize = 0;
    while (i_scope < bind.scopes.len) : (i_scope += 1) {
        const scope = bind.scopes[i_scope];

        for (scope.symbols) |sym_idx| {
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
                                const t = try resolveAnnotation(allocator, &diag_list, tree, ann, source.path, type_store);
                                _ = appendOrOom(&out_list, allocator, .{ .symbol_id = symbol.id, .declared_type = t });
                            },
                            else => {},
                        }
                    }
                },
                .VariableDeclarator => |vd| {
                    if (vd.type_annotation == null) continue;
                    const ann = vd.type_annotation.?;
                    const t = try resolveAnnotation(allocator, &diag_list, tree, ann, source.path, type_store);
                    _ = appendOrOom(&out_list, allocator, .{
                        .symbol_id = symbol.id,
                        .declared_type = t,
                    });
                },
                .FunctionDeclaration => |decl| {
                    // Collect every parameter type into a local accumulator for the FunctionSignature;
                    // individual per-symbol entries are still recorded below via `bind.node_symbols` so each param keeps its own declared_type. The signature is then synthesized from these collected types, with `unknown` as the fallback for missing or unresolvable return annotations (see policy in goal document: "prefer unknown unless the checker can distinguish no return").
                    var local_params: std.ArrayList(types.ParameterType) = .empty;
                    errdefer local_params.deinit(allocator);

                    {
                        var i_param: usize = 0;
                        while (i_param < decl.params.len) : (i_param += 1) {
                            const param_id = decl.params[i_param];
                            if (param_id >= tree.nodes.len) continue;
                            const param_node = tree.nodes[param_id];
                            switch (param_node.data) {
                                .Parameter => |param| {
                                    // Untyped parameters carry no annotation and are added to the signature under `unknown` so callers can see them. Annotated-but-unknown names still route through resolveAnnotation, which emits VZG6004 on unknown types — preserving that diagnostic even when the declaration is a function param.
                                    const type_id: types.TypeId = if (param.type_annotation) |ann|
                                        try resolveAnnotation(allocator, &diag_list, tree, ann, source.path, type_store)
                                    else
                                        builtins.unknown;

                                    // Track the parameter for signature construction. The name comes directly from the AST (which is still live on the binder's arena), so we don't need a copy.
                                    if (local_params.append(allocator, .{
                                        .name = param.name,
                                        .type_id = type_id,
                                        .optional = param.optional,
                                        .has_default = param.initializer != null,
                                        .rest = param.rest,
                                    })) |_| {} else |err| {
                                        return err;
                                    }
                                },
                                else => {},
                            }
                        }
                    }

                    // Resolve the declared return type per goal policy: use `unknown` when no annotation is present (i.e. "no return" cannot be distinguished from "return void") and fall through to resolveAnnotation for annotated names, which emits VZG6004 on unknown types. The final type_id is always a valid builtin or `unknown`.
                    var return_type: types.TypeId = undefined;
                    if (decl.return_type) |ann| {
                        return_type = try resolveAnnotation(allocator, &diag_list, tree, ann, source.path, type_store);
                    } else {
                        return_type = builtins.unknown;
                    }
                    return_type = try type_inference.wrapFunctionReturn(return_type, decl.flags, type_store);

                    // Build a function signature from the collected parameter list and resolved return type. The FunctionSignature is allocated by an arena-owned store — each call to `add()` appends into a shared ArrayList on the collector's allocator so lifetime remains tied to the enclosing analysis pass (typically a binder-level arena). The resulting signature_id is paired with the function's symbol_id in `signature_entries` for downstream consumption.
                    const sig = try type_store.addFunctionDetailed(
                        local_params.items,
                        return_type,
                        @intCast(decl.type_parameters.len),
                        .{
                            .is_async = decl.flags.is_async,
                            .is_generator = decl.flags.is_generator,
                        },
                    );

                    for (bind.node_symbols) |ns| {
                        if (ns.node == node_id) {
                            try signature_entries.append(allocator, .{
                                .symbol_id = ns.symbol,
                                .signature_id = sig,
                                .resolved_return_type = return_type,
                            });
                            break;
                        }
                    }
                },
                .Parameter => |param| {
                    const ann = param.type_annotation orelse continue;
                    const type_id = try resolveAnnotation(allocator, &diag_list, tree, ann, source.path, type_store);

                    // The binder declared this parameter with `symbol.declaration == param_id` and `symbol.kind == .parameter`. Each symbol appears exactly once in the enclosing scope's symbols slice during collection.
                    _ = appendOrOom(&out_list, allocator, .{
                        .symbol_id = symbol.id,
                        .declared_type = type_id,
                    });
                },
                .TypeAliasDeclaration => |decl| {
                    const type_id = try resolveAnnotation(
                        allocator,
                        &diag_list,
                        tree,
                        decl.type_annotation,
                        source.path,
                        type_store,
                    );
                    _ = appendOrOom(&out_list, allocator, .{
                        .symbol_id = symbol.id,
                        .declared_type = type_id,
                    });
                },
                else => {},
            }
        }
    }

    // End of i_scope loop.

    return .{
        .symbol_declared_types = try out_list.toOwnedSlice(allocator),
        .function_signatures = signature_entries.items,
        .diagnostics = try diag_list.toOwnedSlice(allocator),
        .allocator_ = &allocator,
    };
}

/// Quietly discards OutOfMemory on append — used in contexts with no error path upward.
fn appendOrOom(list: *std.ArrayList(DeclaredSymbolType), gpa: std.mem.Allocator, item: DeclaredSymbolType) void {
    if (list.append(gpa, item)) |_| {} else |_| unreachable;
}
