const ast = @import("ast.zig");

pub const Kind = enum {
    declaration,
    expression,
    arrow,
    method,
    constructor,
    getter,
    setter,
};

pub const Receiver = enum {
    dynamic,
    lexical,
    object,
    class_instance,
    class_static,
};

pub const Descriptor = struct {
    node: ast.NodeId,
    name: ?[]const u8,
    params: []const ast.NodeId,
    body: ast.NodeId,
    expression_body: bool = false,
    return_type: ?ast.TypeAnnotation,
    flags: ast.FunctionFlags,
    type_parameters: []const ast.GenericTypeParameter = &.{},
    receiver: Receiver,
    kind: Kind,

    pub fn isAccessor(self: Descriptor) bool {
        return self.kind == .getter or self.kind == .setter;
    }
};

pub fn describe(tree: ast.Ast, node_id: ast.NodeId) ?Descriptor {
    const node = tree.node(node_id);
    return switch (node.data) {
        .FunctionDeclaration => |function| .{
            .node = node_id,
            .name = function.name,
            .params = function.params,
            .body = function.body,
            .return_type = function.return_type,
            .flags = function.flags,
            .type_parameters = function.type_parameters,
            .receiver = .dynamic,
            .kind = .declaration,
        },
        .FunctionExpression => |function| blk: {
            const object_kind = objectMethodKind(tree, node_id);
            break :blk .{
                .node = node_id,
                .name = function.name,
                .params = function.params,
                .body = function.body,
                .return_type = function.return_type,
                .flags = function.flags,
                .receiver = if (object_kind == null) .dynamic else .object,
                .kind = object_kind orelse .expression,
            };
        },
        .ArrowFunctionExpression => |function| .{
            .node = node_id,
            .name = null,
            .params = function.params,
            .body = function.body,
            .expression_body = function.expression_body,
            .return_type = function.return_type,
            .flags = function.flags,
            .receiver = .lexical,
            .kind = .arrow,
        },
        .ClassMethod => |method| .{
            .node = node_id,
            .name = method.name,
            .params = method.params,
            .body = method.body,
            .return_type = method.return_type,
            .flags = method.flags,
            .receiver = if (method.is_static) .class_static else .class_instance,
            .kind = switch (method.kind) {
                .method => .method,
                .constructor => .constructor,
                .getter => .getter,
                .setter => .setter,
            },
        },
        else => null,
    };
}

fn objectMethodKind(tree: ast.Ast, node_id: ast.NodeId) ?Kind {
    for (tree.nodes) |node| switch (node.data) {
        .ObjectExpression => |object| for (object.properties) |property| {
            if (property.value != node_id) continue;
            return switch (property.kind) {
                .method, .async_method => .method,
                .getter => .getter,
                .setter => .setter,
                else => null,
            };
        },
        else => {},
    };
    return null;
}
