const std = @import("std");

const ast_mod = @import("../frontend/ast.zig");
const frontend = @import("../frontend/frontend.zig");
const binder = @import("../frontend/binder.zig");
const tokens = @import("../frontend/tokens.zig");
const diagnostics = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const type_compat = @import("type_compat.zig");
const type_info_mod = @import("type_info.zig");

/// Checker v2 consumes the canonical semantic tables. It does not parse source,
/// resolve annotation text, or infer expression types.
pub fn checkFile(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
) ![]const diagnostics.Diagnostic {
    var out: std.ArrayList(diagnostics.Diagnostic) = .empty;
    const tree = &result.ast;

    for (tree.nodes, 0..) |node, raw_id| {
        const node_id: ast_mod.NodeId = @intCast(raw_id);
        switch (node.data) {
            .VariableDeclarator => |declaration| try checkInitializer(allocator, result, type_info, store, node_id, declaration, &out),
            .AssignmentExpression => |assignment| try checkAssignment(allocator, tree, type_info, store, assignment, &out),
            .CallExpression => |call| try checkCall(allocator, tree, type_info, store, node_id, call.callee, call.arguments, &out),
            .NewExpression => |call| try checkCall(allocator, tree, type_info, store, node_id, call.callee, call.arguments, &out),
            .FunctionDeclaration, .FunctionExpression, .ArrowFunctionExpression => try checkFunctionReturns(allocator, result, type_info, store, node_id, &out),
            else => try emitInferenceIssue(allocator, tree, type_info, node_id, &out),
        }
    }

    sortDiagnostics(out.items);
    return out.toOwnedSlice(allocator);
}

fn checkInitializer(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    declaration_id: ast_mod.NodeId,
    declaration: ast_mod.VariableDeclarator,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const initializer = declaration.init orelse return;
    const symbol = symbolForDeclaration(result.bind, declaration_id) orelse return;
    const symbol_type = type_info.lookupSymbol(symbol.id) orelse return;
    const expected = symbol_type.declared_type orelse return;
    const actual = resolvedNode(type_info, initializer, store) orelse return;
    if (type_compat.check(actual, expected, store).isCompatible()) return;

    // When both sides are aggregates with a compatible shape (matching length
    // or matching keys), compare element-by-element and report per-position
    // mismatches. The generic diagnostic is preserved when shapes cannot be
    // meaningfully compared side-by-side so we do not silence real errors.
    const emitted = try checkAggregateElementMismatch(allocator, result.ast, store, result.ast.node(declaration_id).span, initializer, expected, actual, out);
    if (emitted) return;
    try appendDiagnostic(allocator, out, .type_mismatch, "initializer is not assignable to the declared type", "incompatible initializer", result.ast.node(initializer).span, symbol.span, "declared type is here");
}

fn checkAssignment(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    assignment: ast_mod.AssignmentExpression,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    if (assignment.operator != .Equal) return;
    const expected = resolvedNode(type_info, assignment.left, store) orelse return;
    const actual = resolvedNode(type_info, assignment.right, store) orelse return;
    if (type_compat.check(actual, expected, store).isCompatible()) return;
    try appendDiagnostic(allocator, out, .type_mismatch, "assigned value is not assignable to the target type", "incompatible assignment", tree.node(assignment.right).span, tree.node(assignment.left).span, "assignment target is here");
}

fn checkCall(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    call_id: ast_mod.NodeId,
    callee_id: ast_mod.NodeId,
    arguments: []const ast_mod.NodeId,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const info = type_info.lookupNodeInfo(call_id) orelse return;
    if (info.issue != .invalid_argument_count and info.issue != .invalid_argument_type) return;
    const callee_type = resolvedNode(type_info, callee_id, store) orelse return;
    const signature = store.lookupFunction(callee_type) orelse return;

    if (info.issue == .invalid_argument_count) {
        try appendDiagnostic(allocator, out, .invalid_argument_count, "argument count does not match the function signature", "invalid argument count", tree.node(call_id).span, tree.node(callee_id).span, "function signature is here");
        return;
    }

    for (arguments, 0..) |argument, index| {
        const actual = resolvedNode(type_info, argument, store) orelse continue;
        const parameter = parameterForArgument(signature, index) orelse continue;
        const expected = restArgumentType(parameter, store);
        if (type_compat.check(actual, expected, store).isCompatible()) continue;
        try appendDiagnostic(allocator, out, .invalid_argument_type, "argument is not assignable to the parameter type", "invalid argument type", tree.node(argument).span, tree.node(callee_id).span, "function signature is here");
        return;
    }
}

fn emitInferenceIssue(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    node_id: ast_mod.NodeId,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const info = type_info.lookupNodeInfo(node_id) orelse return;
    const detail: struct { code: diagnostics.DiagnosticCode, message: []const u8, label: []const u8 } = switch (info.issue) {
        .none, .invalid_argument_count, .invalid_argument_type => return,
        .invalid_operator => .{ .code = .type_mismatch, .message = "operator cannot be applied to these operand types", .label = "invalid operator operands" },
        .unknown_property => .{ .code = .unknown_property, .message = "property does not exist on this type", .label = "unknown property" },
        .invalid_index => .{ .code = .invalid_index, .message = "type cannot be indexed with this expression", .label = "invalid index" },
        .satisfies => .{ .code = .type_mismatch, .message = "expression does not satisfy the target type", .label = "satisfies check failed" },
    };
    const related = issueRelated(tree, node_id);
    try appendDiagnostic(allocator, out, detail.code, detail.message, detail.label, tree.node(node_id).span, related, "related operand is here");
}

fn checkFunctionReturns(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    function_id: ast_mod.NodeId,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const node = result.ast.node(function_id);
    const body: ast_mod.NodeId = switch (node.data) {
        .FunctionDeclaration => |function| if (function.return_type != null) function.body else return,
        .FunctionExpression => |function| if (function.return_type != null) function.body else return,
        .ArrowFunctionExpression => |function| if (function.return_type != null) function.body else return,
        else => return,
    };
    const expression_body = switch (node.data) {
        .ArrowFunctionExpression => |function| function.expression_body,
        else => false,
    };
    const function_type = functionType(result.bind, type_info, function_id) orelse return;
    const signature = store.lookupFunction(function_type) orelse return;
    const expected = unwrappedReturn(signature, store);
    if (expression_body) {
        const actual = resolvedNode(type_info, body, store) orelse return;
        if (!type_compat.check(actual, expected, store).isCompatible())
            try appendDiagnostic(allocator, out, .type_mismatch, "returned expression is not assignable to the declared return type", "incompatible return", result.ast.node(body).span, node.span, "function return type is declared here");
        return;
    }
    try checkReturnsIn(allocator, &result.ast, type_info, store, body, expected, node.span, out);
}

fn checkReturnsIn(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    node_id: ast_mod.NodeId,
    expected: types.TypeId,
    function_span: tokens.Span,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const node = tree.node(node_id);
    switch (node.data) {
        .ReturnStatement => |statement| {
            const actual = if (statement.argument) |argument| resolvedNode(type_info, argument, store) orelse return else store.builtins.undefined;
            if (type_compat.check(actual, expected, store).isCompatible()) return;
            const span = if (statement.argument) |argument| tree.node(argument).span else node.span;
            try appendDiagnostic(allocator, out, .type_mismatch, "returned value is not assignable to the declared return type", "incompatible return", span, function_span, "function return type is declared here");
        },
        .Program => |program| for (program.statements) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out),
        .BlockStatement => |block| for (block.statements) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out),
        .IfStatement => |statement| {
            try checkReturnsIn(allocator, tree, type_info, store, statement.consequent, expected, function_span, out);
            if (statement.alternate) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out);
        },
        .WhileStatement => |statement| try checkReturnsIn(allocator, tree, type_info, store, statement.body, expected, function_span, out),
        .DoWhileStatement => |statement| try checkReturnsIn(allocator, tree, type_info, store, statement.body, expected, function_span, out),
        .ForStatement => |statement| try checkReturnsIn(allocator, tree, type_info, store, statement.body, expected, function_span, out),
        .SwitchStatement => |statement| for (statement.cases) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out),
        .SwitchCase => |case| for (case.consequent) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out),
        .TryStatement => |statement| {
            try checkReturnsIn(allocator, tree, type_info, store, statement.block, expected, function_span, out);
            if (statement.handler) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out);
            if (statement.finalizer) |child| try checkReturnsIn(allocator, tree, type_info, store, child, expected, function_span, out);
        },
        .CatchClause => |clause| try checkReturnsIn(allocator, tree, type_info, store, clause.body, expected, function_span, out),
        .FinallyClause => |clause| try checkReturnsIn(allocator, tree, type_info, store, clause.body, expected, function_span, out),
        .LabeledStatement => |statement| try checkReturnsIn(allocator, tree, type_info, store, statement.body, expected, function_span, out),
        .FunctionDeclaration, .FunctionExpression, .ArrowFunctionExpression, .ClassDeclaration, .ClassExpression => {},
        else => {},
    }
}

/// When both expected and actual are aggregates with a matching shape (matching
/// length for arrays/tuples or matching keys for objects), walk side-by-side
/// and emit per-position element/type-mismatch diagnostics. Returns true if at
/// least one diagnostic was emitted; false when the shapes cannot be compared
/// positionally so the caller falls back to the generic "incompatible X" message.
fn checkAggregateElementMismatch(
    allocator: std.mem.Allocator,
    tree: ast_mod.Ast,
    store: *types.TypeStore,
    expected_span: tokens.Span,
    initializer_id: ast_mod.NodeId,
    expected: types.TypeId,
    actual: types.TypeId,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !bool {
    const expected_ty = store.lookup(expected) orelse return false;
    const actual_ty = store.lookup(actual) orelse return false;

    switch (expected_ty.kind) {
        .array => {
            if (actual_ty.kind != .array) return false;
            // Both sides are arrays. The outer check already determined the
            // declared element type and inferred element type disagree. Emit a
            // single element-level diagnostic rather than the generic message.
            try appendDiagnostic(allocator, out, .type_mismatch, "initializer element is not assignable to the declared array element type", "array element type mismatch", tree.node(initializer_id).span, expected_span, "declared array element type is here");
            return true;
        },
        .tuple => |expected_tuple| {
            if (actual_ty.kind != .tuple) return false;
            const actual_tuple = actual_ty.kind.tuple;
            if (expected_tuple.elements.len != actual_tuple.elements.len) return false;
            var emitted: bool = false;
            for (expected_tuple.elements, 0..expected_tuple.elements.len) |_, i| {
                const act_elem = actual_tuple.elements[i];
                if (act_elem.hole) continue;  // source-side holes carry no value to compare
                const msg = try std.fmt.allocPrint(allocator, "tuple element at index {} is not assignable to the declared type", .{i});
                const related = try std.fmt.allocPrint(allocator, "declared tuple element at index {} is here", .{i});
                try appendDiagnostic(allocator, out, .type_mismatch, msg, "element type mismatch", tree.node(initializer_id).span, expected_span, related);
                emitted = true;
            }
            return emitted;
        },
        .object => |expected_props| {
            if (actual_ty.kind != .object) return false;
            const actual_props = actual_ty.kind.object;
            var emitted: bool = false;
            for (expected_props) |exp_prop| {
                // Find matching key in the actual side.
                var found: ?usize = null;
                for (actual_props, 0..) |act_prop, index| {
                    if (std.mem.eql(u8, act_prop.name, exp_prop.name)) {
                        found = index;
                        break;
                    }
                }
                const actual_index = found orelse continue;  // key missing in actual — keep generic diagnostic for now
                const act_prop = actual_props[actual_index];
                if (act_prop.type_id == exp_prop.type_id) continue;
                try appendDiagnostic(allocator, out, .type_mismatch, "object property is not assignable to the declared type", "property type mismatch", tree.node(initializer_id).span, expected_span, "declared property is here");
                emitted = true;
            }
            return emitted;
        },
        else => return false,
    }
}

fn resolvedNode(type_info: type_info_mod.TypeInfo, node_id: ast_mod.NodeId, store: *const types.TypeStore) ?types.TypeId {
    const info = type_info.lookupNodeInfo(node_id) orelse return null;
    if (info.state != .resolved) return null;
    if (info.type_id == types.invalid_type or info.type_id == store.builtins.unknown) return null;
    return info.type_id;
}

fn symbolForDeclaration(bind: binder.BindResult, node_id: ast_mod.NodeId) ?binder.Symbol {
    for (bind.node_symbols) |mapping| if (mapping.node == node_id) return bind.symbols[mapping.symbol];
    for (bind.symbols) |symbol| if (symbol.declaration == node_id and symbol.namespace == .value) return symbol;
    return null;
}

fn functionType(bind: binder.BindResult, type_info: type_info_mod.TypeInfo, node_id: ast_mod.NodeId) ?types.TypeId {
    if (symbolForDeclaration(bind, node_id)) |symbol| return (type_info.lookupSymbol(symbol.id) orelse return null).effective();
    return (type_info.lookupNodeInfo(node_id) orelse return null).type_id;
}

fn unwrappedReturn(signature: types.FunctionSignature, store: *const types.TypeStore) types.TypeId {
    const ty = store.lookup(signature.return_type) orelse return signature.return_type;
    if (signature.flags.is_async and ty.kind == .promise) return ty.kind.promise.value_type;
    if (signature.flags.is_generator and ty.kind == .generator) return ty.kind.generator.return_type;
    return signature.return_type;
}

fn parameterForArgument(signature: types.FunctionSignature, index: usize) ?types.ParameterType {
    if (index < signature.parameters.len) return signature.parameters[index];
    if (signature.parameters.len == 0) return null;
    const last = signature.parameters[signature.parameters.len - 1];
    return if (last.rest) last else null;
}

fn restArgumentType(parameter: types.ParameterType, store: *const types.TypeStore) types.TypeId {
    if (!parameter.rest) return parameter.type_id;
    const ty = store.lookup(parameter.type_id) orelse return parameter.type_id;
    return switch (ty.kind) {
        .array => |array| array.element_type,
        else => parameter.type_id,
    };
}

fn issueRelated(tree: *const ast_mod.Ast, node_id: ast_mod.NodeId) tokens.Span {
    return switch (tree.node(node_id).data) {
        .UnaryExpression => |expression| tree.node(expression.argument).span,
        .BinaryExpression => |expression| tree.node(expression.left).span,
        .AssignmentExpression => |expression| tree.node(expression.left).span,
        .UpdateExpression => |expression| tree.node(expression.argument).span,
        .MemberExpression => |expression| tree.node(expression.object).span,
        .ElementAccessExpression => |expression| tree.node(expression.object).span,
        .SatisfiesExpression => |expression| tree.node(expression.expression).span,
        else => tree.node(node_id).span,
    };
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    label: []const u8,
    span: tokens.Span,
    related_span: tokens.Span,
    related_message: []const u8,
) !void {
    const related = try allocator.alloc(diagnostics.RelatedSpan, 1);
    related[0] = .{ .span = related_span, .message = related_message };
    try out.append(allocator, .{ .severity = .@"error", .code = code, .phase = .type_checker, .message = message, .span = span, .label = label, .related = related });
}

fn sortDiagnostics(items: []diagnostics.Diagnostic) void {
    if (items.len < 2) return;
    for (items[1..], 0..) |item, raw_index| {
        var index = raw_index + 1;
        while (index > 0) : (index -= 1) {
            const previous = items[index - 1];
            if (previous.span.start < item.span.start) break;
            if (previous.span.start == item.span.start and previous.span.end < item.span.end) break;
            if (previous.span.start == item.span.start and previous.span.end == item.span.end and @intFromEnum(previous.code) <= @intFromEnum(item.code)) break;
            items[index] = previous;
        }
        items[index] = item;
    }
}
