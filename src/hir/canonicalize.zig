//! Mandatory deterministic HIR v1 canonicalization.
//!
//! The fixed-order worklist converges because each rewrite either removes one
//! instruction, block, or block parameter, or changes a one-way syntax rank
//! (operation to constant, branch to jump, valued return to empty return).

const std = @import("std");
const builder_mod = @import("builder.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const rewrite = @import("rewrite.zig");
const trace = @import("trace.zig");

pub const Error = error{ CanonicalizationBudget, ResourceLimit } || std.mem.Allocator.Error;

pub fn run(builder: *builder_mod.Builder) Error!void {
    var function_index: usize = 0;
    while (function_index < builder.functions.items.len) : (function_index += 1) {
        while (try canonicalizeFunction(builder, function_index)) {}
    }
}

fn canonicalizeFunction(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    if (try eliminateCopies(builder, function_index)) return true;
    if (try foldOneLiteral(builder, function_index)) return true;
    if (try simplifyOneBranch(builder, function_index)) return true;
    if (try normalizeOneReturn(builder, function_index)) return true;
    if (try collapseOneMergeValue(builder, function_index)) return true;
    if (try removeOneUnusedPure(builder, function_index)) return true;
    if (try removeUnreachable(builder, function_index)) return true;
    if (try mergeOneJumpBlock(builder, function_index)) return true;
    return false;
}

fn noteRewrite(builder: *builder_mod.Builder, kind: trace.EventKind, source: ids.OriginId) Error!void {
    if (builder.budget.reserve(.rewrites, 1) != null) return error.CanonicalizationBudget;
    if (builder.debug_level == .full) {
        const inputs = try builder.allocator.dupe(ids.OriginId, &.{source});
        try builder.appendTrace(.{ .kind = kind, .inputs = inputs, .output = source });
    }
}

fn eliminateCopies(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    const function = &builder.functions.items[function_index];
    var replacements: std.ArrayList(rewrite.ValueReplacement) = .empty;
    defer replacements.deinit(builder.allocator);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.operation == .copy and copyCanBeEliminated(function, instruction)) {
            try replacements.append(builder.allocator, .{
                .from = instruction.result.?,
                .to = rewrite.value(replacements.items, instruction.operation.copy),
            });
            try noteRewrite(builder, .canonical_rewrite, instruction.origin);
        }
    };
    if (replacements.items.len == 0) return false;
    try applyValueReplacements(builder, function_index, replacements.items, true);
    return true;
}

pub fn copyCanBeEliminated(function: *const model.HirFunction, instruction: model.HirInstruction) bool {
    if (instruction.operation != .copy) return false;
    const source = instruction.operation.copy;
    const source_type = valueType(function, source) orelse return false;
    const source_origin = valueOrigin(function, source) orelse return false;
    return instruction.result_type.? == source_type and instruction.origin.eql(source_origin);
}

fn valueType(function: *const model.HirFunction, value: ids.ValueId) ?model.TypeId {
    for (function.blocks) |block| {
        for (block.parameters) |parameter| if (parameter.value.eql(value)) return parameter.type_id;
        for (block.instructions) |instruction| if (instruction.result) |result| if (result.eql(value)) return instruction.result_type;
    }
    return null;
}

fn valueOrigin(function: *const model.HirFunction, value: ids.ValueId) ?ids.OriginId {
    for (function.blocks) |block| {
        for (block.parameters) |parameter| if (parameter.value.eql(value)) return parameter.origin;
        for (block.instructions) |instruction| if (instruction.result) |result| if (result.eql(value)) return instruction.origin;
    }
    return null;
}

fn applyValueReplacements(builder: *builder_mod.Builder, function_index: usize, replacements: []const rewrite.ValueReplacement, remove_copies: bool) !void {
    var function = builder.functions.items[function_index];
    const places = try builder.allocator.alloc(model.HirPlace, function.places.len);
    for (function.places, 0..) |place, index| places[index] = rewrite.place(replacements, place);
    function.places = places;

    const blocks = try builder.allocator.alloc(model.HirBlock, function.blocks.len);
    for (function.blocks, 0..) |block, block_index| {
        var instructions: std.ArrayList(model.HirInstruction) = .empty;
        for (block.instructions) |instruction| {
            if (remove_copies and instruction.operation == .copy and hasReplacement(replacements, instruction.result.?)) continue;
            var output = instruction;
            output.operation = try rewrite.operation(builder.allocator, replacements, instruction.operation);
            try instructions.append(builder.allocator, output);
        }
        blocks[block_index] = block;
        blocks[block_index].instructions = try instructions.toOwnedSlice(builder.allocator);
        blocks[block_index].terminator = try rewrite.terminator(builder.allocator, replacements, &.{}, block.terminator);
    }
    function.blocks = blocks;
    builder.functions.items[function_index] = function;
}

fn hasReplacement(replacements: []const rewrite.ValueReplacement, value_id: ids.ValueId) bool {
    for (replacements) |replacement| if (replacement.from.eql(value_id)) return true;
    return false;
}

fn constantDefinitions(builder: *builder_mod.Builder, function: model.HirFunction) ![]?model.HirConstant {
    const constants = try builder.allocator.alloc(?model.HirConstant, builder.budget.usage.values);
    @memset(constants, null);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.operation == .constant) constants[instruction.result.?.index().?] = instruction.operation.constant;
    };
    return constants;
}

fn foldOneLiteral(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    const constants = try constantDefinitions(builder, function);
    for (function.blocks, 0..) |block, block_index| for (block.instructions, 0..) |instruction, instruction_index| {
        const folded = foldOperation(constants, instruction.operation) orelse continue;
        try noteRewrite(builder, .constant_folded, instruction.origin);
        const blocks = try builder.allocator.dupe(model.HirBlock, function.blocks);
        const instructions = try builder.allocator.dupe(model.HirInstruction, block.instructions);
        instructions[instruction_index].operation = .{ .constant = folded };
        instructions[instruction_index].effects = model.EffectSet.pure_effect;
        blocks[block_index].instructions = instructions;
        function.blocks = blocks;
        builder.functions.items[function_index] = function;
        return true;
    };
    return false;
}

fn known(constants: []const ?model.HirConstant, value: ids.ValueId) ?model.HirConstant {
    const index = value.index() orelse return null;
    if (index >= constants.len) return null;
    return constants[index];
}

fn foldOperation(constants: []const ?model.HirConstant, operation: model.HirOperation) ?model.HirConstant {
    return switch (operation) {
        .to_boolean => |operand| if (known(constants, operand)) |item| .{ .boolean = truthy(item) } else null,
        .is_nullish => |operand| if (known(constants, operand)) |item| .{ .boolean = item == .undefined or item == .null_ } else null,
        .void_value => .undefined,
        .unary => |item| foldUnary(item.operator, known(constants, item.operand) orelse return null, item.mode),
        .binary => |item| foldBinary(item.operator, known(constants, item.left) orelse return null, known(constants, item.right) orelse return null, item.mode),
        .add => |item| foldAdd(known(constants, item.left) orelse return null, known(constants, item.right) orelse return null, item.mode),
        else => null,
    };
}

fn truthy(value: model.HirConstant) bool {
    return switch (value) {
        .undefined, .null_ => false,
        .boolean => |item| item,
        .number => |item| item != 0 and !std.math.isNan(item),
        .bigint => |item| !std.mem.eql(u8, item, "0"),
        .string => |item| item.len != 0,
    };
}

fn foldUnary(operator: model.UnaryOperator, operand: model.HirConstant, mode: model.NumericMode) ?model.HirConstant {
    return switch (operator) {
        .logical_not => .{ .boolean = !truthy(operand) },
        .plus => if (mode == .number and operand == .number) .{ .number = operand.number } else null,
        .negate => if (mode == .number and operand == .number) .{ .number = -operand.number } else null,
        .bit_not => null,
    };
}

fn foldBinary(operator: model.BinaryOperator, left: model.HirConstant, right: model.HirConstant, mode: model.NumericMode) ?model.HirConstant {
    if (operator == .equal_strict or operator == .not_equal_strict) {
        const equal = constantEqual(left, right);
        return .{ .boolean = if (operator == .equal_strict) equal else !equal };
    }
    if (mode != .number or left != .number or right != .number) return null;
    return switch (operator) {
        .subtract => .{ .number = left.number - right.number },
        .multiply => .{ .number = left.number * right.number },
        .less => .{ .boolean = left.number < right.number },
        .less_equal => .{ .boolean = left.number <= right.number },
        .greater => .{ .boolean = left.number > right.number },
        .greater_equal => .{ .boolean = left.number >= right.number },
        else => null,
    };
}

fn foldAdd(left: model.HirConstant, right: model.HirConstant, mode: model.AddMode) ?model.HirConstant {
    if (mode == .numeric and left == .number and right == .number) return .{ .number = left.number + right.number };
    return null;
}

fn constantEqual(left: model.HirConstant, right: model.HirConstant) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .undefined, .null_ => true,
        .boolean => |item| item == right.boolean,
        .number => |item| item == right.number,
        .bigint => |item| std.mem.eql(u8, item, right.bigint),
        .string => |item| std.mem.eql(u8, item, right.string),
    };
}

fn simplifyOneBranch(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    const constants = try constantDefinitions(builder, function);
    for (function.blocks, 0..) |block, index| if (block.terminator == .branch) {
        const branch = block.terminator.branch;
        const condition = known(constants, branch.condition) orelse continue;
        try noteRewrite(builder, .canonical_rewrite, block.origin);
        const blocks = try builder.allocator.dupe(model.HirBlock, function.blocks);
        blocks[index].terminator = .{ .jump = .{ .target = if (truthy(condition)) branch.true_target else branch.false_target } };
        function.blocks = blocks;
        builder.functions.items[function_index] = function;
        return true;
    };
    return false;
}

fn normalizeOneReturn(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    const constants = try constantDefinitions(builder, function);
    for (function.blocks, 0..) |block, index| if (block.terminator == .return_) {
        const returned = block.terminator.return_ orelse continue;
        const item = known(constants, returned) orelse continue;
        if (item != .undefined) continue;
        try noteRewrite(builder, .canonical_rewrite, block.origin);
        const blocks = try builder.allocator.dupe(model.HirBlock, function.blocks);
        blocks[index].terminator = .{ .return_ = null };
        function.blocks = blocks;
        builder.functions.items[function_index] = function;
        return true;
    };
    return false;
}

fn collapseOneMergeValue(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    const function = builder.functions.items[function_index];
    for (function.blocks) |target| {
        if (target.id.eql(function.entry)) continue;
        for (target.parameters, 0..) |parameter, parameter_index| {
            var incoming: ?ids.ValueId = null;
            var edge_count: usize = 0;
            var legal = true;
            for (function.blocks) |source| switch (source.terminator) {
                .jump => |jump| if (jump.target.eql(target.id)) {
                    if (jump.arguments.len != target.parameters.len) {
                        legal = false;
                        break;
                    }
                    const argument = jump.arguments[parameter_index];
                    if (incoming) |first| {
                        if (!first.eql(argument)) {
                            legal = false;
                            break;
                        }
                    } else incoming = argument;
                    edge_count += 1;
                },
                .branch => |branch| if (branch.true_target.eql(target.id) or branch.false_target.eql(target.id)) {
                    legal = false;
                    break;
                },
                else => {},
            };
            if (!legal or edge_count == 0) continue;
            try noteRewrite(builder, .canonical_rewrite, parameter.origin);
            try applyValueReplacements(builder, function_index, &.{.{ .from = parameter.value, .to = incoming.? }}, false);
            var updated = builder.functions.items[function_index];
            const blocks = try builder.allocator.dupe(model.HirBlock, updated.blocks);
            for (blocks) |*block| {
                if (block.id.eql(target.id)) block.parameters = try removeAt(model.HirBlockParameter, builder.allocator, block.parameters, parameter_index);
                if (block.terminator == .jump and block.terminator.jump.target.eql(target.id)) {
                    block.terminator.jump.arguments = try removeAt(ids.ValueId, builder.allocator, block.terminator.jump.arguments, parameter_index);
                }
            }
            updated.blocks = blocks;
            builder.functions.items[function_index] = updated;
            return true;
        }
    }
    return false;
}

fn removeAt(comptime T: type, allocator: std.mem.Allocator, input: []const T, removed: usize) ![]const T {
    const output = try allocator.alloc(T, input.len - 1);
    @memcpy(output[0..removed], input[0..removed]);
    @memcpy(output[removed..], input[removed + 1 ..]);
    return output;
}

fn removeOneUnusedPure(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    const uses = try builder.allocator.alloc(usize, builder.budget.usage.values);
    @memset(uses, 0);
    for (function.places) |place| countUses(@TypeOf(place.kind), place.kind, uses);
    for (function.blocks) |block| {
        for (block.instructions) |instruction| countUses(model.HirOperation, instruction.operation, uses);
        countTerminatorUses(block.terminator, uses);
    }
    for (function.blocks, 0..) |block, block_index| for (block.instructions, 0..) |instruction, instruction_index| {
        const result = instruction.result orelse continue;
        if (uses[result.index().?] != 0 or !instruction.effects.pure or instruction.effects.creates_identity) continue;
        try noteRewrite(builder, .canonical_rewrite, instruction.origin);
        const blocks = try builder.allocator.dupe(model.HirBlock, function.blocks);
        blocks[block_index].instructions = try removeAt(model.HirInstruction, builder.allocator, block.instructions, instruction_index);
        function.blocks = blocks;
        builder.functions.items[function_index] = function;
        return true;
    };
    return false;
}

fn countValue(value_id: ids.ValueId, uses: []usize) void {
    if (value_id.index()) |index| {
        if (index < uses.len) uses[index] += 1;
    }
}

fn countCompletionUses(completion: model.Completion, uses: []usize) void {
    switch (completion) {
        .return_ => |returned| if (returned) |value_id| countValue(value_id, uses),
        .throw => |value_id| countValue(value_id, uses),
        else => {},
    }
}

fn countTerminatorUses(terminator: model.HirTerminator, uses: []usize) void {
    switch (terminator) {
        .jump => |jump| for (jump.arguments) |value_id| countValue(value_id, uses),
        .branch => |branch| countValue(branch.condition, uses),
        .return_ => |returned| if (returned) |value_id| countValue(value_id, uses),
        .throw => |value_id| countValue(value_id, uses),
        .leave_region => |leave| countCompletionUses(leave.completion, uses),
        .unreachable_, .resume_completion => {},
    }
}

fn countUses(comptime T: type, input: T, uses: []usize) void {
    if (T == ids.ValueId) {
        if (input.index()) |index| {
            if (index < uses.len) uses[index] += 1;
        }
        return;
    }
    switch (@typeInfo(T)) {
        .optional => {
            if (input) |item| countUses(@TypeOf(item), item, uses);
        },
        .pointer => |info| switch (info.size) {
            .slice => for (input) |item| countUses(info.child, item, uses),
            else => {},
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| countUses(field.type, @field(input, field.name), uses);
        },
        .@"union" => switch (input) {
            inline else => |item| countUses(@TypeOf(item), item, uses),
        },
        else => {},
    }
}

fn removeUnreachable(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    if (function.blocks.len == 0) return false;
    const reachable = try builder.allocator.alloc(bool, function.blocks.len);
    @memset(reachable, false);
    var worklist: std.ArrayList(ids.BlockId) = .empty;
    defer worklist.deinit(builder.allocator);
    try worklist.append(builder.allocator, function.entry);
    for (builder.regions.items) |region| if (region.function.eql(function.id)) {
        try worklist.append(builder.allocator, region.handler);
        if (region.continuation) |item| try worklist.append(builder.allocator, item);
        try worklist.appendSlice(builder.allocator, region.protected_blocks);
    };
    var cursor: usize = 0;
    while (cursor < worklist.items.len) : (cursor += 1) {
        const index = blockIndex(function.blocks, worklist.items[cursor]) orelse continue;
        if (reachable[index]) continue;
        reachable[index] = true;
        try appendSuccessors(builder.allocator, &worklist, function.blocks[index].terminator);
    }
    var removed: usize = 0;
    for (reachable) |item| if (!item) {
        removed += 1;
    };
    if (removed == 0) return false;
    for (function.blocks, reachable) |block, keep| if (!keep) try noteRewrite(builder, .unreachable_removed, block.origin);
    const blocks = try builder.allocator.alloc(model.HirBlock, function.blocks.len - removed);
    var output: usize = 0;
    for (function.blocks, reachable) |block, keep| if (keep) {
        blocks[output] = block;
        output += 1;
    };
    function.blocks = blocks;
    builder.functions.items[function_index] = function;
    return true;
}

fn appendSuccessors(allocator: std.mem.Allocator, worklist: *std.ArrayList(ids.BlockId), terminator: model.HirTerminator) !void {
    switch (terminator) {
        .jump => |item| try worklist.append(allocator, item.target),
        .branch => |item| {
            try worklist.append(allocator, item.true_target);
            try worklist.append(allocator, item.false_target);
        },
        .leave_region => |item| {
            try worklist.append(allocator, item.cleanup);
            switch (item.completion) {
                .normal => |target| if (target) |block_id| try worklist.append(allocator, block_id),
                .break_, .continue_ => |target| try worklist.append(allocator, target),
                else => {},
            }
        },
        else => {},
    }
}

fn mergeOneJumpBlock(builder: *builder_mod.Builder, function_index: usize) Error!bool {
    var function = builder.functions.items[function_index];
    for (function.blocks, 0..) |candidate, candidate_index| {
        if (candidate.id.eql(function.entry) or candidate.parameters.len != 0 or candidate.instructions.len != 0 or candidate.terminator != .jump) continue;
        const jump = candidate.terminator.jump;
        if (jump.arguments.len != 0 or jump.target.eql(candidate.id)) continue;
        const target_index = blockIndex(function.blocks, jump.target) orelse continue;
        if (function.blocks[target_index].parameters.len != 0 or isRegionBoundary(builder, function.id, candidate.id)) continue;
        try noteRewrite(builder, .blocks_merged, candidate.origin);
        const replacement = rewrite.BlockReplacement{ .from = candidate.id, .to = jump.target };
        const blocks = try builder.allocator.alloc(model.HirBlock, function.blocks.len - 1);
        var output: usize = 0;
        for (function.blocks, 0..) |block_item, index| {
            if (index == candidate_index) continue;
            blocks[output] = block_item;
            blocks[output].terminator = try rewrite.terminator(builder.allocator, &.{}, &.{replacement}, block_item.terminator);
            output += 1;
        }
        function.blocks = blocks;
        builder.functions.items[function_index] = function;
        for (builder.regions.items) |*region| if (region.function.eql(function.id)) {
            if (region.continuation) |item| region.continuation = rewrite.block(&.{replacement}, item);
        };
        return true;
    }
    return false;
}

fn isRegionBoundary(builder: *builder_mod.Builder, function: ids.FunctionId, block_id: ids.BlockId) bool {
    for (builder.regions.items) |region| if (region.function.eql(function)) {
        if (region.handler.eql(block_id)) return true;
        if (region.continuation) |item| if (item.eql(block_id)) return true;
        for (region.protected_blocks) |item| if (item.eql(block_id)) return true;
    };
    return false;
}

fn blockIndex(blocks: []const model.HirBlock, id: ids.BlockId) ?usize {
    for (blocks, 0..) |block_item, index| if (block_item.id.eql(id)) return index;
    return null;
}
