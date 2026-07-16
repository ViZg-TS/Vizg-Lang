//! Assignable-expression lowering into evaluated semantic places.

const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");

pub fn lower(context: anytype, node_id: ast.NodeId) anyerror!ids.PlaceId {
    const node = context.local.frontend.ast.node(node_id);
    return switch (node.data) {
        .Identifier => context.lowerIdentifierPlace(node_id),
        .MemberExpression => |member| lowerMember(context, member),
        .ElementAccessExpression => |element| lowerElement(context, element),
        else => error.UnsupportedHirPlace,
    };
}

fn lowerMember(context: anytype, member: ast.MemberExpression) anyerror!ids.PlaceId {
    if (member.optional) return error.UnsupportedHirPlace;
    const key = try context.builder.copyString(member.property);
    return switch (context.local.frontend.ast.node(member.object).data) {
        .SuperExpression => blk: {
            const receiver = try context.emitValue(.load_super, context.nodeType(member.object));
            break :blk context.emitPlace(.{ .super_property = .{ .receiver = receiver, .key = .{ .static = key } } });
        },
        else => blk: {
            const base = try context.lowerExpression(member.object);
            break :blk context.emitPlace(.{ .property = .{ .base = base, .key = .{ .static = key } } });
        },
    };
}

fn lowerElement(context: anytype, element: ast.ElementAccessExpression) anyerror!ids.PlaceId {
    if (element.optional) return error.UnsupportedHirPlace;
    return switch (context.local.frontend.ast.node(element.object).data) {
        .SuperExpression => blk: {
            const receiver = try context.emitValue(.load_super, context.nodeType(element.object));
            const key = try context.lowerExpression(element.index);
            break :blk context.emitPlace(.{ .super_property = .{ .receiver = receiver, .key = .{ .computed = key } } });
        },
        else => blk: {
            const base = try context.lowerExpression(element.object);
            const key = try context.lowerExpression(element.index);
            break :blk context.emitPlace(.{ .element = .{ .base = base, .key = key } });
        },
    };
}
