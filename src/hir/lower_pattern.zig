//! Shared structural pattern lowering for declarations and assignments.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const tokens = @import("../frontend/tokens.zig");

pub fn isComposite(node: ast.Node) bool {
    return switch (node.data) {
        .ArrayExpression, .ObjectExpression => true,
        else => false,
    };
}

pub fn predeclare(context: anytype, pattern: ast.NodeId, kind: model.HirBindingKind) anyerror!void {
    switch (context.astNode(pattern).data) {
        .Identifier => try context.declarePatternIdentifier(pattern, kind),
        .ArrayExpression => |array| for (array.elements) |element| {
            if (element) |child| try predeclare(context, child, kind);
        },
        .ObjectExpression => |object| for (object.properties) |property| {
            if (property.computed_key != null or property.kind == .computed) return error.UnsupportedHirPattern;
            switch (property.kind) {
                .key_value, .shorthand => try predeclare(context, property.value, kind),
                .spread => return error.UnsupportedHirPattern,
                else => return error.UnsupportedHirPattern,
            }
        },
        .AssignmentExpression => |assignment| {
            if (assignment.operator != .Equal) return error.UnsupportedHirPattern;
            try predeclare(context, assignment.left, kind);
        },
        .SpreadElement => return error.UnsupportedHirPattern,
        else => return error.UnsupportedHirPattern,
    }
}

pub fn lower(
    context: anytype,
    position: model.PatternPosition,
    pattern: ast.NodeId,
    source: ids.ValueId,
) anyerror!void {
    var items: std.ArrayList(model.PatternItem) = .empty;
    try append(context, position, pattern, &items);
    try context.emitVoid(.{ .apply_pattern = .{
        .position = position,
        .source = source,
        .items = try items.toOwnedSlice(context.builder.allocator),
    } });
}

fn append(
    context: anytype,
    position: model.PatternPosition,
    pattern: ast.NodeId,
    items: *std.ArrayList(model.PatternItem),
) anyerror!void {
    switch (context.astNode(pattern).data) {
        .Identifier => switch (position) {
            .declaration => try items.append(context.builder.allocator, .{
                .binding_target = try context.patternBinding(pattern),
            }),
            .assignment => try items.append(context.builder.allocator, .{
                .place_target = try context.lowerPlace(pattern),
            }),
            else => return error.UnsupportedHirPattern,
        },
        .ArrayExpression => |array| {
            try items.append(context.builder.allocator, .array_begin);
            for (array.elements, 0..) |element, index| {
                const child = element orelse {
                    try items.append(context.builder.allocator, .elision);
                    continue;
                };
                if (context.astNode(child).data == .SpreadElement) return error.UnsupportedHirPattern;
                try items.append(context.builder.allocator, .{ .element = @intCast(index) });
                try append(context, position, child, items);
            }
            try items.append(context.builder.allocator, .array_end);
        },
        .ObjectExpression => |object| {
            try items.append(context.builder.allocator, .object_begin);
            for (object.properties) |property| {
                if (property.computed_key != null or property.kind == .computed) return error.UnsupportedHirPattern;
                switch (property.kind) {
                    .key_value, .shorthand => {
                        try items.append(context.builder.allocator, .{
                            .property_static = try context.builder.copyString(property.key),
                        });
                        try append(context, position, property.value, items);
                    },
                    .spread => return error.UnsupportedHirPattern,
                    else => return error.UnsupportedHirPattern,
                }
            }
            try items.append(context.builder.allocator, .object_end);
        },
        .AssignmentExpression => |assignment| {
            if (assignment.operator != tokens.TokenType.Equal) return error.UnsupportedHirPattern;
            try items.append(context.builder.allocator, .{
                .default_initializer = try context.lowerPatternInitializer(assignment.right),
            });
            try append(context, position, assignment.left, items);
        },
        .SpreadElement => return error.UnsupportedHirPattern,
        else => return error.UnsupportedHirPattern,
    }
}
