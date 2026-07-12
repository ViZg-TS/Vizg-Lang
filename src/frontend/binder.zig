const std = @import("std");
const ast_mod = @import("ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const tokens = @import("tokens.zig");

const NodeId = ast_mod.NodeId;

pub const ScopeId = u32;
pub const SymbolId = u32;

pub const ScopeKind = enum {
    global,
    function,
    block,
};

pub const SymbolKind = enum {
    variable,
    function,
    parameter,
    import,
};

pub const Scope = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent: ?ScopeId,
    symbols: []const SymbolId,
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    scope: ScopeId,
    declaration: NodeId,
    span: tokens.Span,
};

pub const NodeSymbol = struct {
    node: NodeId,
    symbol: SymbolId,
};

pub const ImportRecord = struct {
    local_name: []const u8,
    source: []const u8,
};

pub const ExportRecord = struct {
    name: []const u8,
    local_name: []const u8,
    node: NodeId,
};

pub const ModuleInfo = struct {
    imports: []const ImportRecord,
    exports: []const ExportRecord,
};

pub const BindResult = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    node_symbols: []const NodeSymbol,
    module: ModuleInfo,
    diagnostics: []const diagnostics.Diagnostic,
};

const ScopeBuilder = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent: ?ScopeId,
    symbols: std.ArrayList(SymbolId) = .empty,
};

const Binder = struct {
    allocator: std.mem.Allocator,
    ast: ast_mod.Ast,
    scopes: std.ArrayList(ScopeBuilder) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    node_symbols: std.ArrayList(NodeSymbol) = .empty,
    imports: std.ArrayList(ImportRecord) = .empty,
    exports: std.ArrayList(ExportRecord) = .empty,
    diagnostic_list: std.ArrayList(diagnostics.Diagnostic) = .empty,

    fn bind(self: *Binder) !BindResult {
        const global_scope = try self.addScope(.global, null);
        try self.bindNode(self.ast.root, global_scope);

        var final_scopes: std.ArrayList(Scope) = .empty;
        errdefer final_scopes.deinit(self.allocator);
        for (self.scopes.items) |*scope| {
            try final_scopes.append(self.allocator, .{
                .id = scope.id,
                .kind = scope.kind,
                .parent = scope.parent,
                .symbols = try scope.symbols.toOwnedSlice(self.allocator),
            });
        }

        return .{
            .scopes = try final_scopes.toOwnedSlice(self.allocator),
            .symbols = try self.symbols.toOwnedSlice(self.allocator),
            .node_symbols = try self.node_symbols.toOwnedSlice(self.allocator),
            .module = .{
                .imports = try self.imports.toOwnedSlice(self.allocator),
                .exports = try self.exports.toOwnedSlice(self.allocator),
            },
            .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
        };
    }

    fn bindNode(self: *Binder, node_id: NodeId, scope: ScopeId) anyerror!void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Program => |program| {
                for (program.statements) |statement| try self.bindNode(statement, scope);
            },
            .ImportDeclaration => |import_decl| {
                for (import_decl.names) |name| {
                    _ = try self.declare(scope, name, .import, node_id, node.span);
                    try self.imports.append(self.allocator, .{
                        .local_name = name,
                        .source = import_decl.source,
                    });
                }
            },
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast_mod.invalid_node) {
                    const declaration = export_decl.declaration;
                    try self.bindNode(declaration, scope);
                    try self.recordDeclarationExports(declaration);
                } else {
                    for (export_decl.specifiers) |specifier| {
                        try self.appendExport(specifier.exported_name, specifier.local_name, node_id);
                    }
                }

                // Any export record — default or named — counts toward module exports.
                if (export_decl.default_name != null) {
                    _ = try self.appendExport("default", export_decl.default_name.?, node_id);
                }
            },
            .FunctionDeclaration => |function_decl| {
                const symbol_id = try self.declare(scope, function_decl.name, .function, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });

                const function_scope = try self.addScope(.function, scope);
                for (function_decl.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindNode(function_decl.body, function_scope);
            },
            .FunctionExpression => |function_expr| {
                const function_scope = try self.addScope(.function, scope);
                if (function_expr.name) |name| {
                    const symbol_id = try self.declare(function_scope, name, .function, node_id, node.span);
                    try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                }
                for (function_expr.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindNode(function_expr.body, function_scope);
            },
            .ArrowFunctionExpression => |arrow| {
                const function_scope = try self.addScope(.function, scope);
                for (arrow.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindNode(arrow.body, function_scope);
            },
            .BlockStatement => |block| {
                const block_scope = try self.addScope(.block, scope);
                for (block.statements) |statement| try self.bindNode(statement, block_scope);
            },
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration_id| try self.bindNode(declaration_id, scope);
            },
            .VariableDeclarator => |declarator| {
                const symbol_id = try self.declare(scope, declarator.name, .variable, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                if (declarator.init) |initializer| try self.bindNode(initializer, scope);
            },
            .ReturnStatement => |return_stmt| {
                if (return_stmt.argument) |expression| try self.bindNode(expression, scope);
            },
            .ThrowStatement => |throw_stmt| try self.bindNode(throw_stmt.argument, scope),
            .TryStatement => |try_stmt| {
                try self.bindNode(try_stmt.block, scope);
                if (try_stmt.handler) |handler| try self.bindNode(handler, scope);
                if (try_stmt.finalizer) |finalizer| try self.bindNode(finalizer, scope);
            },
            .CatchClause => |catch_clause| {
                const catch_scope = try self.addScope(.block, scope);
                if (catch_clause.parameter) |parameter_id| {
                    const parameter_node = self.ast.node(parameter_id);
                    switch (parameter_node.data) {
                        .Parameter => |parameter| _ = try self.declare(catch_scope, parameter.name, .variable, parameter_id, parameter_node.span),
                        else => {},
                    }
                }
                try self.bindNode(catch_clause.body, catch_scope);
            },
            .FinallyClause => |finally_clause| try self.bindNode(finally_clause.body, scope),
            .BreakStatement, .ContinueStatement => {},
            .ExpressionStatement => |statement| try self.bindNode(statement.expression, scope),
            .TemplateExpression => |template| {
                for (template.parts) |part| if (part.expression) |expression| try self.bindNode(expression, scope);
            },
            .RegExpLiteral => {},
            .SpreadElement => |spread| try self.bindNode(spread.argument, scope),
            .ThisExpression, .SuperExpression => {},
            .CallExpression => |call| {
                try self.bindNode(call.callee, scope);
                for (call.arguments) |arg| try self.bindNode(arg, scope);
            },
            .NewExpression => |new_expr| {
                try self.bindNode(new_expr.callee, scope);
                for (new_expr.arguments) |arg| try self.bindNode(arg, scope);
            },
            .ElementAccessExpression => |elem_access| {
                try self.bindNode(elem_access.object, scope);
                try self.bindNode(elem_access.index, scope);
            },
            .NonNullExpression => |nonnull| try self.bindNode(nonnull.expression, scope),
            .UnaryExpression => |unary| try self.bindNode(unary.argument, scope),
            .MemberExpression => |member| try self.bindNode(member.object, scope),
            .BinaryExpression => |binary| {
                try self.bindNode(binary.left, scope);
                try self.bindNode(binary.right, scope);
            },
            .ConditionalExpression => |conditional| {
                try self.bindNode(conditional.condition, scope);
                try self.bindNode(conditional.consequent, scope);
                try self.bindNode(conditional.alternate, scope);
            },
            .AssignmentExpression => |assignment| {
                try self.bindNode(assignment.left, scope);
                try self.bindNode(assignment.right, scope);
            },
            .IfStatement => |if_stmt| {
                try self.bindNode(if_stmt.condition, scope);
                try self.bindNode(if_stmt.consequent, scope);
                if (if_stmt.alternate) |alternate| try self.bindNode(alternate, scope);
            },
            .WhileStatement => |while_stmt| {
                try self.bindNode(while_stmt.condition, scope);
                try self.bindNode(while_stmt.body, scope);
            },
            .DoWhileStatement => |do_while_stmt| {
                try self.bindNode(do_while_stmt.body, scope);
                try self.bindNode(do_while_stmt.condition, scope);
            },
            .ForStatement => |for_stmt| {
                const loop_scope = try self.addScope(.block, scope);
                if (for_stmt.init) |init| try self.bindNode(init, loop_scope);
                if (for_stmt.condition) |condition| try self.bindNode(condition, loop_scope);
                if (for_stmt.update) |update| try self.bindNode(update, loop_scope);
                if (for_stmt.right) |right| try self.bindNode(right, loop_scope);
                try self.bindNode(for_stmt.body, loop_scope);
            },
            .SwitchStatement => |switch_stmt| {
                try self.bindNode(switch_stmt.discriminant, scope);
                const switch_scope = try self.addScope(.block, scope);
                for (switch_stmt.cases) |case| try self.bindNode(case, switch_scope);
            },
            .SwitchCase => |switch_case| {
                if (switch_case.condition) |condition| try self.bindNode(condition, scope);
                for (switch_case.consequent) |statement| try self.bindNode(statement, scope);
            },
            .ObjectExpression => |obj_expr| {
                for (obj_expr.properties) |prop| try self.bindNode(prop.value, scope);
            },
            .ArrayExpression => |arr| {
                for (arr.elements) |elem| try self.bindNode(elem, scope);
            },
            else => {},
        }
    }

    fn addScope(self: *Binder, kind: ScopeKind, parent: ?ScopeId) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{ .id = id, .kind = kind, .parent = parent });
        return id;
    }

    fn declare(self: *Binder, scope_id: ScopeId, name: []const u8, kind: SymbolKind, declaration: NodeId, span: tokens.Span) !SymbolId {
        const scope = &self.scopes.items[@intCast(scope_id)];
        for (scope.symbols.items) |existing_id| {
            const existing = self.symbols.items[@intCast(existing_id)];
            if (std.mem.eql(u8, existing.name, name)) {
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .duplicate_declaration,
                    .phase = .binder,
                    .message = "duplicate declaration",
                    .span = span,
                });
                break;
            }
        }

        const id: SymbolId = @intCast(self.symbols.items.len);
        try self.symbols.append(self.allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .scope = scope_id,
            .declaration = declaration,
            .span = span,
        });
        try scope.symbols.append(self.allocator, id);
        return id;
    }

    fn recordDeclarationExports(self: *Binder, node_id: NodeId) !void {
        const node = self.ast.node(node_id);
        switch (node.data) {
            .FunctionDeclaration => |function_decl| try self.appendExport(function_decl.name, function_decl.name, node_id),
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration_id| try self.recordDeclarationExports(declaration_id);
            },
            .VariableDeclarator => |declarator| try self.appendExport(declarator.name, declarator.name, node_id),
            else => {},
        }
    }

    fn appendExport(self: *Binder, name: []const u8, local_name: []const u8, node_id: NodeId) !void {
        for (self.exports.items) |export_record| {
            if (std.mem.eql(u8, export_record.name, name)) {
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .duplicate_export,
                    .phase = .binder,
                    .message = "duplicate export",
                    .span = self.ast.node(node_id).span,
                });
                return;
            }
        }

        try self.exports.append(self.allocator, .{
            .name = name,
            .local_name = local_name,
            .node = node_id,
        });
    }
};

pub fn bind(allocator: std.mem.Allocator, tree: ast_mod.Ast) !BindResult {
    var binder = Binder{ .allocator = allocator, .ast = tree };
    return binder.bind();
}

fn hasSymbol(result: BindResult, name: []const u8) bool {
    for (result.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return true;
    }
    return false;
}

test "binder records imports exports scopes and declarations" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\import { log } from "console";
        \\
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    log(message);
        \\    return message;
        \\}
    ;

    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), bound.module.imports.len);
    try std.testing.expectEqual(@as(usize, 1), bound.module.exports.len);
    try std.testing.expect(hasSymbol(bound, "log"));
    try std.testing.expect(hasSymbol(bound, "main"));
    try std.testing.expect(hasSymbol(bound, "name"));
    try std.testing.expect(hasSymbol(bound, "message"));
}

test "binder binds iteration variables in loop header scopes" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\function visit(object, iterable, stream) {
        \\    for (const key in object) { key; }
        \\    for (const value of iterable) { value; }
        \\    for await (const item of stream) { item; }
        \\}
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);

    for ([_][]const u8{ "key", "value", "item" }) |name| {
        var found = false;
        for (bound.symbols) |symbol| if (std.mem.eql(u8, symbol.name, name)) {
            found = true;
            try std.testing.expectEqual(ScopeKind.block, bound.scopes[@intCast(symbol.scope)].kind);
        };
        try std.testing.expect(found);
    }
}
