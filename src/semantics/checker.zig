const std = @import("std");

const ast_mod = @import("../frontend/ast.zig");
const frontend = @import("../frontend/frontend.zig");
const binder = @import("../frontend/binder.zig");
const function_like = @import("../frontend/function_like.zig");
const tokens = @import("../frontend/tokens.zig");
const diagnostics = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const type_compat = @import("type_compat.zig");
const type_info_mod = @import("type_info.zig");
const type_inference = @import("type_inference.zig");

fn isValidNode(tree: *const ast_mod.Ast, node_id: ast_mod.NodeId) bool {
    return node_id != ast_mod.invalid_node and @as(usize, node_id) < tree.nodes.len;
}

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
            .AssignmentExpression => |assignment| try checkAssignment(allocator, tree, type_info, store, node_id, assignment, &out),
            .CallExpression => |call| try checkCall(
                allocator,
                tree,
                type_info,
                store,
                node_id,
                call.callee,
                call.arguments,
                tree.node(call.callee).data == .SuperExpression,
                tree.node(call.callee).data == .SuperExpression,
                &out,
            ),
            .NewExpression => |call| try checkCall(allocator, tree, type_info, store, node_id, call.callee, call.arguments, true, false, &out),
            .FunctionDeclaration, .FunctionExpression, .ArrowFunctionExpression, .ClassMethod => try checkFunctionReturns(allocator, result, type_info, store, node_id, &out),
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
    const compatibility = type_compat.check(actual, expected, store);
    if (compatibility.isCompatible()) return;

    // When both sides are aggregates with a compatible shape (matching length
    // or matching keys), compare element-by-element and report per-position
    // mismatches. The generic diagnostic is preserved when shapes cannot be
    // meaningfully compared side-by-side so we do not silence real errors.
    const emitted = try checkAggregateElementMismatch(allocator, result.ast, type_info, store, result.ast.node(declaration_id).span, initializer, expected, actual, out);
    if (emitted) return;
    const message = try compatibilityMessage(allocator, compatibility);
    try appendDiagnostic(allocator, out, .type_mismatch, message, "incompatible initializer", result.ast.node(initializer).span, symbol.span, "declared type is here");
}

fn compatibilityMessage(allocator: std.mem.Allocator, result: type_compat.CompatibilityResult) ![]const u8 {
    const failure = switch (result) {
        .compatible => return "initializer is not assignable to the declared type",
        .incompatible => |value| value,
    };
    var path: std.ArrayList(u8) = .empty;
    for (failure.pathSlice()) |segment| switch (segment) {
        .property => |name| {
            if (path.items.len != 0) try path.append(allocator, '.');
            try path.appendSlice(allocator, name);
        },
        else => {},
    };
    if (path.items.len == 0) {
        path.deinit(allocator);
        return "initializer is not assignable to the declared type";
    }
    defer path.deinit(allocator);
    return std.fmt.allocPrint(allocator, "initializer property path '{s}' is not assignable to the declared type", .{path.items});
}

fn checkAssignment(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    assignment_id: ast_mod.NodeId,
    assignment: ast_mod.AssignmentExpression,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const expected = resolvedNode(type_info, assignment.left, store) orelse return;
    const actual_node = if (assignment.operator == .Equal) assignment.right else assignment_id;
    const actual = resolvedNode(type_info, actual_node, store) orelse return;
    if (type_compat.check(actual, expected, store).isCompatible()) return;
    const message = if (assignment.operator == .Equal)
        "assigned value is not assignable to the target type"
    else
        "compound assignment result is not assignable to the target type";
    try appendDiagnostic(allocator, out, .type_mismatch, message, "incompatible assignment", tree.node(actual_node).span, tree.node(assignment.left).span, "assignment target is here");
}

fn checkCall(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
    store: *types.TypeStore,
    call_id: ast_mod.NodeId,
    callee_id: ast_mod.NodeId,
    arguments: []const ast_mod.NodeId,
    construct: bool,
    super_call: bool,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const info = type_info.lookupNodeInfo(call_id) orelse return;
    if (info.issue == .invalid_constructor) {
        try appendDiagnostic(allocator, out, .type_mismatch, "expression is not constructable", "invalid constructor", tree.node(call_id).span, tree.node(callee_id).span, "constructor expression is here");
        return;
    }
    if (info.issue == .invalid_callee) {
        try appendDiagnostic(allocator, out, .type_mismatch, "expression is not callable", "invalid call target", tree.node(call_id).span, tree.node(callee_id).span, "callee is here");
        return;
    }
    if (info.issue != .invalid_argument_count and info.issue != .invalid_argument_type) return;
    const callee_type = resolvedNode(type_info, callee_id, store) orelse return;

    if (info.issue == .invalid_argument_count) {
        try appendDiagnostic(allocator, out, .invalid_argument_count, "argument count does not match the function signature", "invalid argument count", tree.node(call_id).span, tree.node(callee_id).span, "function signature is here");
        return;
    }

    const signature = callSignature(callee_type, construct, super_call, store) orelse return;
    for (arguments, 0..) |argument, index| {
        const actual = resolvedNode(type_info, argument, store) orelse continue;
        const parameter = parameterForArgument(signature, index) orelse continue;
        const expected = restArgumentType(parameter, store);
        if (type_compat.check(actual, expected, store).isCompatible()) continue;
        try appendDiagnostic(allocator, out, .invalid_argument_type, "argument is not assignable to the parameter type", "invalid argument type", tree.node(argument).span, tree.node(callee_id).span, "function signature is here");
        return;
    }
    try appendDiagnostic(allocator, out, .invalid_argument_type, "argument is not accepted by every callable union member", "invalid argument type", tree.node(call_id).span, tree.node(callee_id).span, "callable union is here");
}

fn callSignature(callee_type: types.TypeId, construct: bool, super_call: bool, store: *const types.TypeStore) ?types.FunctionSignature {
    if (!construct) {
        if (store.lookupFunction(callee_type)) |signature| return signature;
        const callee = store.lookup(callee_type) orelse return null;
        if (callee.kind != .union_type) return null;
        for (callee.kind.union_type) |member| if (store.lookupFunction(member)) |signature| return signature;
        return null;
    }
    const callee = store.lookup(callee_type) orelse return null;
    const identity = switch (callee.kind) {
        .class_constructor => |constructor| constructor.identity,
        .class => |instance| if (super_call) instance.identity else return null,
        else => return null,
    };
    const class = store.lookupClassSemanticType(identity) orelse return null;
    return store.lookupFunction(class.constructor_signature orelse return null);
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
        .none, .invalid_argument_count, .invalid_argument_type, .invalid_callee, .invalid_constructor => return,
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
    const function = function_like.describe(result.ast, function_id) orelse return;
    try checkFunctionLikeRules(allocator, &result.ast, function, out);
    // Recovery can retain the callable declaration while omitting its body.
    if (!isValidNode(&result.ast, function.body)) return;
    if (function.kind == .constructor or function.kind == .setter)
        try checkForbiddenReturnValues(allocator, &result.ast, function.body, function.kind, node.span, out);
    if (function.return_type == null) return;
    const function_type = functionType(result.bind, type_info, function_id) orelse return;
    const signature = store.lookupFunction(function_type) orelse return;
    const expected = unwrappedReturn(signature, store);
    if (function.expression_body) {
        const actual = resolvedNode(type_info, function.body, store) orelse return;
        if (!type_compat.check(actual, expected, store).isCompatible())
            try appendDiagnostic(allocator, out, .type_mismatch, "returned expression is not assignable to the declared return type", "incompatible return", result.ast.node(function.body).span, node.span, "function return type is declared here");
        return;
    }
    try checkReturnsIn(allocator, &result.ast, type_info, store, function.body, expected, node.span, out);
    if (try type_inference.hasReachableFallthrough(allocator, function_id, result.ast, result.cfgs) and
        !type_compat.check(store.builtins.undefined, expected, store).isCompatible())
    {
        try appendDiagnostic(allocator, out, .type_mismatch, "reachable function exit returns undefined", "incompatible fallthrough", result.ast.node(function.body).span, node.span, "function return type is declared here");
    }
}

fn checkFunctionLikeRules(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    function: function_like.Descriptor,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    const span = tree.node(function.node).span;
    if ((function.kind == .constructor or function.isAccessor()) and
        (function.flags.is_async or function.flags.is_generator))
    {
        try appendDiagnostic(allocator, out, .type_mismatch, "constructors and accessors cannot be async or generators", "invalid callable flags", span, span, "callable is declared here");
    }
    if (function.kind == .constructor and function.return_type != null)
        try appendDiagnostic(allocator, out, .type_mismatch, "constructors cannot declare a return type", "invalid constructor return type", function.return_type.?.span, span, "constructor is declared here");
    if (function.kind == .getter and function.params.len != 0)
        try appendDiagnostic(allocator, out, .type_mismatch, "getters cannot declare parameters", "invalid getter parameters", if (isValidNode(tree, function.params[0])) tree.node(function.params[0]).span else span, span, "getter is declared here");
    if (function.kind == .setter) {
        if (function.return_type != null)
            try appendDiagnostic(allocator, out, .type_mismatch, "setters cannot declare a return type", "invalid setter return type", function.return_type.?.span, span, "setter is declared here");
        var valid_parameter = function.params.len == 1 and isValidNode(tree, function.params[0]);
        if (valid_parameter) switch (tree.node(function.params[0]).data) {
            .Parameter => |parameter| valid_parameter = !parameter.optional and parameter.initializer == null and !parameter.rest,
            else => valid_parameter = false,
        };
        if (!valid_parameter)
            try appendDiagnostic(allocator, out, .type_mismatch, "setters require exactly one required non-rest parameter", "invalid setter parameter", if (function.params.len != 0 and isValidNode(tree, function.params[0])) tree.node(function.params[0]).span else span, span, "setter is declared here");
    }
}

fn checkForbiddenReturnValues(
    allocator: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    node_id: ast_mod.NodeId,
    kind: function_like.Kind,
    function_span: tokens.Span,
    out: *std.ArrayList(diagnostics.Diagnostic),
) !void {
    if (!isValidNode(tree, node_id)) return;
    const node = tree.node(node_id);
    switch (node.data) {
        .ReturnStatement => |statement| if (statement.argument) |argument| {
            if (!isValidNode(tree, argument)) return;
            const message = if (kind == .constructor) "constructors cannot return a value" else "setters cannot return a value";
            try appendDiagnostic(allocator, out, .type_mismatch, message, "invalid return value", tree.node(argument).span, function_span, "callable is declared here");
        },
        .Program => |program| for (program.statements) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out),
        .BlockStatement => |block| for (block.statements) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out),
        .IfStatement => |statement| {
            try checkForbiddenReturnValues(allocator, tree, statement.consequent, kind, function_span, out);
            if (statement.alternate) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out);
        },
        .WhileStatement => |statement| try checkForbiddenReturnValues(allocator, tree, statement.body, kind, function_span, out),
        .DoWhileStatement => |statement| try checkForbiddenReturnValues(allocator, tree, statement.body, kind, function_span, out),
        .ForStatement => |statement| try checkForbiddenReturnValues(allocator, tree, statement.body, kind, function_span, out),
        .SwitchStatement => |statement| for (statement.cases) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out),
        .SwitchCase => |case| for (case.consequent) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out),
        .TryStatement => |statement| {
            try checkForbiddenReturnValues(allocator, tree, statement.block, kind, function_span, out);
            if (statement.handler) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out);
            if (statement.finalizer) |child| try checkForbiddenReturnValues(allocator, tree, child, kind, function_span, out);
        },
        .CatchClause => |clause| try checkForbiddenReturnValues(allocator, tree, clause.body, kind, function_span, out),
        .FinallyClause => |clause| try checkForbiddenReturnValues(allocator, tree, clause.body, kind, function_span, out),
        .LabeledStatement => |statement| try checkForbiddenReturnValues(allocator, tree, statement.body, kind, function_span, out),
        .FunctionDeclaration, .FunctionExpression, .ArrowFunctionExpression, .ClassMethod, .ClassDeclaration, .ClassExpression => {},
        else => {},
    }
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
    if (!isValidNode(tree, node_id)) return;
    const node = tree.node(node_id);
    switch (node.data) {
        .ReturnStatement => |statement| {
            if (statement.argument) |argument| if (!isValidNode(tree, argument)) return;
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
        .FunctionDeclaration, .FunctionExpression, .ArrowFunctionExpression, .ClassMethod, .ClassDeclaration, .ClassExpression => {},
        else => {},
    }
}

/// When both expected and actual are aggregates with a matching shape (matching
/// length for arrays/tuples or matching keys for objects), walk side-by-side
/// and emit per-position element/type-mismatch diagnostics. Returns true if at
/// least one diagnostic was emitted; false when the shapes cannot be compared
/// positionally so the caller falls back to the generic "incompatible X" message.
fn arrayElementSpan(tree: ast_mod.Ast, initializer_id: ast_mod.NodeId, index: usize) tokens.Span {
    const initializer = tree.node(initializer_id);
    if (initializer.data == .ArrayExpression) {
        const array = initializer.data.ArrayExpression;
        if (index < array.elements.len) {
            if (array.elements[index]) |element_id| return tree.node(element_id).span;
        }
    }
    return initializer.span;
}

fn checkAggregateElementMismatch(
    allocator: std.mem.Allocator,
    tree: ast_mod.Ast,
    type_info: type_info_mod.TypeInfo,
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
            if (actual_ty.kind == .tuple) {
                // Both sides are tuples — compare per-position.
                const actual_tuple = actual_ty.kind.tuple;
                if (expected_tuple.elements.len != actual_tuple.elements.len) return false;
                var emitted: bool = false;
                for (expected_tuple.elements, 0..expected_tuple.elements.len) |expected_element, i| {
                    const act_elem = actual_tuple.elements[i];
                    if (act_elem.hole) continue;
                    if (type_compat.check(act_elem.type_id, expected_element.type_id, store).isCompatible()) continue;
                    const msg = try std.fmt.allocPrint(allocator, "tuple element at index {} is not assignable to the declared type", .{i});
                    const related = try std.fmt.allocPrint(allocator, "declared tuple element at index {} is here", .{i});
                    try appendDiagnostic(allocator, out, .type_mismatch, msg, "element type mismatch", arrayElementSpan(tree, initializer_id, i), expected_span, related);
                    emitted = true;
                }
                return emitted;
            } else if (actual_ty.kind == .array) {
                // Annotation declares tuple but inferArray produced an array shape.
                // Compare declared element types vs source-side inferred types per-position.
                const arr_type = actual_ty.kind.array;
                var emitted: bool = false;
                for (expected_tuple.elements, 0..) |decl_elem, i| {
                    const nd = tree.node(initializer_id);
                    if (nd.data != .ArrayExpression) continue;
                    const init_arr = nd.data.ArrayExpression;
                    if (i >= init_arr.elements.len) continue;
                    const elem_id = init_arr.elements[i] orelse continue;
                    var eff_act: ?types.TypeId = resolvedNode(type_info, elem_id, store);
                    if (eff_act == null or eff_act.? == types.invalid_type) eff_act = arr_type.element_type;
                    if (eff_act == null) continue;
                    if (type_compat.check(eff_act.?, decl_elem.type_id, store).isCompatible()) continue;
                    const msg = try std.fmt.allocPrint(allocator, "tuple element at index {} is not assignable to the declared type", .{i});
                    const related = try std.fmt.allocPrint(allocator, "declared tuple element at index {} is here", .{i});
                    try appendDiagnostic(allocator, out, .type_mismatch, msg, "element type mismatch", tree.node(elem_id).span, expected_span, related);
                    emitted = true;
                }
                return emitted;
            }
            return false;
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
                const actual_index = found orelse continue; // key missing in actual — keep generic diagnostic for now
                const act_prop = actual_props[actual_index];
                if (type_compat.check(act_prop.type_id, exp_prop.type_id, store).isCompatible()) continue;
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
    const effective = info.effective() orelse return null;
    if (effective == store.builtins.unknown) return null;
    return effective;
}

fn symbolForDeclaration(bind: binder.BindResult, node_id: ast_mod.NodeId) ?binder.Symbol {
    for (bind.node_symbols) |mapping| if (mapping.node == node_id) return bind.symbols[mapping.symbol];
    for (bind.symbols) |symbol| if (symbol.declaration == node_id and symbol.namespace == .value) return symbol;
    return null;
}

fn functionType(bind: binder.BindResult, type_info: type_info_mod.TypeInfo, node_id: ast_mod.NodeId) ?types.TypeId {
    if (symbolForDeclaration(bind, node_id)) |symbol| return (type_info.lookupSymbol(symbol.id) orelse return null).effective();
    return (type_info.lookupNodeInfo(node_id) orelse return null).effective();
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
