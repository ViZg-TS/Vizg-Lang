const std = @import("std");
const ast_mod = @import("ast.zig");
const binder = @import("binder.zig");
const diagnostics = @import("../diagnostics/root.zig");
const tokens = @import("tokens.zig");

const NodeId = ast_mod.NodeId;

/// Hardcoded ambient globals (predeclared, no-stdlib style).
/// Future: load from external declarations / lib files / `ambient_globals` option.
const PredeclaredAmbients: []const []const u8 = &.{
    "console",
};

pub const ReferenceId = u32;

pub const ReferenceKind = enum {
    read,
    write,
    call,
    export_ref,
};

pub const Reference = struct {
    node: NodeId,
    name: []const u8,
    symbol: ?binder.SymbolId,
    scope: binder.ScopeId,
    kind: ReferenceKind,
    span: tokens.Span,
};

pub const ResolveResult = struct {
    references: []const Reference,
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ResolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.references);
        allocator.free(self.diagnostics);
        self.* = .{ .references = &.{}, .diagnostics = &.{} };
    }
};

const Resolver = struct {
    allocator: std.mem.Allocator,
    ast: ast_mod.Ast,
    bind: binder.BindResult,
    references: std.ArrayList(Reference) = .empty,
    diagnostic_list: std.ArrayList(diagnostics.Diagnostic) = .empty,
    next_scope: binder.ScopeId = 1,

    fn resolve(self: *Resolver) !ResolveResult {
        if (self.bind.scopes.len == 0) {
            return .{
                .references = try self.references.toOwnedSlice(self.allocator),
                .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
            };
        }

        try self.resolveNode(self.ast.root, 0);
        return .{
            .references = try self.references.toOwnedSlice(self.allocator),
            .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
        };
    }

    fn resolveNode(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) anyerror!void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Program => |program| {
                for (program.statements) |statement| try self.resolveNode(statement, scope);
            },
            .ImportDeclaration => {},
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast_mod.invalid_node) {
                    try self.resolveNode(export_decl.declaration, scope);
                } else {
                    for (export_decl.specifiers) |specifier| {
                        const local_node = if (specifier.local != ast_mod.invalid_node) specifier.local else node_id;
                        try self.addReference(local_node, specifier.local_name, scope, .export_ref);
                    }
                }
            },
            .FunctionDeclaration => |function_decl| {
                const function_scope = self.takeScope();
                for (function_decl.params) |_| {}
                try self.resolveNode(function_decl.body, function_scope);
            },
            .BlockStatement => |block| {
                const block_scope = self.takeScope();
                for (block.statements) |statement| try self.resolveNode(statement, block_scope);
            },
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration| try self.resolveNode(declaration, scope);
            },
            .VariableDeclarator => |declarator| {
                if (declarator.init) |initializer| try self.resolveNode(initializer, scope);
            },
            .Parameter => {},
            .ReturnStatement => |return_stmt| {
                if (return_stmt.argument) |expression| try self.resolveNode(expression, scope);
            },
            .ExpressionStatement => |statement| try self.resolveNode(statement.expression, scope),
            .Identifier => |identifier| try self.addReference(node_id, identifier.name, scope, .read),
            .Literal => {},
            .CallExpression => |call| {
                try self.resolveCallee(call.callee, scope);
                for (call.arguments) |arg| try self.resolveNode(arg, scope);
            },
            .ElementAccessExpression => |elem_access| {
                try self.resolveNode(elem_access.object, scope);
                try self.resolveNode(elem_access.index, scope);
            },
            .AsExpression => |as_expr| {
                // Resolve only the inner expression; do NOT resolve type_annotation as a value.
                _ = as_expr.type_annotation;  // type names are not resolved at runtime
                try self.resolveNode(as_expr.expression, scope);
            },
            .NonNullExpression => |nonnull| try self.resolveNode(nonnull.expression, scope),
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            .BinaryExpression => |binary| {
                try self.resolveNode(binary.left, scope);
                try self.resolveNode(binary.right, scope);
            },
            .UpdateExpression => |update_expr| {
                // Postfix/PREFIX update is a read-modify-write; emit write ref on argument.
                if (node_id == ast_mod.invalid_node) {} else switch (self.ast.node(update_expr.argument).data) {
                    .Identifier => |id| try self.addReference(update_expr.argument, id.name, scope, .write),
                    .ElementAccessExpression => |elem_access| try self.resolveNode(elem_access.object, scope),
                    .MemberExpression => |member| try self.resolveNode(member.object, scope),
                    else => {},
                }
            },
            .AssignmentExpression => |assignment| {
                try self.resolveAssignmentTarget(assignment.left, scope);
                try self.resolveNode(assignment.right, scope);
            },
            .IfStatement => |if_stmt| {
                try self.resolveNode(if_stmt.condition, scope);
                try self.resolveNode(if_stmt.consequent, scope);
                if (if_stmt.alternate) |alternate| try self.resolveNode(alternate, scope);
            },
            .WhileStatement => |while_stmt| {
                try self.resolveNode(while_stmt.condition, scope);
                try self.resolveNode(while_stmt.body, scope);
            },
            .ForStatement => |for_stmt| {
                if (for_stmt.init) |init| try self.resolveNode(init, scope);
                if (for_stmt.condition) |condition| try self.resolveNode(condition, scope);
                if (for_stmt.update) |update| try self.resolveNode(update, scope);
                try self.resolveNode(for_stmt.body, scope);
            },
            .ObjectExpression => |obj_expr| {
                for (obj_expr.properties) |prop| try self.resolveNode(prop.value, scope);
            },
            .ArrayExpression => |arr| {
                for (arr.elements) |elem| try self.resolveNode(elem, scope);
            },
        }
    }

    fn resolveCallee(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) !void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Identifier => |identifier| try self.addReference(node_id, identifier.name, scope, .call),
            .ElementAccessExpression => |elem_access| try self.resolveNode(elem_access.object, scope),
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            else => try self.resolveNode(node_id, scope),
        }
    }

    fn resolveAssignmentTarget(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) !void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Identifier => |identifier| try self.addReference(node_id, identifier.name, scope, .write),
            .ElementAccessExpression => |elem_access| try self.resolveNode(elem_access.object, scope),
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            else => try self.resolveNode(node_id, scope),
        }
    }

    fn addReference(self: *Resolver, node_id: NodeId, name: []const u8, scope: binder.ScopeId, kind: ReferenceKind) !void {
        if (name.len == 0) return;
        const node = self.ast.node(node_id);
        const symbol = self.lookup(scope, name);
        try self.references.append(self.allocator, .{
            .node = node_id,
            .name = name,
            .symbol = symbol,
            .scope = scope,
            .kind = kind,
            .span = node.span,
        });

        if (symbol == null) {
            const is_ambient: bool = blk: for (PredeclaredAmbients) |ambient| {
                if (std.mem.eql(u8, ambient, name)) break :blk true;
            } else false;
            if (!is_ambient) {
                const message = try std.fmt.allocPrint(self.allocator, "cannot find name '{s}'", .{name});
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .cannot_find_name,
                    .phase = .resolver,
                    .message = message,
                    .span = node.span,
                    .label = "name is not declared in this scope",
                });
            }
        }
    }

    fn lookup(self: *Resolver, start_scope: binder.ScopeId, name: []const u8) ?binder.SymbolId {
        var scope_id: ?binder.ScopeId = start_scope;
        while (scope_id) |id| {
            const scope = self.bind.scopes[@intCast(id)];
            for (scope.symbols) |symbol_id| {
                const symbol = self.bind.symbols[@intCast(symbol_id)];
                if (std.mem.eql(u8, symbol.name, name)) return symbol_id;
            }
            scope_id = scope.parent;
        }
        return null;
    }

    fn takeScope(self: *Resolver) binder.ScopeId {
        const scope = self.next_scope;
        self.next_scope += 1;
        return scope;
    }
};

pub fn resolve(allocator: std.mem.Allocator, tree: ast_mod.Ast, bound: binder.BindResult) !ResolveResult {
    var resolver = Resolver{
        .allocator = allocator,
        .ast = tree,
        .bind = bound,
    };
    return resolver.resolve();
}
