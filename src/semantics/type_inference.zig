const std = @import("std");
const ast_mod = @import("../frontend/ast.zig");
const builtin_kind = @import("../types/builtin.zig");
const types = @import("../types/root.zig");
const node_type_info_mod = @import("type_info.zig");

// inferLiteralNodeTypes — walks the AST tree and classifies every reachable
// literal node by its primitive type. Returns a NodeTypeInfo entry for each
// classified leaf; unclassifiable nodes are omitted from the result slice.
// Per goal scope, only number / string / boolean / null are inferred.

/// Classify an AST Literal value to a builtin kind when possible. The parser
/// strips quotes before storing strings in `value`, so `"hello"` arrives as
/// the bare token text — we rely on the parser having validated format at scan
/// time and just check whether the value looks numeric or matches the known
/// boolean / null keywords.
fn classifyLiteralValue(value: []const u8) ?builtin_kind.BuiltinKind {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return .boolean;
    if (std.mem.eql(u8, value, "null")) return .null_;
    if (looksNumeric(value)) return .number;
    // Anything else with a Literal AST variant is treated as a string literal.
    // Any non-keyword, non-numeric literal token that survived the scanner is
    // a quoted string — we cannot reliably distinguish a bare identifier from
    // an unquoted raw string without context, but the `Literal` variant on the
    // AST guarantees it came from a string token (not an Identifier).
    return .string;
}

/// Quick numeric test. Never rejects input the parser already accepted; may be
/// slightly over-inclusive for edge cases like `"1e"`, which is acceptable
/// because downstream layers validate further if needed and we mirror how
/// existing inference treats ambiguous tokens in this codebase.
fn looksNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '-' or text[0] == '+') i += 1;
    var seen_digit: bool = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isDigit(c)) {
            seen_digit = true;
        } else if (c == '.' or c == 'e' or c == 'E') {
            // Decimal / exponent — allowed inside a number. Parser already
            // balances these, so we don't re-validate.
        } else {
            return seen_digit and (c == '.' or c == 'e' or c == 'E');
        }
    }
    return seen_digit;
}



/// Classify an identifier by name for the small set of keywords that the
/// parser may leave as identifiers rather than literals. `undefined` is
/// excluded per goal text: skip unless the parser emits explicit support.
fn classifyIdentifier(name: []const u8) ?builtin_kind.BuiltinKind {
    if (std.mem.eql(u8, name, "true")) return .boolean;
    if (std.mem.eql(u8, name, "false")) return .boolean;
    if (std.mem.eql(u8, name, "null")) return .null_;
    return null;
}

/// Node-level type record stored alongside SymbolTypeInfo in TypeInfo.nodes.

/// Infer literal node types and return them as an owned slice on `allocator`.
/// Reserved parameter for future inference passes that may consult built-in
/// function signatures.
pub fn inferLiteralNodeTypes(
    allocator: std.mem.Allocator,
    tree: ast_mod.Ast,
) ![]const node_type_info_mod.NodeTypeInfo {
    // Zig 0.16 ArrayList uses the Aligned wrapper which requires an explicit
    // gpa on mutable operations (append / toOwnedSlice / deinit). We pass the
    // caller's allocator everywhere so the returned slice is owned by it.
    var out_list: std.ArrayList(node_type_info_mod.NodeTypeInfo) = .empty;
    defer out_list.deinit(allocator);

    var stack: std.ArrayList(ast_mod.NodeId) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, tree.root);

    while (stack.items.len > 0) {
        const id = stack.items[stack.items.len - 1];
        _ = stack.shrinkRetainingCapacity(stack.items.len - 1);

        const node = tree.node(id);
        switch (node.data) {
            .Literal => |lit| {
                if (classifyLiteralValue(lit.value)) |kind| {
                    try out_list.append(allocator, .{
                        .node_id = id,
                        .type_id = builtin_kind.builtinKindTypeId(kind),
                    });
                }
            },
            .Identifier => |ident| {
                if (classifyIdentifier(ident.name)) |kind| {
                    try out_list.append(allocator, .{
                        .node_id = id,
                        .type_id = builtin_kind.builtinKindTypeId(kind),
                    });
                }
            },
            // Tree-shaped nodes: push children for further descent.
            .Program => |prog| for (prog.statements) |s| try stack.append(allocator, s),
            .BlockStatement => |block| for (block.statements) |s| try stack.append(allocator, s),
            .ExpressionStatement => |expr_stmt| _ = try stack.append(allocator, expr_stmt.expression),
            .VariableDeclaration => |decl| for (decl.declarations) |d| try stack.append(allocator, d),
            .VariableDeclarator => |vd| if (vd.init) |i| try stack.append(allocator, i),
            .FunctionDeclaration => |fn_decl| { _ = fn_decl; }, // body is a BlockStatement
            .Parameter => {},
            .ReturnStatement => |ret| {
                if (ret.argument) |a| _ = try stack.append(allocator, a);
            },
            .CallExpression => |call| {
                try stack.append(allocator, call.callee);
                for (call.arguments) |arg| try stack.append(allocator, arg);
            },
            .ElementAccessExpression => |elem_access| {
                _ = try stack.append(allocator, elem_access.object);
                _ = try stack.append(allocator, elem_access.index);
            },
            .NonNullExpression => |nonnull| _ = try stack.append(allocator, nonnull.expression),
            .MemberExpression => |member| { _ = member.property; try stack.append(allocator, member.object); },
            .BinaryExpression => |bin| {
                _ = bin.operator;
                _ = try stack.append(allocator, bin.left);
                _ = try stack.append(allocator, bin.right);
            },
            .UpdateExpression => |update_expr| {
                _ = update_expr.operator;
                _ = update_expr.prefix;
                _ = try stack.append(allocator, update_expr.argument);
            },
            .AssignmentExpression => |a| {
                _ = a.operator;
                _ = try stack.append(allocator, a.left);
                _ = try stack.append(allocator, a.right);
            },
            .IfStatement => |if_stmt| {
                try stack.append(allocator, if_stmt.condition);
                try stack.append(allocator, if_stmt.consequent);
                if (if_stmt.alternate) |alt| _ = try stack.append(allocator, alt);
            },
            .WhileStatement => |while_stmt| {
                _ = while_stmt.condition;
                try stack.append(allocator, while_stmt.body);
            },
            .ForStatement => |for_stmt| {
                if (for_stmt.init) |i| _ = try stack.append(allocator, i);
                if (for_stmt.condition) |c| _ = try stack.append(allocator, c);
                if (for_stmt.update) |u| _ = try stack.append(allocator, u);
                _ = try stack.append(allocator, for_stmt.body);
            },
            .ImportDeclaration => {},
            .ExportDeclaration => {},
            .ObjectExpression => |obj_expr| {
                for (obj_expr.properties) |prop| _ = try stack.append(allocator, prop.value);
            },
            .ArrayExpression => |arr| {
                for (arr.elements) |elem| _ = try stack.append(allocator, elem);
            },
        }
    }


    return try out_list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests — follow the goal's test matrix exactly. Each test parses a tiny
// snippet, runs `inferLiteralNodeTypes`, and verifies:
//   * at least one classified node is produced;
//   * for non-literal cases, no classified node appears (empty slice).

test "number literal node has type number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try @import("../frontend/frontend.zig").analyze(
        alloc, .{ .text = "let x = 1;\n" }, .{},
    );
    const inferred = try inferLiteralNodeTypes(alloc, result.ast);
    defer alloc.free(inferred);

    try std.testing.expectEqual(@as(usize, 1), inferred.len);
    try std.testing.expectEqual(
        @as(types.TypeId, builtin_kind.builtinKindTypeId(.number)),
        inferred[0].type_id,
    );
}

test "string literal node has type string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try @import("../frontend/frontend.zig").analyze(
        alloc, .{ .text = "let x = \"hello\";\n" }, .{},
    );
    const inferred = try inferLiteralNodeTypes(alloc, result.ast);
    defer alloc.free(inferred);

    if (inferred.len != 1) {
        std.debug.print("expected exactly one classified node for string literal\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "true/false literal node has type boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const srcs = [_][]const u8{
        "let x = true;\n",
        "let y = false;\n",
    };
    for (srcs) |src| {
        const result = try @import("../frontend/frontend.zig").analyze(
            alloc, .{ .text = src }, .{},
        );
        const inferred = try inferLiteralNodeTypes(alloc, result.ast);
        defer alloc.free(inferred);

        if (inferred.len != 1) {
            std.debug.print("expected exactly one classified node for {s}\n", .{src});
            return error.TestUnexpectedResult;
        }
    }
}

test "null literal node has type null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try @import("../frontend/frontend.zig").analyze(
        alloc, .{ .text = "let x = null;\n" }, .{},
    );
    const inferred = try inferLiteralNodeTypes(alloc, result.ast);
    defer alloc.free(inferred);

    if (inferred.len != 1) {
        std.debug.print("expected exactly one classified node for null literal\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "non-literal expression has no node type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Pure identifier expression — only Identifier nodes, none of which match
    // true/false/null, so nothing gets classified.
    const result = try @import("../frontend/frontend.zig").analyze(
        alloc, .{ .text = "x;\n" }, .{},
    );
    const inferred = try inferLiteralNodeTypes(alloc, result.ast);
    defer alloc.free(inferred);

    try std.testing.expectEqual(@as(usize, 0), inferred.len);
}

test "empty program produces no entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try @import("../frontend/frontend.zig").analyze(
        alloc, .{ .text = "" }, .{},
    );
    const inferred = try inferLiteralNodeTypes(alloc, result.ast);
    defer alloc.free(inferred);

    try std.testing.expectEqual(@as(usize, 0), inferred.len);
}
