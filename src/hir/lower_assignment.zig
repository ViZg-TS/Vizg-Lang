//! Assignment, update, and delete lowering through semantic places.

const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const tokens = @import("../frontend/tokens.zig");

pub fn lowerAssignment(context: anytype, node_id: ast.NodeId, expression: ast.AssignmentExpression) anyerror!ids.ValueId {
    const place = try context.lowerPlace(expression.left);
    if (expression.operator == .Equal) {
        const value = try context.lowerExpression(expression.right);
        try context.emitVoid(.{ .store_place = .{ .place = place, .value = value } });
        return value;
    }

    const old = try context.emitValue(.{ .load_place = place }, context.nodeType(expression.left));
    if (isLogicalAssignment(expression.operator)) return lowerLogicalAssignment(context, node_id, expression, place, old);
    const right = try context.lowerExpression(expression.right);
    const result = try emitCompound(context, node_id, expression.operator, old, right);
    try context.emitVoid(.{ .store_place = .{ .place = place, .value = result } });
    return result;
}

fn lowerLogicalAssignment(context: anytype, node_id: ast.NodeId, expression: ast.AssignmentExpression, place: ids.PlaceId, old: ids.ValueId) anyerror!ids.ValueId {
    const condition = if (expression.operator == .QuestionQuestionEqual)
        try context.emitValue(.{ .is_nullish = old }, context.booleanType())
    else
        try context.emitValue(.{ .to_boolean = old }, context.booleanType());
    const select_right = expression.operator != .BarBarEqual;
    const store_block = try context.anf.createBlock();
    const old_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const merged = try context.anf.addParameter(merge_block, context.nodeType(node_id));
    try context.anf.terminate(.{ .branch = .{
        .condition = condition,
        .true_target = if (select_right) store_block else old_block,
        .false_target = if (select_right) old_block else store_block,
    } });

    try context.anf.beginBlock(store_block);
    const right = try context.lowerExpression(expression.right);
    try context.emitVoid(.{ .store_place = .{ .place = place, .value = right } });
    const stored = try context.emitValue(.{ .copy = right }, context.nodeType(node_id));
    try context.anf.terminate(.{ .jump = .{ .target = merge_block, .arguments = try oneValue(context, stored) } });

    try context.anf.beginBlock(old_block);
    const retained = try context.emitValue(.{ .copy = old }, context.nodeType(node_id));
    try context.anf.terminate(.{ .jump = .{ .target = merge_block, .arguments = try oneValue(context, retained) } });
    try context.anf.beginBlock(merge_block);
    return merged;
}

fn oneValue(context: anytype, value: ids.ValueId) anyerror![]const ids.ValueId {
    const values = try context.builder.allocator.alloc(ids.ValueId, 1);
    values[0] = value;
    return values;
}

pub fn lowerUpdate(context: anytype, node_id: ast.NodeId, expression: ast.UpdateExpression) anyerror!ids.ValueId {
    const place = try context.lowerPlace(expression.argument);
    const type_id = context.nodeType(expression.argument);
    const old = try context.emitValue(.{ .load_place = place }, type_id);
    const builtins = context.builder.result.semanticResult().type_store.builtins;
    const mode: model.NumericMode = if (type_id == builtins.number) .number else if (type_id == builtins.bigint) .bigint else .dynamic;
    const one = if (mode == .bigint)
        try context.emitValue(.{ .constant = .{ .bigint = try context.builder.copyString("1") } }, builtins.bigint)
    else
        try context.emitValue(.{ .constant = .{ .number = 1 } }, builtins.number);
    const operator: model.BinaryOperator = switch (expression.operator) {
        .PlusPlus => .add,
        .MinusMinus => .subtract,
        else => return error.UnsupportedHirExpression,
    };
    const updated = if (operator == .add)
        try context.emitValue(.{ .add = .{ .left = old, .right = one, .mode = if (mode == .dynamic) .dynamic else .numeric } }, context.nodeType(node_id))
    else
        try context.emitValue(.{ .binary = .{ .operator = operator, .left = old, .right = one, .mode = mode } }, context.nodeType(node_id));
    try context.emitVoid(.{ .store_place = .{ .place = place, .value = updated } });
    return if (expression.prefix) updated else old;
}

pub fn lowerDelete(context: anytype, node_id: ast.NodeId, argument: ast.NodeId) anyerror!ids.ValueId {
    const place = try context.lowerPlace(argument);
    return context.emitValue(.{ .delete_place = place }, context.nodeType(node_id));
}

fn emitCompound(context: anytype, node_id: ast.NodeId, operator: tokens.TokenType, left: ids.ValueId, right: ids.ValueId) anyerror!ids.ValueId {
    const type_id = context.nodeType(node_id);
    const builtins = context.builder.result.semanticResult().type_store.builtins;
    if (operator == .PlusEqual) {
        const mode: model.AddMode = if (type_id == builtins.string) .string_concat else if (type_id == builtins.number or type_id == builtins.bigint) .numeric else .dynamic;
        return context.emitValue(.{ .add = .{ .left = left, .right = right, .mode = mode } }, type_id);
    }
    const mode: model.NumericMode = if (type_id == builtins.number) .number else if (type_id == builtins.bigint) .bigint else .dynamic;
    const binary: model.BinaryOperator = switch (operator) {
        .MinusEqual => .subtract,
        .AsteriskEqual => .multiply,
        .SlashEqual => .divide,
        .PercentEqual => .remainder,
        .AsteriskAsteriskEqual => .exponentiate,
        .AmpersandEqual => .bit_and,
        .BarEqual => .bit_or,
        .CaretEqual => .bit_xor,
        .LessThanLessThanEqual => .shift_left,
        .GreaterThanGreaterThanEqual => .shift_right,
        .GreaterThanGreaterThanGreaterThanEqual => .shift_right_unsigned,
        else => return error.UnsupportedHirExpression,
    };
    return context.emitValue(.{ .binary = .{ .operator = binary, .left = left, .right = right, .mode = mode } }, type_id);
}

fn isLogicalAssignment(operator: tokens.TokenType) bool {
    return switch (operator) {
        .AmpersandAmpersandEqual, .BarBarEqual, .QuestionQuestionEqual => true,
        else => false,
    };
}
