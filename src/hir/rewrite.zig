//! Exhaustive HIR operand and target rewriting used by canonicalization.

const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");

pub const ValueReplacement = struct { from: ids.ValueId, to: ids.ValueId };
pub const BlockReplacement = struct { from: ids.BlockId, to: ids.BlockId };

pub fn value(replacements: []const ValueReplacement, input: ids.ValueId) ids.ValueId {
    var current = input;
    var remaining = replacements.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        var changed = false;
        for (replacements) |item| if (item.from.eql(current)) {
            current = item.to;
            changed = true;
            break;
        };
        if (!changed) break;
    }
    return current;
}

pub fn block(replacements: []const BlockReplacement, input: ids.BlockId) ids.BlockId {
    var current = input;
    var remaining = replacements.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        var changed = false;
        for (replacements) |item| if (item.from.eql(current)) {
            current = item.to;
            changed = true;
            break;
        };
        if (!changed) break;
    }
    return current;
}

fn key(values: []const ValueReplacement, input: model.PropertyKey) model.PropertyKey {
    return switch (input) {
        .computed => |item| .{ .computed = value(values, item) },
        else => input,
    };
}

fn valueSlice(allocator: std.mem.Allocator, replacements: []const ValueReplacement, input: []const ids.ValueId) ![]const ids.ValueId {
    if (input.len == 0) return input;
    const output = try allocator.alloc(ids.ValueId, input.len);
    for (input, 0..) |item, index| output[index] = value(replacements, item);
    return output;
}

fn arguments(allocator: std.mem.Allocator, replacements: []const ValueReplacement, input: []const model.CallArgument) ![]const model.CallArgument {
    if (input.len == 0) return input;
    const output = try allocator.alloc(model.CallArgument, input.len);
    for (input, 0..) |item, index| output[index] = switch (item) {
        .value => |operand| .{ .value = value(replacements, operand) },
        .spread => |operand| .{ .spread = value(replacements, operand) },
    };
    return output;
}

pub fn operation(allocator: std.mem.Allocator, replacements: []const ValueReplacement, input: model.HirOperation) !model.HirOperation {
    return switch (input) {
        .copy => |v| .{ .copy = value(replacements, v) },
        .initialize_binding => |x| .{ .initialize_binding = .{ .binding = x.binding, .value = value(replacements, x.value) } },
        .store_binding => |x| .{ .store_binding = .{ .binding = x.binding, .value = value(replacements, x.value) } },
        .make_property_place => |x| .{ .make_property_place = .{ .result = x.result, .base = value(replacements, x.base), .key = key(replacements, x.key) } },
        .make_element_place => |x| .{ .make_element_place = .{ .result = x.result, .base = value(replacements, x.base), .key = value(replacements, x.key) } },
        .make_super_place => |x| .{ .make_super_place = .{ .result = x.result, .receiver = value(replacements, x.receiver), .key = key(replacements, x.key) } },
        .store_place => |x| .{ .store_place = .{ .place = x.place, .value = value(replacements, x.value) } },
        .to_boolean => |v| .{ .to_boolean = value(replacements, v) },
        .is_nullish => |v| .{ .is_nullish = value(replacements, v) },
        .typeof_value => |v| .{ .typeof_value = value(replacements, v) },
        .void_value => |v| .{ .void_value = value(replacements, v) },
        .unary => |x| .{ .unary = .{ .operator = x.operator, .operand = value(replacements, x.operand), .mode = x.mode } },
        .binary => |x| .{ .binary = .{ .operator = x.operator, .left = value(replacements, x.left), .right = value(replacements, x.right), .mode = x.mode } },
        .add => |x| .{ .add = .{ .left = value(replacements, x.left), .right = value(replacements, x.right), .mode = x.mode } },
        .call => |x| .{ .call = .{ .callee = value(replacements, x.callee), .arguments = try arguments(allocator, replacements, x.arguments) } },
        .construct => |x| .{ .construct = .{ .callee = value(replacements, x.callee), .arguments = try arguments(allocator, replacements, x.arguments) } },
        .call_method => |x| .{ .call_method = .{ .callee = if (x.callee) |v| value(replacements, v) else null, .receiver = value(replacements, x.receiver), .key = key(replacements, x.key), .arguments = try arguments(allocator, replacements, x.arguments) } },
        .call_super_method => |x| .{ .call_super_method = .{ .callee = if (x.callee) |v| value(replacements, v) else null, .receiver = value(replacements, x.receiver), .key = key(replacements, x.key), .arguments = try arguments(allocator, replacements, x.arguments) } },
        .call_super_constructor => |x| .{ .call_super_constructor = try arguments(allocator, replacements, x) },
        .tagged_template_call => |x| .{ .tagged_template_call = .{ .tag = value(replacements, x.tag), .receiver = if (x.receiver) |v| value(replacements, v) else null, .template_site = value(replacements, x.template_site), .substitutions = try valueSlice(allocator, replacements, x.substitutions) } },
        .dynamic_import => |x| .{ .dynamic_import = .{ .source = value(replacements, x.source), .options = if (x.options) |v| value(replacements, v) else null, .attributes = x.attributes } },
        .create_class => |x| .{ .create_class = .{ .entity = x.entity, .base = if (x.base) |v| value(replacements, v) else null } },
        .define_property => |x| .{ .define_property = .{ .object = value(replacements, x.object), .key = key(replacements, x.key), .value = value(replacements, x.value) } },
        .define_method => |x| .{ .define_method = .{ .object = value(replacements, x.object), .key = key(replacements, x.key), .function = x.function, .kind = x.kind, .is_static = x.is_static } },
        .copy_object_properties => |x| .{ .copy_object_properties = .{ .target = value(replacements, x.target), .source = value(replacements, x.source) } },
        .array_append => |x| .{ .array_append = .{ .array = value(replacements, x.array), .value = value(replacements, x.value) } },
        .array_append_hole => |v| .{ .array_append_hole = value(replacements, v) },
        .array_append_iterable => |x| .{ .array_append_iterable = .{ .array = value(replacements, x.array), .iterable = value(replacements, x.iterable) } },
        .build_string => |parts| blk: {
            const output = try allocator.alloc(model.TemplatePart, parts.len);
            for (parts, 0..) |part, index| output[index] = switch (part) {
                .value => |v| .{ .value = value(replacements, v) },
                else => part,
            };
            break :blk .{ .build_string = output };
        },
        .to_string => |v| .{ .to_string = value(replacements, v) },
        .get_iterator => |v| .{ .get_iterator = value(replacements, v) },
        .get_async_iterator => |v| .{ .get_async_iterator = value(replacements, v) },
        .iterator_next => |v| .{ .iterator_next = value(replacements, v) },
        .iterator_done => |v| .{ .iterator_done = value(replacements, v) },
        .iterator_value => |v| .{ .iterator_value = value(replacements, v) },
        .iterator_close => |v| .{ .iterator_close = value(replacements, v) },
        .enumerate_properties => |v| .{ .enumerate_properties = value(replacements, v) },
        .enumerator_next => |v| .{ .enumerator_next = value(replacements, v) },
        .enumerator_done => |v| .{ .enumerator_done = value(replacements, v) },
        .enumerator_value => |v| .{ .enumerator_value = value(replacements, v) },
        .await_ => |v| .{ .await_ = value(replacements, v) },
        .yield_ => |v| .{ .yield_ = value(replacements, v) },
        .yield_delegate => |v| .{ .yield_delegate = value(replacements, v) },
        else => input,
    };
}

pub fn terminator(allocator: std.mem.Allocator, values: []const ValueReplacement, blocks: []const BlockReplacement, input: model.HirTerminator) !model.HirTerminator {
    return switch (input) {
        .jump => |x| .{ .jump = .{ .target = block(blocks, x.target), .arguments = try valueSlice(allocator, values, x.arguments) } },
        .branch => |x| .{ .branch = .{ .condition = value(values, x.condition), .true_target = block(blocks, x.true_target), .false_target = block(blocks, x.false_target) } },
        .return_ => |v| .{ .return_ = if (v) |item| value(values, item) else null },
        .throw => |v| .{ .throw = value(values, v) },
        .leave_region => |x| .{ .leave_region = .{ .region = x.region, .cleanup = block(blocks, x.cleanup), .completion = switch (x.completion) {
            .normal => |target| .{ .normal = if (target) |item| block(blocks, item) else null },
            .return_ => |v| .{ .return_ = if (v) |item| value(values, item) else null },
            .throw => |v| .{ .throw = value(values, v) },
            .break_ => |target| .{ .break_ = block(blocks, target) },
            .continue_ => |target| .{ .continue_ = block(blocks, target) },
        } } },
        else => input,
    };
}

pub fn place(values: []const ValueReplacement, input: model.HirPlace) model.HirPlace {
    var output = input;
    output.kind = switch (input.kind) {
        .property => |x| .{ .property = .{ .base = value(values, x.base), .key = key(values, x.key) } },
        .element => |x| .{ .element = .{ .base = value(values, x.base), .key = value(values, x.key) } },
        .super_property => |x| .{ .super_property = .{ .receiver = value(values, x.receiver), .key = key(values, x.key) } },
        else => input.kind,
    };
    return output;
}
