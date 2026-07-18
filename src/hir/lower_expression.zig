//! Source-order expression lowering into block-aware ANF.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const tokens = @import("../frontend/tokens.zig");

const SuspensionKind = enum { await_, yield_ };

fn requireSuspensionContext(kind: SuspensionKind, allows_await: bool, allows_yield: bool) error{ AwaitOutsideAsyncContext, YieldOutsideGeneratorContext }!void {
    switch (kind) {
        .await_ => if (!allows_await) return error.AwaitOutsideAsyncContext,
        .yield_ => if (!allows_yield) return error.YieldOutsideGeneratorContext,
    }
}

pub fn lower(context: anytype, node_id: ast.NodeId) anyerror!ids.ValueId {
    const node = context.local.frontend.ast.node(node_id);
    return switch (node.data) {
        .Literal => |literal| context.emitValue(try context.lowerLiteral(literal.value), context.nodeType(node_id)),
        .RegExpLiteral => |regexp| lowerRegExp(context, node_id, regexp),
        .ObjectExpression => |object| lowerObject(context, node_id, object),
        .ArrayExpression => |array| lowerArray(context, node_id, array),
        .TemplateExpression => |template| lowerTemplate(context, node_id, template),
        .TaggedTemplateExpression => |tagged| lowerTaggedTemplate(context, node_id, tagged),
        .Identifier => context.lowerIdentifier(node_id),
        .FunctionExpression => context.lowerFunctionExpression(node_id, .ordinary),
        .ArrowFunctionExpression => context.lowerFunctionExpression(node_id, .ordinary),
        .ClassExpression => context.lowerClassExpression(node_id),
        .AsExpression => |expression| blk: {
            context.eraseTypeNode(expression.type_annotation.root);
            break :blk lower(context, expression.expression);
        },
        .SatisfiesExpression => |expression| blk: {
            context.eraseTypeNode(expression.type_annotation.root);
            break :blk lower(context, expression.expression);
        },
        .NonNullExpression => |expression| lower(context, expression.expression),
        .CallExpression => |call| lowerCall(context, node_id, call),
        .NewExpression => |expression| lowerNew(context, node_id, expression),
        .MemberExpression => |member| lowerMember(context, node_id, member),
        .ElementAccessExpression => |element| lowerElement(context, node_id, element),
        .ThisExpression => context.lowerThis(node_id),
        .SuperExpression => context.lowerSuper(node_id),
        .MetaProperty => |meta| lowerMeta(context, node_id, meta),
        .ImportExpression => |expression| lowerImport(context, node_id, expression),
        .AssignmentExpression => |expression| context.lowerAssignment(node_id, expression),
        .UpdateExpression => |expression| context.lowerUpdate(node_id, expression),
        .UnaryExpression => |expression| lowerUnary(context, node_id, expression),
        .YieldExpression => |expression| lowerYield(context, node_id, expression),
        .BinaryExpression => |expression| lowerBinary(context, node_id, expression),
        .SequenceExpression => |sequence| lowerSequence(context, sequence),
        .ConditionalExpression => |conditional| lowerConditional(context, node_id, conditional),
        else => error.UnsupportedHirExpression,
    };
}

fn lowerCall(context: anytype, node_id: ast.NodeId, call: ast.CallExpression) anyerror!ids.ValueId {
    const callee_node = context.local.frontend.ast.node(call.callee);
    if (callee_node.data == .MemberExpression and callee_node.data.MemberExpression.optional)
        return lowerOptionalMemberCall(context, node_id, callee_node.data.MemberExpression, call.arguments);
    if (callee_node.data == .ElementAccessExpression and callee_node.data.ElementAccessExpression.optional)
        return lowerOptionalElementCall(context, node_id, callee_node.data.ElementAccessExpression, call.arguments);
    if (call.optional) return lowerOptionalCall(context, node_id, call);
    if (callee_node.data == .MemberExpression)
        return lowerMethodCall(context, node_id, callee_node.data.MemberExpression, call.arguments);
    if (callee_node.data == .ElementAccessExpression)
        return lowerElementMethodCall(context, node_id, callee_node.data.ElementAccessExpression, call.arguments);
    if (callee_node.data == .SuperExpression) {
        context.noteSuperUse();
        const arguments = try lowerArguments(context, call.arguments);
        const result = try context.emitValue(.{ .call_super_constructor = arguments }, context.nodeType(node_id));
        try context.afterSuperConstructor();
        return result;
    }
    const callee = try lower(context, call.callee);
    const arguments = try lowerArguments(context, call.arguments);
    return context.emitValue(.{ .call = .{ .callee = callee, .arguments = arguments } }, context.nodeType(node_id));
}

fn lowerMethodCall(context: anytype, node_id: ast.NodeId, member: ast.MemberExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const key: model.PropertyKey = .{ .static = try context.builder.copyString(member.property) };
    if (context.local.frontend.ast.node(member.object).data == .SuperExpression) {
        const receiver = try context.lowerSuper(member.object);
        const args = try lowerArguments(context, arguments);
        return context.emitValue(.{ .call_super_method = .{ .receiver = receiver, .key = key, .arguments = args } }, context.nodeType(node_id));
    }
    const receiver = try lower(context, member.object);
    const args = try lowerArguments(context, arguments);
    return context.emitValue(.{ .call_method = .{ .receiver = receiver, .key = key, .arguments = args } }, context.nodeType(node_id));
}

fn lowerElementMethodCall(context: anytype, node_id: ast.NodeId, element: ast.ElementAccessExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    if (context.local.frontend.ast.node(element.object).data == .SuperExpression) {
        const receiver = try context.lowerSuper(element.object);
        const key = try lower(context, element.index);
        const args = try lowerArguments(context, arguments);
        return context.emitValue(.{ .call_super_method = .{ .receiver = receiver, .key = .{ .computed = key }, .arguments = args } }, context.nodeType(node_id));
    }
    const receiver = try lower(context, element.object);
    const key = try lower(context, element.index);
    const args = try lowerArguments(context, arguments);
    return context.emitValue(.{ .call_method = .{ .receiver = receiver, .key = .{ .computed = key }, .arguments = args } }, context.nodeType(node_id));
}

fn lowerNew(context: anytype, node_id: ast.NodeId, expression: ast.NewExpression) anyerror!ids.ValueId {
    const callee = try lower(context, expression.callee);
    const arguments = try lowerArguments(context, expression.arguments);
    return context.emitValue(.{ .construct = .{ .callee = callee, .arguments = arguments } }, context.nodeType(node_id));
}

fn lowerMeta(context: anytype, node_id: ast.NodeId, meta: ast.MetaProperty) anyerror!ids.ValueId {
    const kind: model.MetaKind = switch (meta.kind) {
        .import_meta => .import_meta,
        .new_target => .new_target,
    };
    return context.lowerMeta(node_id, kind);
}

fn lowerImport(context: anytype, node_id: ast.NodeId, expression: ast.ImportExpression) anyerror!ids.ValueId {
    const source = try lower(context, expression.source);
    const options = if (expression.options) |options| try lower(context, options) else null;
    const attributes = if (expression.attributes) |attributes|
        try lowerImportAttributes(context, attributes)
    else
        &.{};
    return context.emitValue(.{ .dynamic_import = .{ .source = source, .options = options, .attributes = attributes } }, context.nodeType(node_id));
}

fn lowerImportAttributes(context: anytype, attributes: ast.ImportAttributes) anyerror![]const model.DynamicImportAttribute {
    const lowered = try context.builder.allocator.alloc(model.DynamicImportAttribute, attributes.entries.len);
    for (attributes.entries, 0..) |attribute, index| {
        const value_node = context.local.frontend.ast.node(attribute.value);
        if (value_node.data != .Literal) return error.InvalidDynamicImportAttribute;
        const value_operation = try context.lowerLiteral(value_node.data.Literal.value);
        const value = switch (value_operation) {
            .constant => |constant| switch (constant) {
                .string => |string| string,
                else => return error.InvalidDynamicImportAttribute,
            },
            else => return error.InvalidDynamicImportAttribute,
        };
        lowered[index] = .{ .key = try context.builder.copyString(attribute.key), .value = value };
    }
    return lowered;
}

fn lowerMember(context: anytype, node_id: ast.NodeId, member: ast.MemberExpression) anyerror!ids.ValueId {
    if (member.optional) return lowerOptionalMember(context, node_id, member);
    if (try context.sourceHostMemberBinding(node_id)) |binding|
        return context.emitValue(.{ .load_binding = binding }, context.nodeType(node_id));
    const place = try context.lowerPlace(node_id);
    return context.emitValue(.{ .load_place = place }, context.nodeType(node_id));
}

fn lowerElement(context: anytype, node_id: ast.NodeId, element: ast.ElementAccessExpression) anyerror!ids.ValueId {
    if (element.optional) return lowerOptionalElement(context, node_id, element);
    const place = try context.lowerPlace(node_id);
    return context.emitValue(.{ .load_place = place }, context.nodeType(node_id));
}

fn lowerUnary(context: anytype, node_id: ast.NodeId, expression: ast.UnaryExpression) anyerror!ids.ValueId {
    if (expression.operator == .Keyword_delete) return context.lowerDelete(node_id, expression.argument);
    if (expression.operator == .Keyword_await) {
        try requireSuspensionContext(.await_, context.allowsAwait(), context.allowsYield());
        const operand = try lower(context, expression.argument);
        return context.emitSuspension(.{ .await_ = operand }, context.nodeType(node_id));
    }
    const operand = try lower(context, expression.argument);
    return switch (expression.operator) {
        .Exclamation => blk: {
            const boolean = try context.emitValue(.{ .to_boolean = operand }, context.booleanType());
            break :blk context.emitValue(.{ .unary = .{ .operator = .logical_not, .operand = boolean, .mode = .dynamic } }, context.nodeType(node_id));
        },
        .Plus => context.emitValue(.{ .unary = .{ .operator = .plus, .operand = operand, .mode = numericMode(context, expression.argument) } }, context.nodeType(node_id)),
        .Minus => context.emitValue(.{ .unary = .{ .operator = .negate, .operand = operand, .mode = numericMode(context, expression.argument) } }, context.nodeType(node_id)),
        .Tilde => context.emitValue(.{ .unary = .{ .operator = .bit_not, .operand = operand, .mode = numericMode(context, expression.argument) } }, context.nodeType(node_id)),
        .Keyword_typeof => context.emitValue(.{ .typeof_value = operand }, context.nodeType(node_id)),
        .Keyword_void => context.emitValue(.{ .void_value = operand }, context.nodeType(node_id)),
        else => error.UnsupportedHirExpression,
    };
}

fn lowerYield(context: anytype, node_id: ast.NodeId, expression: ast.YieldExpression) anyerror!ids.ValueId {
    try requireSuspensionContext(.yield_, context.allowsAwait(), context.allowsYield());
    const operand = if (expression.argument) |argument|
        try lower(context, argument)
    else
        try context.emitValue(.{ .constant = .undefined }, context.builder.result.semanticResult().type_store.builtins.undefined);
    return context.emitSuspension(
        if (expression.delegate) .{ .yield_delegate = operand } else .{ .yield_ = operand },
        context.nodeType(node_id),
    );
}

test "suspension context rejects await and yield outside eligible functions" {
    try std.testing.expectError(error.AwaitOutsideAsyncContext, requireSuspensionContext(.await_, false, false));
    try std.testing.expectError(error.YieldOutsideGeneratorContext, requireSuspensionContext(.yield_, false, false));
    try requireSuspensionContext(.await_, true, false);
    try requireSuspensionContext(.yield_, false, true);
    try requireSuspensionContext(.await_, true, true);
    try requireSuspensionContext(.yield_, true, true);
}

fn lowerBinary(context: anytype, node_id: ast.NodeId, expression: ast.BinaryExpression) anyerror!ids.ValueId {
    if (isLogical(expression.operator)) return lowerLogical(context, node_id, expression);
    const left = try lower(context, expression.left);
    const right = try lower(context, expression.right);
    if (expression.operator == .Plus) {
        const type_id = context.nodeType(node_id);
        const builtins = context.builder.result.semanticResult().type_store.builtins;
        const mode: model.AddMode = if (type_id == builtins.string) .string_concat else if (type_id == builtins.number or type_id == builtins.bigint) .numeric else .dynamic;
        return context.emitValue(.{ .add = .{ .left = left, .right = right, .mode = mode } }, type_id);
    }
    const operator: model.BinaryOperator = switch (expression.operator) {
        .Minus => .subtract,
        .Asterisk => .multiply,
        .Slash => .divide,
        .Percent => .remainder,
        .AsteriskAsterisk => .exponentiate,
        .Ampersand => .bit_and,
        .Bar => .bit_or,
        .Caret => .bit_xor,
        .LessThanLessThan => .shift_left,
        .GreaterThanGreaterThan => .shift_right,
        .GreaterThanGreaterThanGreaterThan => .shift_right_unsigned,
        .LessThan => .less,
        .LessThanEquals => .less_equal,
        .GreaterThan => .greater,
        .GreaterThanEquals => .greater_equal,
        .EqualsEquals => .equal_loose,
        .EqualsEqualsEquals => .equal_strict,
        .ExclamationEquals => .not_equal_loose,
        .ExclamationEqualsEquals => .not_equal_strict,
        .Keyword_in => .in,
        .Keyword_instanceof => .instanceof,
        else => return error.UnsupportedHirExpression,
    };
    return context.emitValue(.{ .binary = .{ .operator = operator, .left = left, .right = right, .mode = binaryMode(context, expression) } }, context.nodeType(node_id));
}

fn lowerLogical(context: anytype, node_id: ast.NodeId, expression: ast.BinaryExpression) anyerror!ids.ValueId {
    const left = try lower(context, expression.left);
    const condition = if (expression.operator == .QuestionQuestion)
        try context.emitValue(.{ .is_nullish = left }, context.booleanType())
    else
        try context.emitValue(.{ .to_boolean = left }, context.booleanType());
    const select_right = expression.operator != .BarBar;
    const right_block = try context.anf.createBlock();
    const left_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try context.anf.terminate(.{ .branch = .{
        .condition = condition,
        .true_target = if (select_right) right_block else left_block,
        .false_target = if (select_right) left_block else right_block,
    } });
    try context.anf.beginBlock(right_block);
    const right = try lower(context, expression.right);
    try jumpWithValue(context, merge_block, try context.emitValue(.{ .copy = right }, context.nodeType(node_id)));
    try context.anf.beginBlock(left_block);
    try jumpWithValue(context, merge_block, try context.emitValue(.{ .copy = left }, context.nodeType(node_id)));
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn lowerOptionalMember(context: anytype, node_id: ast.NodeId, member: ast.MemberExpression) anyerror!ids.ValueId {
    const base = try lower(context, member.object);
    return optionalValue(context, node_id, base, .{ .static = try context.builder.copyString(member.property) });
}

fn lowerOptionalElement(context: anytype, node_id: ast.NodeId, element: ast.ElementAccessExpression) anyerror!ids.ValueId {
    const base = try lower(context, element.object);
    const null_block = try context.anf.createBlock();
    const access_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try branchNullish(context, base, null_block, access_block);
    try context.anf.beginBlock(access_block);
    const key = try lower(context, element.index);
    const place = try context.emitPlace(.{ .element = .{ .base = base, .key = key } });
    const value = try context.emitValue(.{ .load_place = place }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, value);
    try emitUndefinedArm(context, node_id, null_block, merge_block);
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn optionalValue(context: anytype, node_id: ast.NodeId, base: ids.ValueId, key: model.PropertyKey) anyerror!ids.ValueId {
    const null_block = try context.anf.createBlock();
    const access_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try branchNullish(context, base, null_block, access_block);
    try context.anf.beginBlock(access_block);
    const place = try context.emitPlace(.{ .property = .{ .base = base, .key = key } });
    const value = try context.emitValue(.{ .load_place = place }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, value);
    try emitUndefinedArm(context, node_id, null_block, merge_block);
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn lowerOptionalCall(context: anytype, node_id: ast.NodeId, call: ast.CallExpression) anyerror!ids.ValueId {
    const callee_node = context.local.frontend.ast.node(call.callee);
    if (callee_node.data == .MemberExpression) return lowerOptionalMethodCall(context, node_id, callee_node.data.MemberExpression, call.arguments);
    if (callee_node.data == .ElementAccessExpression) return lowerOptionalElementMethodCall(context, node_id, callee_node.data.ElementAccessExpression, call.arguments);
    const callee = try lower(context, call.callee);
    return optionalCallValue(context, node_id, callee, null, call.arguments);
}

fn lowerOptionalMemberCall(context: anytype, node_id: ast.NodeId, member: ast.MemberExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const receiver = try lower(context, member.object);
    return optionalCallValue(context, node_id, receiver, .{ .static = try context.builder.copyString(member.property) }, arguments);
}

fn lowerOptionalElementCall(context: anytype, node_id: ast.NodeId, element: ast.ElementAccessExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const receiver = try lower(context, element.object);
    const null_block = try context.anf.createBlock();
    const call_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try branchNullish(context, receiver, null_block, call_block);
    try context.anf.beginBlock(call_block);
    const key = try lower(context, element.index);
    const args = try lowerArguments(context, arguments);
    const value = try context.emitValue(.{ .call_method = .{ .receiver = receiver, .key = .{ .computed = key }, .arguments = args } }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, value);
    try emitUndefinedArm(context, node_id, null_block, merge_block);
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn lowerOptionalMethodCall(context: anytype, node_id: ast.NodeId, member: ast.MemberExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const receiver = try lower(context, member.object);
    const key: model.PropertyKey = .{ .static = try context.builder.copyString(member.property) };
    const place = try context.emitPlace(.{ .property = .{ .base = receiver, .key = key } });
    const callee = try context.emitValue(.{ .load_place = place }, context.nodeType(member.object));
    return optionalMethodValue(context, node_id, callee, receiver, key, arguments);
}

fn lowerOptionalElementMethodCall(context: anytype, node_id: ast.NodeId, element: ast.ElementAccessExpression, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const receiver = try lower(context, element.object);
    const key_value = try lower(context, element.index);
    const place = try context.emitPlace(.{ .element = .{ .base = receiver, .key = key_value } });
    const callee = try context.emitValue(.{ .load_place = place }, context.nodeType(element.object));
    return optionalMethodValue(context, node_id, callee, receiver, .{ .computed = key_value }, arguments);
}

fn optionalMethodValue(context: anytype, node_id: ast.NodeId, callee: ids.ValueId, receiver: ids.ValueId, key: model.PropertyKey, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const null_block = try context.anf.createBlock();
    const call_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try branchNullish(context, callee, null_block, call_block);
    try context.anf.beginBlock(call_block);
    const args = try lowerArguments(context, arguments);
    const value = try context.emitValue(.{ .call_method = .{ .callee = callee, .receiver = receiver, .key = key, .arguments = args } }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, value);
    try emitUndefinedArm(context, node_id, null_block, merge_block);
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn optionalCallValue(context: anytype, node_id: ast.NodeId, callee_or_receiver: ids.ValueId, key: ?model.PropertyKey, arguments: []const ast.NodeId) anyerror!ids.ValueId {
    const null_block = try context.anf.createBlock();
    const call_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try branchNullish(context, callee_or_receiver, null_block, call_block);
    try context.anf.beginBlock(call_block);
    const args = try lowerArguments(context, arguments);
    const value = if (key) |method_key|
        try context.emitValue(.{ .call_method = .{ .receiver = callee_or_receiver, .key = method_key, .arguments = args } }, context.nodeType(node_id))
    else
        try context.emitValue(.{ .call = .{ .callee = callee_or_receiver, .arguments = args } }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, value);
    try emitUndefinedArm(context, node_id, null_block, merge_block);
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn branchNullish(context: anytype, value: ids.ValueId, null_block: ids.BlockId, value_block: ids.BlockId) anyerror!void {
    const condition = try context.emitValue(.{ .is_nullish = value }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = condition, .true_target = null_block, .false_target = value_block } });
}

fn emitUndefinedArm(context: anytype, node_id: ast.NodeId, null_block: ids.BlockId, merge_block: ids.BlockId) anyerror!void {
    try context.anf.beginBlock(null_block);
    const undefined_value = try context.emitValue(.{ .constant = .undefined }, context.builder.result.semanticResult().type_store.builtins.undefined);
    const result = try context.emitValue(.{ .copy = undefined_value }, context.nodeType(node_id));
    try jumpWithValue(context, merge_block, result);
}

fn lowerArguments(context: anytype, arguments: []const ast.NodeId) anyerror![]const model.CallArgument {
    const values = try context.builder.allocator.alloc(model.CallArgument, arguments.len);
    for (arguments, 0..) |argument, index| {
        const node = context.local.frontend.ast.node(argument);
        values[index] = if (node.data == .SpreadElement)
            .{ .spread = try lower(context, node.data.SpreadElement.argument) }
        else
            .{ .value = try lower(context, argument) };
    }
    return values;
}

fn lowerRegExp(context: anytype, node_id: ast.NodeId, regexp: ast.RegExpLiteral) anyerror!ids.ValueId {
    var flags: [8]u8 = undefined;
    var length: usize = 0;
    const ordered = [_]struct { enabled: bool, spelling: u8 }{
        .{ .enabled = regexp.flags.has_indices, .spelling = 'd' },
        .{ .enabled = regexp.flags.global, .spelling = 'g' },
        .{ .enabled = regexp.flags.ignore_case, .spelling = 'i' },
        .{ .enabled = regexp.flags.multiline, .spelling = 'm' },
        .{ .enabled = regexp.flags.dot_all, .spelling = 's' },
        .{ .enabled = regexp.flags.unicode, .spelling = 'u' },
        .{ .enabled = regexp.flags.unicode_sets, .spelling = 'v' },
        .{ .enabled = regexp.flags.sticky, .spelling = 'y' },
    };
    for (ordered) |flag| if (flag.enabled) {
        flags[length] = flag.spelling;
        length += 1;
    };
    return context.emitValue(.{ .create_regexp = .{
        .pattern = try context.builder.copyString(regexp.pattern),
        .flags = try context.builder.copyString(flags[0..length]),
        .source_site = try context.sourceSite(),
    } }, context.nodeType(node_id));
}

fn lowerObject(context: anytype, node_id: ast.NodeId, expression: ast.ObjectExpression) anyerror!ids.ValueId {
    const object = try context.emitValue(.create_object, context.nodeType(node_id));
    for (expression.properties) |property| switch (property.kind) {
        .spread => {
            const spread = context.local.frontend.ast.node(property.value).data.SpreadElement;
            const source = try lower(context, spread.argument);
            try context.emitVoid(.{ .copy_object_properties = .{ .target = object, .source = source } });
        },
        .key_value, .shorthand => {
            const value = try lower(context, property.value);
            try context.emitVoid(.{ .define_property = .{
                .object = object,
                .key = .{ .static = try context.builder.copyString(property.key) },
                .value = value,
            } });
        },
        .computed => {
            const key = try lower(context, property.computed_key orelse return error.MissingComputedPropertyKey);
            const value = try lower(context, property.value);
            try context.emitVoid(.{ .define_property = .{ .object = object, .key = .{ .computed = key }, .value = value } });
        },
        .method, .async_method, .getter, .setter => {
            const kind: model.HirFunctionKind = switch (property.kind) {
                .getter => .getter,
                .setter => .setter,
                else => .method,
            };
            const function = try context.createMethodShell(property.value, kind);
            try context.emitVoid(.{ .define_method = .{
                .object = object,
                .key = .{ .static = try context.builder.copyString(property.key) },
                .function = function,
                .kind = kind,
                .is_static = false,
            } });
        },
    };
    return object;
}

fn lowerArray(context: anytype, node_id: ast.NodeId, expression: ast.ArrayExpression) anyerror!ids.ValueId {
    const array = try context.emitValue(.create_array, context.nodeType(node_id));
    for (expression.elements) |maybe_element| {
        const element = maybe_element orelse {
            try context.emitVoid(.{ .array_append_hole = array });
            continue;
        };
        const node = context.local.frontend.ast.node(element);
        if (node.data == .SpreadElement) {
            const iterable = try lower(context, node.data.SpreadElement.argument);
            try context.emitVoid(.{ .array_append_iterable = .{ .array = array, .iterable = iterable } });
        } else {
            const value = try lower(context, element);
            try context.emitVoid(.{ .array_append = .{ .array = array, .value = value } });
        }
    }
    return array;
}

fn lowerTemplate(context: anytype, node_id: ast.NodeId, template: ast.TemplateExpression) anyerror!ids.ValueId {
    var parts: std.ArrayList(model.TemplatePart) = .empty;
    defer parts.deinit(context.builder.allocator);
    for (template.parts) |part| {
        try parts.append(context.builder.allocator, .{ .text = try context.lowerTemplateText(part.raw, part.cooked) });
        if (part.expression) |expression| {
            const value = try lower(context, expression);
            try parts.append(context.builder.allocator, .{ .value = try context.emitValue(.{ .to_string = value }, context.builder.result.semanticResult().type_store.builtins.string) });
        }
    }
    return context.emitValue(.{ .build_string = try parts.toOwnedSlice(context.builder.allocator) }, context.nodeType(node_id));
}

fn lowerTaggedTemplate(context: anytype, node_id: ast.NodeId, tagged: ast.TaggedTemplateExpression) anyerror!ids.ValueId {
    const template = context.local.frontend.ast.node(tagged.template).data.TemplateExpression;
    var receiver: ?ids.ValueId = null;
    const tag_node = context.local.frontend.ast.node(tagged.tag);
    const tag = switch (tag_node.data) {
        .MemberExpression => |member| blk: {
            const base = try lower(context, member.object);
            receiver = base;
            const place = try context.emitPlace(.{ .property = .{ .base = base, .key = .{ .static = try context.builder.copyString(member.property) } } });
            break :blk try context.emitValue(.{ .load_place = place }, context.nodeType(tagged.tag));
        },
        .ElementAccessExpression => |element| blk: {
            const base = try lower(context, element.object);
            receiver = base;
            const key = try lower(context, element.index);
            const place = try context.emitPlace(.{ .element = .{ .base = base, .key = key } });
            break :blk try context.emitValue(.{ .load_place = place }, context.nodeType(tagged.tag));
        },
        else => try lower(context, tagged.tag),
    };
    const raw = try context.builder.allocator.alloc([]const u8, template.parts.len);
    const cooked = try context.builder.allocator.alloc(?[]const u8, template.parts.len);
    for (template.parts, 0..) |part, index| {
        raw[index] = try context.builder.copyString(part.raw);
        cooked[index] = try context.lowerTemplateText(part.raw, part.cooked);
    }
    const site = try context.emitValue(.{ .create_template_site = .{
        .source_site = try context.sourceSite(),
        .cooked = cooked,
        .raw = raw,
    } }, context.nodeType(tagged.template));
    var substitutions: std.ArrayList(ids.ValueId) = .empty;
    defer substitutions.deinit(context.builder.allocator);
    for (template.parts) |part| {
        if (part.expression) |expression| try substitutions.append(context.builder.allocator, try lower(context, expression));
    }
    return context.emitValue(.{ .tagged_template_call = .{
        .tag = tag,
        .receiver = receiver,
        .template_site = site,
        .substitutions = try substitutions.toOwnedSlice(context.builder.allocator),
    } }, context.nodeType(node_id));
}

fn jumpWithValue(context: anytype, target: ids.BlockId, value: ids.ValueId) anyerror!void {
    try context.anf.terminate(.{ .jump = .{ .target = target, .arguments = try oneValue(context, value) } });
}

fn numericMode(context: anytype, node_id: ast.NodeId) model.NumericMode {
    const type_id = context.nodeType(node_id);
    const builtins = context.builder.result.semanticResult().type_store.builtins;
    return if (type_id == builtins.number) .number else if (type_id == builtins.bigint) .bigint else .dynamic;
}

fn binaryMode(context: anytype, expression: ast.BinaryExpression) model.NumericMode {
    const left = numericMode(context, expression.left);
    const right = numericMode(context, expression.right);
    return if (left == right) left else .dynamic;
}

fn isLogical(operator: tokens.TokenType) bool {
    return operator == .AmpersandAmpersand or operator == .BarBar or operator == .QuestionQuestion;
}

fn lowerSequence(context: anytype, sequence: ast.SequenceExpression) anyerror!ids.ValueId {
    if (sequence.expressions.len == 0) return error.EmptySequenceExpression;
    var result = try lower(context, sequence.expressions[0]);
    for (sequence.expressions[1..]) |expression| result = try lower(context, expression);
    return result;
}

fn lowerConditional(context: anytype, node_id: ast.NodeId, conditional: ast.ConditionalExpression) anyerror!ids.ValueId {
    const condition = try lower(context, conditional.condition);
    const boolean = try context.emitValue(.{ .to_boolean = condition }, context.booleanType());
    const consequent_block = try context.anf.createBlock();
    const alternate_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try context.anf.terminate(.{ .branch = .{
        .condition = boolean,
        .true_target = consequent_block,
        .false_target = alternate_block,
    } });

    try context.anf.beginBlock(consequent_block);
    const consequent = try lower(context, conditional.consequent);
    const consequent_result = try context.emitValue(.{ .copy = consequent }, context.nodeType(node_id));
    try context.anf.terminate(.{ .jump = .{ .target = merge_block, .arguments = try oneValue(context, consequent_result) } });

    try context.anf.beginBlock(alternate_block);
    const alternate = try lower(context, conditional.alternate);
    const alternate_result = try context.emitValue(.{ .copy = alternate }, context.nodeType(node_id));
    try context.anf.terminate(.{ .jump = .{ .target = merge_block, .arguments = try oneValue(context, alternate_result) } });

    try context.anf.beginBlock(merge_block);
    return merged;
}

fn oneValue(context: anytype, value: ids.ValueId) anyerror![]const ids.ValueId {
    const values = try context.builder.allocator.alloc(ids.ValueId, 1);
    values[0] = value;
    return values;
}
