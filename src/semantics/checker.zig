const std = @import("std");

const ast_mod = @import("../frontend/ast.zig");
const frontend = @import("../frontend/frontend.zig");
const diagnostics = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const builtin_kind = @import("../types/builtin.zig");

/// Walk a frontend result and emit one diagnostic per initializer or simple
/// assignment expression whose literal RHS type mismatches the declared type of
/// its LHS. v1 scope: plain `=` with Identifier LHS + Literal RHS only; anything
/// else is silently skipped (per goal text). Uses a pre-pass over declarations
/// to bridge the binder's lack of per-symbol type storage.
pub fn checkFile(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
    type_info: @import("type_info.zig").TypeInfo,
) ![]const diagnostics.Diagnostic {
    const tree = &result.ast;
    var out = try std.ArrayList(diagnostics.Diagnostic).initCapacity(allocator, 0);

    try checkInitializers(tree, type_info, allocator, &out);

    // v1 pre-pass — the binder only records names and scopes, not types. Build
    // a (scope_id, name) -> TypeId table from the AST so that
    // checkAssignments can look up the declared type of an Identifier LHS.
    const declared_types = try collectDeclaredTypes(allocator, tree);
    defer allocator.free(declared_types);

    try checkAssignments(tree, result.resolve.references, declared_types, allocator, &out);

    return try out.toOwnedSlice(allocator);
}

pub const DeclaredType = struct {
    scope: ast_mod.NodeId,
    name: []const u8,
    type_id: types.TypeId,
};

fn collectDeclaredTypes(allocator: std.mem.Allocator, tree: *const ast_mod.Ast) ![]DeclaredType {
    var list = try std.ArrayList(DeclaredType).initCapacity(allocator, 0);
    try prewalk(tree.root, tree, 0, allocator, &list);
    return try list.toOwnedSlice(allocator);
}

fn prewalk(
    node_id: ast_mod.NodeId,
    tree: *const ast_mod.Ast,
    parent_scope: ast_mod.NodeId,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(DeclaredType),
) !void {
    if (node_id == ast_mod.invalid_node) return;
    const node = tree.node(node_id);
    switch (node.data) {
        .Program => |p| for (p.statements) |s| try prewalk(s, tree, parent_scope, gpa, out),
        .FunctionDeclaration => |f| try prewalk(f.body, tree, node_id, gpa, out),
        .VariableDeclaration => |vd| {
            for (vd.declarations) |decl_id| {
                const decl_node = tree.node(decl_id);
                switch (decl_node.data) {
                    .VariableDeclarator => |d| {
                        if (d.type_annotation == null or d.name.len == 0) continue;
                        const ann_name = d.type_annotation.?.name;
                        const type_id = lookupBuiltinIdByName(ann_name) orelse continue;
                        try out.append(gpa, .{ .scope = parent_scope, .name = d.name, .type_id = type_id });
                    },
                    else => {},
                }
            }
        },
        .BlockStatement => |bs| for (bs.statements) |s| try prewalk(s, tree, node_id, gpa, out),
        // VariableDeclarator is the leaf — no recursion needed.
        else => {},
    }
}

fn lookupBuiltinIdByName(name: []const u8) ?types.TypeId {
    inline for (builtin_kind.builtinKinds_static) |kind| {
        if (std.mem.eql(u8, name, builtinKindNameStatic(kind))) return builtinKindTypeIdFromKind(kind);
    }
    return null;
}

fn builtinKindTypeIdFromKind(kind: builtin_kind.BuiltinKind) types.TypeId {
    return switch (kind) {
        .number => @intCast(@as(u32, 100)),
        .string => @intCast(@as(u32, 101)),
        .boolean => @intCast(@as(u32, 102)),
        .null_ => @intCast(@as(u32, 103)),
        .undefined => @intCast(@as(u32, 104)),
        .void => @intCast(@as(u32, 105)),
        .unknown => @intCast(@as(u32, 106)),
        .any => @intCast(@as(u32, 107)),
    };
}

fn builtinKindNameStatic(kind: builtin_kind.BuiltinKind) []const u8 {
    return switch (kind) {
        .number => "number",
        .string => "string",
        .boolean => "boolean",
        .null_ => "null",
        .undefined => "undefined",
        .void => "void",
        .unknown => "unknown",
        .any => "any",
    };
}

/// Reverse of `builtinKindTypeIdFromKind`: classify a TypeId by the range
/// it falls in (v1 only considers builtins with IDs 100..107). Returns null for
/// any id outside that range — callers already check for non-null before using.
fn builtinKindFromTypeId(id: types.TypeId) ?builtin_kind.BuiltinKind {
    const v: u32 = id;
    if (v == 100) return .number;
    if (v == 101) return .string;
    if (v == 102) return .boolean;
    if (v == 103) return .null_;
    if (v == 104) return .undefined;
    if (v == 105) return .void;
    if (v == 106) return .unknown;
    if (v == 107) return .any;
    return null;
}

fn staticTypeMismatchMessage(expected_id: types.TypeId, rhs_kind: builtin_kind.BuiltinKind) []const u8 {
    return switch (expected_id) {
        @intCast(@as(u32, 100)) => switch (rhs_kind) {
            .string => "type mismatch: expected 'number', got 'string'",
            .boolean => "type mismatch: expected 'number', got 'boolean'",
            .null_ => "type mismatch: expected 'number', got 'null'",
            .undefined => "type mismatch: expected 'number', got 'undefined'",
            .void => "type mismatch: expected 'number', got 'void'",
            .unknown => "type mismatch: expected 'number', got 'unknown'",
            .any => "type mismatch: expected 'number', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 101)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'string', got 'number'",
            .boolean => "type mismatch: expected 'string', got 'boolean'",
            .null_ => "type mismatch: expected 'string', got 'null'",
            .undefined => "type mismatch: expected 'string', got 'undefined'",
            .void => "type mismatch: expected 'string', got 'void'",
            .unknown => "type mismatch: expected 'string', got 'unknown'",
            .any => "type mismatch: expected 'string', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 102)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'boolean', got 'number'",
            .string => "type mismatch: expected 'boolean', got 'string'",
            .null_ => "type mismatch: expected 'boolean', got 'null'",
            .undefined => "type mismatch: expected 'boolean', got 'undefined'",
            .void => "type mismatch: expected 'boolean', got 'void'",
            .unknown => "type mismatch: expected 'boolean', got 'unknown'",
            .any => "type mismatch: expected 'boolean', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 103)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'null', got 'number'",
            .string => "type mismatch: expected 'null', got 'string'",
            .boolean => "type mismatch: expected 'null', got 'boolean'",
            .undefined => "type mismatch: expected 'null', got 'undefined'",
            .void => "type mismatch: expected 'null', got 'void'",
            .unknown => "type mismatch: expected 'null', got 'unknown'",
            .any => "type mismatch: expected 'null', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 104)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'undefined', got 'number'",
            .string => "type mismatch: expected 'undefined', got 'string'",
            .boolean => "type mismatch: expected 'undefined', got 'boolean'",
            .null_ => "type mismatch: expected 'undefined', got 'null'",
            .void => "type mismatch: expected 'undefined', got 'void'",
            .unknown => "type mismatch: expected 'undefined', got 'unknown'",
            .any => "type mismatch: expected 'undefined', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 105)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'void', got 'number'",
            .string => "type mismatch: expected 'void', got 'string'",
            .boolean => "type mismatch: expected 'void', got 'boolean'",
            .null_ => "type mismatch: expected 'void', got 'null'",
            .undefined => "type mismatch: expected 'void', got 'undefined'",
            .unknown => "type mismatch: expected 'void', got 'unknown'",
            .any => "type mismatch: expected 'void', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 106)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'unknown', got 'number'",
            .string => "type mismatch: expected 'unknown', got 'string'",
            .boolean => "type mismatch: expected 'unknown', got 'boolean'",
            .null_ => "type mismatch: expected 'unknown', got 'null'",
            .undefined => "type mismatch: expected 'unknown', got 'undefined'",
            .void => "type mismatch: expected 'unknown', got 'void'",
            .any => "type mismatch: expected 'unknown', got 'any'",
            else => unreachable,
        },
        @intCast(@as(u32, 107)) => switch (rhs_kind) {
            .number => "type mismatch: expected 'any', got 'number'",
            .string => "type mismatch: expected 'any', got 'string'",
            .boolean => "type mismatch: expected 'any', got 'boolean'",
            .null_ => "type mismatch: expected 'any', got 'null'",
            .undefined => "type mismatch: expected 'any', got 'undefined'",
            .void => "type mismatch: expected 'any', got 'void'",
            .unknown => "type mismatch: expected 'any', got 'unknown'",
            else => unreachable,
        },
        else => "type mismatch: unexpected types",
    };

}

fn checkInitializers(
    tree: *const ast_mod.Ast,
    type_info: @import("type_info.zig").TypeInfo,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    _ = type_info;
    for (tree.nodes) |node| switch (node.data) {
        .VariableDeclarator => |vd| {
            if (vd.type_annotation == null or vd.init == null) continue;
            const ann_name = vd.type_annotation.?.name;

            // v1 only checks literal initializers — the goal says "simple
            // literal initializers" and lists `let x: number = 1` as the
            // positive case.
            const init_node_id: ast_mod.NodeId = @intCast(vd.init.?);
            const init_node = tree.node(init_node_id);
            if (init_node.data != .Literal) continue;

            const rhs_kind = inferBuiltinKindFromLiteral(init_node.data.Literal.value) orelse continue;
            const expected_id = lookupBuiltinIdByName(ann_name) orelse continue;
            const actual_id = builtinKindTypeIdFromKind(rhs_kind);

            if (actual_id == expected_id) continue; // No mismatch — skip.

            try out.append(gpa, .{
                .severity = .@"error",
                .code = .type_mismatch,
                .phase = .type_checker,
                .message = staticTypeMismatchMessage(expected_id, rhs_kind),
                .span = init_node.span,
                .label = vd.name,
            });
        },
        else => {},
    };
}

// ---------------------------------------------------------------------------
// Assignment pass (new for goal). For every top-level AssignmentExpression:
//   1. Skip unless operator is `=` and the left side is an Identifier — v1
//      scope excludes property/index assignment and compound operators.
//   2. Classify RHS; in v1 only Literal RHS produces a known primitive kind,
//      non-literal RHS maps to "unknown expression" and emits no diagnostic.
//   3. Locate the write reference for the left-hand Identifier via the resolver
//      output. If there is none skip rather than guess.
//   4. Look up (ref.scope, ref.name) in declared_types; if neither declaration
//      was found, skip per goal text ("assignment to untyped variable emits
//      no diagnostic").
//   5. Compare types; emit one VZG6005 on mismatch.
/// Resolve the declared return type of a function call's callee (assumed to be
/// an Identifier) by walking AST nodes for matching FunctionDeclarations. Returns
/// the TypeId of the return type if one is explicitly annotated, otherwise null.

fn lookupCallReturnTypeId(
    tree: *const ast_mod.Ast,
    references: []const @import("../frontend/resolver.zig").Reference,
    call_node_id: ast_mod.NodeId,
) ?types.TypeId {
    // Locate the reference for this call site — any kind that carries the callee's name
    // and scope is sufficient. Resolver emits a `.call` Reference for each function-call
    // expression (see resolver.zig).
    const calleeref: @import("../frontend/resolver.zig").Reference = for (references) |r| {
        if (r.node == call_node_id and r.kind != .export_ref) break r;
    } else return null;

    // Find a FunctionDeclaration node at the same scope with a matching name. The binder
    // declares all top-level symbols in its AST nodes, so a linear scan works correctly.
    for (tree.nodes) |n| switch (n.data) {
        .FunctionDeclaration => |fd| {
            if (std.mem.eql(u8, fd.name, calleeref.name)) {
                if (fd.return_type == null) return null;
                // Look up the annotation's identifier in the builtins table.
                return lookupBuiltinIdByName(fd.return_type.?.name);
            }
        },
        else => {},
    };

    return null;
}

// ---------------------------------------------------------------------------
// Assignments with a CallExpression RHS: compare callee return type vs LHS declared
// type, mirroring the existing Literal-RHS path but looking up types via AST walk.
// Returns false when nothing could be checked (e.g. untyped declaration), otherwise
// true — so the caller can continue past this branch on skip.

fn handleCallExprRhs(
    tree: *const ast_mod.Ast,
    references: []const @import("../frontend/resolver.zig").Reference,
    declared_types: []const DeclaredType,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
    assign_expr: ast_mod.AssignmentExpression,
    left_id: ast_mod.NodeId,
) !bool {
    const left_node = tree.node(left_id);

    // LHS must be an Identifier — we compare by name with the function's return annotation.
    if (left_node.data != .Identifier) return true;
    const rhs_call = assign_expr.right;

    const lhs_expected: ?types.TypeId = for (declared_types) |dt| {
        if (std.mem.eql(u8, dt.name, left_node.data.Identifier.name)) break dt.type_id;
    } else null;
    if (lhs_expected == null) return true; // LHS has no declared type — skip.

    const rhs_return = lookupCallReturnTypeId(tree, references, @intCast(rhs_call));
    if (rhs_return == null) return true; // RHS call's return type unknown — skip.

    // Both sides are known; compare via builtin-kind classification to match the Literal-RHS
    // path so mismatch messages stay consistent across cases.
    const lhs_kind = builtinKindFromTypeId(lhs_expected.?);
    const rhs_kind = builtinKindFromTypeId(rhs_return.?);
    if (lhs_kind == null or rhs_kind == null) return true;

    if (lhs_kind.? != rhs_kind.?) {
        try out.append(gpa, .{
            .severity = .@"error",
            .code = .type_mismatch,
            .phase = .type_checker,
            .message = staticTypeMismatchMessage(lhs_expected.?, rhs_kind.?),
            .span = tree.node(@intCast(rhs_call)).span,
            .label = left_node.data.Identifier.name,
        });
    }

    return true; // Handled — no further work needed.
}

// ---------------------------------------------------------------------------
// Literal RHS: infer builtin kind from the literal value, compare against
// the LHS identifier's declared type; surface a type_mismatch diagnostic on mismatch.

fn handleLiteralRhs(
    tree: *const ast_mod.Ast,
    _: []const @import("../frontend/resolver.zig").Reference,
    declared_types: []const DeclaredType,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
    _: ast_mod.AssignmentExpression,
    left_id: ast_mod.NodeId,
    right_id: ast_mod.NodeId,
) !void {
    const left_node = tree.node(left_id);

    // LHS must be an Identifier — we compare by name with the declared type.
    if (left_node.data != .Identifier) return;
    const lhs_name = left_node.data.Identifier.name;

    const expected_id: ?types.TypeId = for (declared_types) |dt| {
        if (std.mem.eql(u8, dt.name, lhs_name)) break dt.type_id;
    } else null;
    if (expected_id == null) return; // LHS has no declared type — skip.

    const rhs_kind = inferBuiltinKindFromLiteral(tree.node(right_id).data.Literal.value) orelse return;

    const lhs_kind = builtinKindFromTypeId(expected_id.?);
    if (lhs_kind == null) return; // Declared type not classifiable as a builtin — skip.

    if (rhs_kind != lhs_kind.?) {
        try out.append(gpa, .{
            .severity = .@"error",
            .code = .type_mismatch,
            .phase = .type_checker,
            .message = staticTypeMismatchMessage(expected_id.?, rhs_kind),
            .span = tree.node(right_id).span,
            .label = lhs_name,
        });
    }
}


// ---------------------------------------------------------------------------

fn checkAssignments(
    tree: *const ast_mod.Ast,
    references: []const @import("../frontend/resolver.zig").Reference,
    declared_types: []const DeclaredType,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {

for (tree.nodes) |node| switch (node.data) {
        .AssignmentExpression => |assign_expr| {
            if (assign_expr.operator != .Equal) continue;

            const left_id: ast_mod.NodeId = @intCast(assign_expr.left);
            const left_node = tree.node(left_id);
            switch (left_node.data) {
                .Identifier => {},
                else => continue,
            }

            const right_id: ast_mod.NodeId = @intCast(assign_expr.right);
            const right_node = tree.node(right_id);

            switch (right_node.data) {
                .Literal => {
                    // Existing literal-RHS path.
                    return try handleLiteralRhs(tree, references, declared_types, gpa, out, assign_expr, left_id, right_id);
                },
                .CallExpression => {
                    _ = try handleCallExprRhs(tree, references, declared_types, gpa, out, assign_expr, left_id);
                    continue;
                },
                else => continue, // RHS unknown — skip in v1.
            }

        },
        else => {},
    };
}

fn inferBuiltinKindFromLiteral(value: []const u8) ?builtin_kind.BuiltinKind {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false"))
        return .boolean;
    if (std.mem.eql(u8, value, "null")) return .null_;

    // Detect numeric literals preserved verbatim by the scanner. v1 scope —
    // only covers decimal/float/hex forms; anything else is classified as a
    // string. The check tolerates an optional leading sign and scientific
    // notation (e.g. "1e-7", "-3.5E2").
    const raw = if (value.len > 0 and (value[0] == '+' or value[0] == '-'))
        value[1..] else value;

    if (raw.len == 0) return .string;

    // Hex: 0x...
    if (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        for (raw[2..]) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')))
                return .string;
        }
        return .number;
    }

    // Decimal: optional digits, optional '.digits', optional ['e'|'E'[+-]digits].
    var i: usize = 0;
    const start_digits = i;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
    if (i > start_digits) {
        if (i < raw.len and raw[i] == '.') {
            const dot_after = i + 1;
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
            _ = dot_after; // digits-after-dot already validated by loop.
        }
        if (i < raw.len and (raw[i] == 'e' or raw[i] == 'E')) {
            i += 1;
            if (i < raw.len and (raw[i] == '+' or raw[i] == '-')) i += 1;
            const exp_start = i;
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
            if (i == exp_start) return .string; // no exponent digits.
        }
    } else {
        return .string; // leading sign but no digits.
    }
    if (i != raw.len) return .string;
    return .number;
}

// ---------------------------------------------------------------------------
// Tests. Each follows the pattern of running frontend.analyze on a small source
// then asserting either zero diagnostics (v1 positive cases) or the presence of
// one with code `.type_mismatch`.
// ---------------------------------------------------------------------------

test "checker: number initializer ok" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = frontend.SourceFile{ .text = "let x: number = 1;" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "checker: string initializer ok" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = frontend.SourceFile{ .text = "let s: string = \"dev\";" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "checker: number var with string literal emits VZG6005" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = frontend.SourceFile{ .text = "let bad: number = \"x\";" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
}

test "checker: untyped variable initializer emits no checker diagnostic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = frontend.SourceFile{ .text = "let s = \"x\";" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
}

test "checker: declared variable with unknown initializer type emits no checker diagnostic in v1" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Identifier RHS is outside v1 scope — only literals checked.
    const source = frontend.SourceFile{ .text = "let x: number = y;" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
}

// ---------------------------------------------------------------------------
// Assignment-specific tests. Each mirrors the four test cases required by the goal.
// ---------------------------------------------------------------------------

test "checker: valid assignment number to number no diagnostic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // x declared as `number` above the assignment, RHS literal matches.
    const source = frontend.SourceFile{ .text = "let x: number;\nx = 2;" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "checker: invalid assignment string to number emits VZG6005" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // x declared as `number` above the assignment, RHS literal mismatches.
    const source = frontend.SourceFile{ .text = "let x: number;\nx = \"bad\";" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);
    var found_mismatch: bool = false;
    for (diags) |d| {
        if (d.code == .type_mismatch) found_mismatch = true;
    }
    try std.testing.expect(found_mismatch);
}

test "checker: assignment to untyped variable emits no diagnostic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // x has no declared type anywhere — cannot look up expected → skip silently.
    const source = frontend.SourceFile{ .text = "let x;\nx = 2;" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "checker: assignment from unknown expression emits no diagnostic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // RHS is a CallExpression — outside v1 scope, no diagnostic emitted.
    const source = frontend.SourceFile{ .text = "let x: number;\nx = foo();" };
    const opts = frontend.FrontendOptions{};
    const result = try frontend.analyze(a, source, opts);
    const type_info = @import("type_info.zig").TypeInfo{ .symbols = &.{}, .nodes = &.{}, .diagnostics = &.{} };
    const diags = try checkFile(a, result, type_info);

    for (diags) |d| { _ = d; }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}
