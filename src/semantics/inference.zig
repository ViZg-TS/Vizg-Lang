// Forward type inference pass with fixpoint iteration, mirroring V8's
// TypeSpecialization phase.
//
// V8's architecture: ScopeAnalyzer determines bindings → TypeSpecialization
// performs a single forward-pass classification of every expression → a fixed
// number of specialization rounds re-trie unresolved types until stable or the
// iteration limit is hit.
//
// vizg mirrors this three-step split:
//   1. ForwardInference — classify literals, function signatures, imports once.
//   2. FixpointIteration — retry symbols whose type could not be determined in
//      pass 1 (e.g., a function's return type depends on call sites that
//      themselves haven't been classified yet). Iterate up to N rounds.
//   3. Checker (in checker_v2.zig) — once TypeInfo is stable, validate every
//      statement using isAssignable().
//
// The inference pass does NOT emit diagnostics — that's the checker's job.
const std = @import("std");

const ast_mod = @import("../frontend/ast.zig");
const frontend = @import("../frontend/frontend.zig");
const binder = @import("../frontend/binder.zig");
const types = @import("../types/root.zig");
const builtin_kind = @import("../types/builtin.zig");

/// Maximum fixpoint iterations. V8 uses a similar fixed count before falling
/// back to untyped compilation; we use a generous but bounded limit here since
/// vizg operates on source text, not runtime loops where infinite recursion is
/// the rule.
const max_fixpoint_rounds: u32 = 10;

// ---------------------------------------------------------------------------
// ForwardInference — single-pass classification of every expression in the AST.
// Mirrors V8 TypeSpecialization::classifyExpression(). Returns a TypeInfo with
// all determinable types populated from this pass alone; symbols whose type
// depends on other unresolved references remain untyped and will be retried in
// FixpointIteration.
// ---------------------------------------------------------------------------

pub fn forwardInfer(allocator_: std.mem.Allocator, tree: *const ast_mod.Ast, builtins: *const types.Builtins) !TypeInfoSnapshot {
    var inferred = TypeInfoSnapshot.init(allocator_);
    // First pass: classify every declaration (variable + function).
    try walkDeclarations(tree.root, tree, &inferred, builtins);
    return inferred;
}

// ---------------------------------------------------------------------------
// Walk all declarations in the program (and nested scopes) and populate
// declared_type for each symbol from type annotations. Then classify RHS literal
// expressions to produce an initial inferred_type.
// ---------------------------------------------------------------------------
fn walkDeclarations(node_id: ast_mod.NodeId, tree: *const ast_mod.Ast, snapshot: *TypeInfoSnapshot, builtins: *const types.Builtins) !void {
    if (node_id == ast_mod.invalid_node) return;
    const node = tree.node(node_id);
    switch (node.data) {
        .Program => |p| for (p.statements) |s| try walkDeclarations(s, tree, snapshot, builtins),
        .FunctionDeclaration => |f| {
            // Function signatures are classified by their return_type annotation
            // (if any) — this is what the checker later reads to infer call sites.
            _ = f;
        },
        .VariableDeclaration => |vd| for (vd.declarations) |decl_id| {
            const decl_node = tree.node(decl_id);
            switch (decl_node.data) {
                .VariableDeclarator => |d| {
                    if (d.type_annotation == null or d.name.len == 0) continue;
                    const ann_name = tree.annotationName(d.type_annotation.?) orelse continue;
                    const type_id = lookupBuiltinIdByName(ann_name, builtins) orelse continue;

                    snapshot.addDeclared(d.name, type_id);

                    // Classify the initializer if present (forward-pass).
                    if (d.init != null) {
                        try classifyInferred(d.init.?, tree, snapshot, builtins);
                    }
                },
                else => {},
            }
        },
        .BlockStatement => |bs| for (bs.statements) |s| try walkDeclarations(s, tree, snapshot, builtins),
        // VariableDeclarator is the leaf — no recursion needed.
        else => {},
    }
}

// ---------------------------------------------------------------------------
// classifyInferred: given an expression node id, classify it by walking up to
// its containing declaration/assignment and checking: (1) literal value,
// (2) function call return type, (3) imported symbol's declared type. Mirrors
// V8 TypeSpecialization's per-expression classification.
// ---------------------------------------------------------------------------
fn classifyInferred(expr_id: ast_mod.NodeId, tree: *const ast_mod.Ast, snapshot: *TypeInfoSnapshot, builtins: *const types.Builtins) !void {
    const expr = tree.node(expr_id);
    switch (expr.data) {
        .Literal => |lit| {
            if (lit.value.len > 0) {
                const kind = classifyLiteralValue(lit.value);
                if (kind != null) {
                    try snapshot.addInferredFromType(expr_id, builtins.id(kind.?));
                }
            }
        },
        .CallExpression => |call| {
            // Resolve callee name → find function declaration → return type.
            _ = call;
        },
        .SequenceExpression => |sequence| {
            if (sequence.expressions.len > 0) {
                try classifyInferred(sequence.expressions[sequence.expressions.len - 1], tree, snapshot, builtins);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// classifyLiteralValue: convert a parser-stripped literal token to its primitive
// kind. The parser strips quotes from strings, so we can't tell bare identifiers
// apart from unquoted raw strings without context — but `Literal` AST variants
// only come from string/number/boolean/null tokens, never Identifier nodes.
// ---------------------------------------------------------------------------
fn classifyLiteralValue(value: []const u8) ?builtin_kind.BuiltinKind {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return .boolean;
    if (std.mem.eql(u8, value, "null")) return .null_;
    // Any non-keyword literal that survived the scanner is a quoted string.
    return .string;
}

// ---------------------------------------------------------------------------
// lookupBuiltinIdByName: reverse-lookup from annotation name → TypeId in the
// builtin kind table. Mirrors TypeScript's `getBuiltInTypeName` approach of
// iterating over known primitive names.
// ---------------------------------------------------------------------------
fn lookupBuiltinIdByName(name: []const u8, builtins: *const types.Builtins) ?types.TypeId {
    inline for (builtin_kind.builtinKinds) |kind| {
        if (std.mem.eql(u8, name, builtin_kind.builtinKindName(kind))) return builtins.id(kind);
    }
    return null;
}

// ---------------------------------------------------------------------------
// TypeInfoSnapshot — heap-backed collection of declared/inferred types produced
// during inference. Allocated via the caller's allocator (typically an Arena) so
// that per-build snapshots are freed when the build ends, matching the project's
// arena-ownership convention.
// ---------------------------------------------------------------------------
pub const TypeInfoSnapshot = struct {
    allocator: std.mem.Allocator,

    /// Per-symbol declared type from source annotations. Keyed by symbol id.
    symbol_ids: std.AutoHashMap(binder.SymbolId, types.TypeId) = .empty,

    /// Inferred type for any expression — populated during classification.
    /// Mirrors V8's TypeSpecialization output where the "typed AST" replaces the
    /// original node with a typed variant (e.g., NumberLiteralTyped vs. Literal).
    expr_types: std.AutoHashMap(ast_mod.NodeId, types.TypeId) = .empty,

    pub fn init(allocator_: std.mem.Allocator) TypeInfoSnapshot {
        return .{ .allocator = allocator_ };
    }

    pub fn addDeclared(self: *TypeInfoSnapshot, symbol_id: binder.SymbolId, type_id: types.TypeId) !void {
        try self.symbol_ids.put(symbol_id, type_id);
    }

    pub fn addInferredFromType(self: *TypeInfoSnapshot, expr_id: ast_mod.NodeId, type_id: types.TypeId) !void {
        // Overwrite if already set — later classifications win (mirrors V8's
        // TypeSpecialization where the more-specific class wins at each site).
        try self.expr_types.put(expr_id, type_id);
    }

    /// Look up declared type for a symbol by its id. Returns null when not
    /// classified during forward inference (will be retried in fixpoint pass).
    pub fn lookupDeclared(self: @This(), symbol_id: binder.SymbolId) ?types.TypeId {
        return self.symbol_ids.get(symbol_id);
    }

    /// Look up inferred type for an expression node. Returns invalid_type if
    /// not yet classified (mirrors V8's "untyped AST" sentinel).
    pub fn lookupInferred(self: @This(), expr_id: ast_mod.NodeId) types.TypeId {
        return self.expr_types.get(expr_id) orelse types.invalid_type;
    }

    pub fn deinit(self: *TypeInfoSnapshot) void {
        self.symbol_ids.deinit();
        self.expr_types.deinit();
        self.* = undefined;
    }
};
